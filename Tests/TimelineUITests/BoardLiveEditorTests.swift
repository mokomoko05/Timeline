import AppKit
import SwiftUI
import WebKit
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
func boardWebView(in root: NSView) throws -> WKWebView {
    if let view = root as? WKWebView { return view }
    for child in root.subviews {
        if let view = try? boardWebView(in: child) { return view }
    }
    throw NSError(domain: "BoardTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing live editor"])
}

@MainActor
func waitForBoardEditor(_ view: WKWebView) async throws {
    for _ in 0..<400 {
        if (try? await view.evaluateJavaScript("!!window.boardEditor?.view()")) as? Bool == true { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Live editor did not load")
    throw NSError(domain: "BoardTests", code: 2)
}

@MainActor
final class BoardLiveEditorTests: XCTestCase {
    func testSelectionAcrossRenderedTextAndCodeRemainsVisibleAfterCopy() async throws {
        let source = "## Title\n\n**Selected** text\n\n```\ncode to copy\n```\n\nEnd"
        let fixture = try LiveFixture(source: source)
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        for dark in [true, false] {
            fixture.session.configure(fontSize: 13, dark: dark)
            _ = try await fixture.webView.evaluateJavaScript("""
            (()=>{
              const editor=window.boardEditor;
              const start=editor.snapshot().source.indexOf('Selected');
              const end=editor.snapshot().source.indexOf('code to copy')+'code to copy'.length;
              editor.focus();editor.select(start,end);
              editor.view().measure();
            })()
            """)
            try await Task.sleep(for: .milliseconds(60))
            let result = try await fixture.webView.evaluateJavaScript("""
            (()=>{
              const editor=window.boardEditor, selection=editor.view().state.selection.main;
              const text=editor.view().state.sliceDoc(selection.from,selection.to);
              const style=getComputedStyle(document.querySelector('.cm-selectionBackground'));
              let copied;
              document.addEventListener('copy',event=>{
                copied=event.clipboardData.getData('text/plain');
                event.preventDefault();
              },{once:true});
              document.execCommand('copy');
              return {text,copied,background:style.backgroundColor,
                selected:!editor.view().state.selection.main.empty};
            })()
            """) as? [String: Any] ?? [:]
            let selected = try XCTUnwrap(result["text"] as? String)
            XCTAssertTrue(selected.contains("Selected"))
            XCTAssertTrue(selected.contains("code to copy"))
            XCTAssertEqual(result["copied"] as? String, selected)
            XCTAssertEqual(result["selected"] as? Bool, true)
            XCTAssertNotEqual(result["background"] as? String, "rgba(0, 0, 0, 0)")
            let snapshot = try await fixture.snapshot()
            XCTAssertEqual(snapshot["source"] as? String, source)
        }
    }

    /// ⌘Enter：保存内容并回到只读浏览。
    func testCommandEnterSavesAndReturnsToReadOnlyBrowsing() async throws {
        let fixture = try LiveFixture(source: "Before body")
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        var previews = 0
        fixture.session.onPreview = { previews += 1; fixture.session.setSourceMode(false) }
        fixture.session.setSourceMode(true)
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.select(7);window.boardEditor.replaceSelection('edited ')")
        let handled = try await fixture.webView.evaluateJavaScript(
            "!document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',metaKey:true,bubbles:true,cancelable:true}))") as? Bool
        XCTAssertEqual(handled, true, "⌘Enter 由编辑器处理，不插入换行")
        for _ in 0..<50 where previews == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(previews, 1)
        XCTAssertEqual(fixture.store.boards[0].markdown, "Before edited body", "按下时立即保存")
        for _ in 0..<50 {
            if (try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-content').isContentEditable") as? Bool) == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let editable = try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-content').isContentEditable") as? Bool
        XCTAssertEqual(editable, false, "回到只读浏览")
    }

    func testRegularEditingSurvivesFocusChangesAndWebContentReloadWithoutVim() async throws {
        let fixture = try LiveFixture(source: "Before body")
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.select(7);window.boardEditor.replaceSelection('edited ')")
        await fixture.commit()
        fixture.store.save()
        for _ in 0..<3 {
            _ = try await fixture.webView.evaluateJavaScript("document.activeElement?.blur();window.boardEditor.focus()")
            let state = try await fixture.webView.evaluateJavaScript("({editable:document.querySelector('.cm-content').isContentEditable,vim:!!window.boardEditor.view().cm,panel:!!document.querySelector('.cm-vim-panel')})") as? [String: Bool]
            XCTAssertEqual(state, ["editable": true, "vim": false, "panel": false])
        }
        fixture.session.webViewWebContentProcessDidTerminate(fixture.webView)
        try await waitForBoardEditor(fixture.webView)
        let restored = try await fixture.snapshot()
        XCTAssertEqual(restored["source"] as? String, "Before edited body")
        XCTAssertEqual(JournalStore(directory: fixture.directory).boards[0].markdown, "Before edited body")
    }

    func testLinkButtonsUseTaskSafariRoutingWithoutMovingCaretOrChangingMarkdown() async throws {
        let source = "[Paper](https://example.com/paper)\n\n[**Design**](<https://example.com/a_(b)?a=1&amp;b=2> \"Title\")\n\nEnd"
        let fixture = try LiveFixture(source: source)
        defer { fixture.close() }
        let (activate, launch) = (SafariLinks.activateExistingTab, SafariLinks.launch)
        defer { SafariLinks.activateExistingTab = activate; SafariLinks.launch = launch }
        var activated: [URL] = [], launched: [URL] = []
        SafariLinks.activateExistingTab = { activated.append($0); return activated.count == 1 }
        SafariLinks.launch = { launched.append($0) }
        try await waitForBoardEditor(fixture.webView)
        let urls = try await fixture.webView.evaluateJavaScript("[...document.querySelectorAll('.board-open-link')].map(e=>e.dataset.openUrl)") as? [String]
        XCTAssertEqual(urls, ["https://example.com/paper", "https://example.com/a_(b)?a=1&b=2"])
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.select(3);document.querySelector('.board-open-link').click()")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(activated.map(\.absoluteString), ["https://example.com/paper"])
        XCTAssertTrue(launched.isEmpty)
        let snapshot = try await fixture.snapshot()
        XCTAssertEqual(snapshot["head"] as? Int, 3)
        XCTAssertEqual(snapshot["source"] as? String, source)
        _ = try await fixture.webView.evaluateJavaScript("document.querySelectorAll('.board-open-link')[1].click()")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(launched.map(\.absoluteString), ["https://example.com/a_(b)?a=1&b=2"])
        _ = try await fixture.webView.evaluateJavaScript("document.querySelector('[data-url]').dispatchEvent(new MouseEvent('click',{bubbles:true,metaKey:true}))")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(activated.count, 3)
    }

    func testCodeCopyButtonsCopyOnlyCurrentBodyAndKeepSelectionAndUndo() async throws {
        let source = "```swift\n  let value = 1\n\n  print(value)\n```\n\n~~~\n~~~\n\n```text\nunclosed\n"
        let fixture = try LiveFixture(source: source)
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        let buttons = try await fixture.webView.evaluateJavaScript("document.querySelectorAll('.board-copy-code').length") as? Int
        XCTAssertEqual(buttons, 3)
        // 预览时复制按钮浮在代码块右上角，不单独占一行；空代码块只剩这一行。
        let corner = try await fixture.webView.evaluateJavaScript("""
        (()=>{const header=document.querySelector('.cm-code-header-concealed');
          return {position:getComputedStyle(header.querySelector('.board-copy-code')).position,
            height:header.getBoundingClientRect().height,
            concealed:document.querySelectorAll('.cm-code-header-concealed').length};})()
        """) as? [String: Any]
        XCTAssertEqual(corner?["position"] as? String, "absolute")
        XCTAssertLessThanOrEqual((corner?["height"] as? NSNumber)?.doubleValue ?? 99, 8)
        XCTAssertEqual(corner?["concealed"] as? Int, 1, "光标所在的第一块显示源码，空代码块保留按钮所在的那一行，只有最后一块收起")
        _ = try await fixture.webView.evaluateJavaScript("(()=>{const editor=window.boardEditor;const start=editor.snapshot().source.indexOf('1');editor.select(start,start+1);editor.replaceSelection('42')})()")
        let before = try await fixture.snapshot()
        _ = try await fixture.webView.evaluateJavaScript("document.querySelector('.board-copy-code').click()")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "  let value = 42\n\n  print(value)\n")
        let feedback = try await fixture.webView.evaluateJavaScript("document.querySelector('.board-copy-code').dataset.copied") as? String
        XCTAssertEqual(feedback, "true")
        let style = try await fixture.webView.evaluateJavaScript("""
        (()=>{const button=document.querySelector('.board-copy-code');
          return {label:button.dataset.label,top:getComputedStyle(document.querySelector('.cm-code-start')).borderTopLeftRadius,
            bottom:getComputedStyle([...document.querySelectorAll('.cm-code-end')].at(-1)).borderBottomRightRadius};})()
        """) as? [String: String]
        XCTAssertEqual(style?["label"], "已复制")
        XCTAssertEqual(style?["top"], "9px")
        XCTAssertEqual(style?["bottom"], "9px", "文档结尾未闭合的代码块也有圆角")
        if let path = ProcessInfo.processInfo.environment["TIMELINE_CODE_SNAPSHOT"] {
            let image = try await fixture.webView.takeSnapshot(configuration: nil)
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        let after = try await fixture.snapshot()
        XCTAssertEqual(after["source"] as? String, before["source"] as? String)
        XCTAssertEqual(after["head"] as? Int, before["head"] as? Int)
        _ = try await fixture.webView.evaluateJavaScript("document.querySelectorAll('.board-copy-code')[1].click()")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "")
        _ = try await fixture.webView.evaluateJavaScript("document.querySelectorAll('.board-copy-code')[2].click()")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "unclosed\n")
        fixture.session.undo()
        try await Task.sleep(for: .milliseconds(60))
        let undone = try await fixture.snapshot()
        XCTAssertEqual(undone["source"] as? String, source)
        fixture.session.configure(fontSize: 13, dark: false, sourceMode: true)
        try await Task.sleep(for: .milliseconds(30))
        let rawButtons = try await fixture.webView.evaluateJavaScript("document.querySelectorAll('.board-copy-code').length") as? Int
        XCTAssertEqual(rawButtons, 0)
    }

    func testLivePreviewHeadingsBlankLinesTaskCompletionAndNativePersistence() async throws {
        let fixture = try LiveFixture(source: "# First\n\n## Second\n\n\n\nThird\n\n- [ ] Task\n\nEnd")
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        XCTAssertNil(fixture.session.error)
        let headings = try await fixture.webView.evaluateJavaScript("[...document.querySelectorAll('.cm-heading-1,.cm-heading-2')].map(e=>getComputedStyle(e).color)") as? [String]
        XCTAssertEqual(headings?.count, 2)
        XCTAssertNotEqual(headings?.first, headings?.last)
        let blanks = try await fixture.webView.evaluateJavaScript("[...document.querySelectorAll('.cm-line')].filter(e=>!e.textContent.trim()).length") as? Int
        XCTAssertGreaterThanOrEqual(blanks ?? 0, 4)
        _ = try await fixture.webView.evaluateJavaScript("document.querySelector('.board-check').click()")
        let checkedSnapshot = try await fixture.snapshot()
        XCTAssertEqual(checkedSnapshot["source"] as? String,
                       "# First\n\n## Second\n\n\n\nThird\n\n- [x] Task\n\nEnd")
        let checked = try await fixture.webView.evaluateJavaScript("document.querySelector('.board-check').getAttribute('aria-checked')") as? String
        let strike = try await fixture.webView.evaluateJavaScript("getComputedStyle(document.querySelector('.cm-task-done')).textDecorationLine.includes('line-through')") as? Bool
        XCTAssertEqual(checked, "true")
        XCTAssertTrue(strike == true)
        if let path = ProcessInfo.processInfo.environment["TIMELINE_LIVE_SNAPSHOT"] {
            let image = try await fixture.webView.takeSnapshot(configuration: nil)
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        await fixture.commit()
        fixture.store.save()
        XCTAssertTrue(JournalStore(directory: fixture.directory).boards[0].markdown.contains("- [x] Task"))
    }

    func testDetailsToggleIsImmediateCompactAndDoesNotMutateSourceOrLoseSelection() async throws {
        let source = "Before\n<details>\n<summary>Agenda</summary>\n\n## Discussion\n\n- [ ] Action\n\n</details>\nAfter\n"
        let fixture = try LiveFixture(source: source)
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        let before = try await fixture.snapshot()
        let closed = try await fixture.webView.evaluateJavaScript("document.querySelector('.board-details').getAttribute('aria-expanded')") as? String
        XCTAssertEqual(closed, "false")
        let hidden = try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-content').textContent.includes('Discussion')") as? Bool
        XCTAssertFalse(hidden == true)
        let gap = try await fixture.webView.evaluateJavaScript("(()=>{const b=document.querySelector('.board-details');return b.getBoundingClientRect().top-b.closest('.cm-line').previousElementSibling.getBoundingClientRect().bottom})()") as? Double
        XCTAssertLessThanOrEqual(gap ?? 100, 4)
        for _ in 0..<8 {
            let result = try await fixture.webView.evaluateJavaScript("(()=>{const start=performance.now();const b=document.querySelector('.board-details');b.click();return {open:b.isConnected?b.getAttribute('aria-expanded'):document.querySelector('.board-details').getAttribute('aria-expanded'),elapsed:performance.now()-start}})()") as? [String: Any]
            XCTAssertLessThan(result?["elapsed"] as? Double ?? 1000, 150)
        }
        let after = try await fixture.snapshot()
        XCTAssertEqual(after["source"] as? String, source)
        XCTAssertEqual(after["head"] as? Int, before["head"] as? Int)
        XCTAssertEqual(fixture.store.boards[0].markdown, source)
    }

    func testPreviewNeverRevealsMarkupWhenSelectedAndSourceModeRestoresEditing() async throws {
        let source = "# Heading\n\n```swift\nlet value = 42\n```\n\n<details open>\n<summary>Agenda</summary>\n\n- [ ] Action\n\n</details>\n\nEnd"
        let fixture = try LiveFixture(source: source)
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        for offset in [0, 14, 46, source.utf16.count] {
            _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.select(\(offset))")
            fixture.session.configure(fontSize: 13, dark: true, previewOnly: true)
            try await Task.sleep(for: .milliseconds(30))
            let state = try await fixture.webView.evaluateJavaScript("""
            (()=>{const content=document.querySelector('.cm-content');return {
              text:content.textContent,editable:content.isContentEditable,
              readonly:window.boardEditor.view().state.readOnly};})()
            """) as? [String: Any]
            let text = try XCTUnwrap(state?["text"] as? String)
            for marker in ["```", "<details", "<summary", "</details>", "# Heading", "- [ ]"] {
                XCTAssertFalse(text.contains(marker), marker)
            }
            XCTAssertTrue(text.contains("let value = 42"))
            XCTAssertEqual(state?["editable"] as? Bool, false)
            XCTAssertEqual(state?["readonly"] as? Bool, true)
        }
        _ = try await fixture.webView.evaluateJavaScript("document.querySelector('.board-check').click()")
        let checked = try await fixture.snapshot()
        XCTAssertTrue((checked["source"] as? String)?.contains("- [x] Action") == true)
        _ = try await fixture.webView.evaluateJavaScript("document.querySelector('.board-copy-code').click()")
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "let value = 42\n")
        fixture.session.setSourceMode(true)
        try await Task.sleep(for: .milliseconds(40))
        let raw = try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-content').textContent") as? String
        XCTAssertTrue(raw?.contains("```swift") == true)
        XCTAssertTrue(raw?.contains("<summary>Agenda</summary>") == true)
        let editable = try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-content').isContentEditable") as? Bool
        XCTAssertEqual(editable, true)
        fixture.session.setSourceMode(false)
        try await Task.sleep(for: .milliseconds(40))
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.focus();window.boardEditor.select(3)")
        let preview = try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-content').textContent") as? String
        XCTAssertFalse(preview?.contains("```") == true)
        XCTAssertFalse(preview?.contains("<summary>") == true)
        let cursorHidden = try await fixture.webView.evaluateJavaScript("getComputedStyle(document.querySelector('.cm-cursorLayer')).display==='none'") as? Bool
        XCTAssertEqual(cursorHidden, true)
        if let path = ProcessInfo.processInfo.environment["TIMELINE_BOARD_PREVIEW_SNAPSHOT"] {
            let image = try await fixture.webView.takeSnapshot(configuration: nil)
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    func testLongDisclosureTitleWrapsCompletelyAtNarrowWidths() async throws {
        let title = String(repeating: "长标题包含完整的议程和阅读目标", count: 8) + String(repeating: "longword", count: 20)
        let fixture = try LiveFixture(source: "Before\n\n<details>\n<summary>\(title)</summary>\n\nBody\n\n</details>\nAfter")
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        fixture.session.configure(fontSize: 13, dark: true, previewOnly: true)
        for width in [300, 410] {
            fixture.window.setContentSize(NSSize(width: width, height: 480))
            try await Task.sleep(for: .milliseconds(70))
            let metrics = try await fixture.webView.evaluateJavaScript("""
            (()=>{const title=document.querySelector('.board-details .title');const style=getComputedStyle(title);
              return {text:title.textContent,ellipsis:style.textOverflow==='ellipsis',wrapped:title.clientHeight>30,
                fits:title.scrollWidth<=title.clientWidth+1, height:title.getBoundingClientRect().height};})()
            """) as? [String: Any]
            XCTAssertEqual(metrics?["text"] as? String, title)
            XCTAssertEqual(metrics?["ellipsis"] as? Bool, false)
            XCTAssertEqual(metrics?["fits"] as? Bool, true)
            XCTAssertGreaterThan(metrics?["height"] as? Double ?? 0, 50)
        }
    }

    func testTypingPreservesCaretThroughStoreRefreshAndTemplateUndo() async throws {
        let fixture = try LiveFixture(source: "Before\n\nBody\n\nAfter")
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.select(8,12);window.boardEditor.replaceSelection('中文 body')")
        let before = try await fixture.snapshot()
        fixture.session.configure(fontSize: 13, dark: true)
        try await Task.sleep(for: .milliseconds(250))
        let after = try await fixture.snapshot()
        XCTAssertEqual(before["head"] as? Int, after["head"] as? Int)
        XCTAssertEqual(after["source"] as? String, "Before\n\n中文 body\n\nAfter")
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.select(8,15)")
        fixture.session.insertTemplate(.disclosure)
        try await Task.sleep(for: .milliseconds(60))
        let inserted = try await fixture.snapshot()["source"] as? String
        XCTAssertTrue(inserted?.contains("\n\n中文 body\n\n</details>") == true)
        fixture.session.undo()
        try await Task.sleep(for: .milliseconds(60))
        let undone = try await fixture.snapshot()
        XCTAssertEqual(undone["source"] as? String, "Before\n\n中文 body\n\nAfter")
    }

    func testArrowKeysMoveThroughFormattedAndCompletedTextCharacterByCharacter() async throws {
        let fixture = try LiveFixture(source: "**Bold** text\n\n- [x] Completed\n\nEnd")
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        for text in ["Bold", "Completed"] {
            let encoded = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
            let result = try await fixture.webView.evaluateJavaScript("(()=>{const editor=window.boardEditor;const start=editor.snapshot().source.indexOf(\(encoded))+1;editor.focus();editor.select(start);document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true,cancelable:true}));return {start,head:editor.snapshot().head}})()") as? [String: Int]
            XCTAssertEqual(result?["head"], result?["start"].map { $0 + 1 }, text)
        }
    }

    func testRepeatedEscapeKeepsEditorFocusedAndDisclosuresOpen() async throws {
        let source = "<details open>\n<summary>Agenda</summary>\n\nDiscussion\n\n</details>\n\nEnd"
        let fixture = try LiveFixture(source: source)
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.focus()")
        for _ in 0..<3 { let handled = try await fixture.pressKey("Escape"); XCTAssertTrue(handled) }
        let state = try await fixture.webView.evaluateJavaScript("({focused:document.activeElement===document.querySelector('.cm-content'),open:document.querySelector('.board-details').getAttribute('aria-expanded')==='true',editable:document.querySelector('.cm-content').isContentEditable})") as? [String: Bool]
        XCTAssertEqual(state, ["focused": true, "open": true, "editable": true])
        let snapshot = try await fixture.snapshot()
        XCTAssertEqual(snapshot["source"] as? String, source)
    }

    func testCursorsRemainVisibleWithStrongContrastInBothAppearances() async throws {
        let fixture = try LiveFixture(source: "Cursor visibility")
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        for dark in [true, false] {
            fixture.session.configure(fontSize: 13, dark: dark)
            _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.focus();window.boardEditor.select(3);window.boardEditor.view().measure();window.boardEditor.view().dom.classList.add('cm-focused')")
            try await Task.sleep(for: .milliseconds(60))
            let insert = try await fixture.webView.evaluateJavaScript("(()=>{const cursor=document.querySelector('.cm-cursor');if(!cursor)return {width:0,steady:false,visible:false};const style=getComputedStyle(cursor);return {width:parseFloat(style.borderLeftWidth),steady:getComputedStyle(cursor.parentElement).animationName==='none',visible:style.display!=='none'}})()") as? [String: Any]
            XCTAssertGreaterThanOrEqual(insert?["width"] as? Double ?? 0, 2)
            XCTAssertEqual(insert?["steady"] as? Bool, true)
            XCTAssertEqual(insert?["visible"] as? Bool, true)
            _ = try await fixture.pressKey("Escape")
        }
    }

    func testFoldCanCloseWhileEditingItsBodyAndNestedFencesStayLiteral() async throws {
        let source = "<details open>\n<summary>Outer</summary>\n\nBody\n\n<details>\n<summary>Inner</summary>\n\nNested\n\n</details>\n\n</details>\n\n~~~html\n<details><summary>Code</summary>\nLiteral\n</details>\n~~~\n"
        let fixture = try LiveFixture(source: source)
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.select(window.boardEditor.snapshot().source.indexOf('Body')+2);document.querySelector('.board-details').click()")
        let closed = try await fixture.webView.evaluateJavaScript("document.querySelector('.board-details').getAttribute('aria-expanded')") as? String
        XCTAssertEqual(closed, "false")
        let sourceAfter = try await fixture.snapshot()
        XCTAssertEqual(sourceAfter["source"] as? String, source)
        _ = try await fixture.webView.evaluateJavaScript("document.querySelector('.board-details').click()")
        let count = try await fixture.webView.evaluateJavaScript("document.querySelectorAll('.board-details').length") as? Int
        XCTAssertEqual(count, 2)
        let literal = try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-content').textContent.includes('Literal')") as? Bool
        XCTAssertTrue(literal == true)
    }

    func testCompositionDoesNotPublishIntermediateTextOrResetCaret() async throws {
        let fixture = try LiveFixture(source: "Before\n\nAfter")
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.focus();window.boardEditor.select(8);document.querySelector('.cm-content').dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true}));window.boardEditor.replaceSelection('zhongwen')")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(fixture.store.boards[0].markdown, "Before\n\nAfter")
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.select(8,16);window.boardEditor.replaceSelection('中文');document.querySelector('.cm-content').dispatchEvent(new CompositionEvent('compositionend',{bubbles:true}))")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(fixture.store.boards[0].markdown, "Before\n\n中文After")
        let snapshot = try await fixture.snapshot()
        XCTAssertEqual(snapshot["head"] as? Int, 10)
    }

    func testSourceModeAndExternalUpdatesKeepTheEditorAndSelection() async throws {
        let fixture = try LiveFixture(source: "# Title\n\n**Strong**\n\nAfter")
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.select(23)")
        fixture.session.configure(fontSize: 13, dark: true, sourceMode: true)
        try await Task.sleep(for: .milliseconds(40))
        let raw = try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-content').textContent") as? String
        XCTAssertTrue(raw?.contains("# Title") == true)
        XCTAssertTrue(raw?.contains("**Strong**") == true)
        fixture.session.configure(fontSize: 13, dark: true)
        try await Task.sleep(for: .milliseconds(40))
        let rendered = try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-content').textContent") as? String
        XCTAssertFalse(rendered?.contains("# Title") == true)
        let selection = try await fixture.snapshot()
        XCTAssertEqual(selection["head"] as? Int, 23)
        fixture.store.setBoardMarkdown("# Updated\n\nExternal\n\nAfter", for: fixture.store.boards[0].id)
        fixture.session.configure(fontSize: 13, dark: true)
        try await Task.sleep(for: .milliseconds(40))
        let external = try await fixture.snapshot()
        XCTAssertEqual(external["source"] as? String, fixture.store.boards[0].markdown)
        XCTAssertEqual(external["head"] as? Int, 23)
    }
}

@MainActor
private final class LiveFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store: JournalStore
    let session: BoardLiveEditorSession
    let webView: WKWebView
    let window: NSWindow
    let pasteboard = NSPasteboard(name: .init("board-editor-\(UUID().uuidString)"))

    init(source: String) throws {
        store = JournalStore(directory: directory)
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Editor")))
        store.setBoardMarkdown(source, for: board.id)
        store.save()
        session = BoardLiveEditorSession(store: store, board: try XCTUnwrap(store.board(for: board.owner)), pasteboard: pasteboard)
        webView = session.makeWebView()
        session.configure(fontSize: 13, dark: true)
        window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 480),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFront(nil)
    }

    func snapshot() async throws -> [String: Any] {
        let result = try await webView.evaluateJavaScript("window.boardEditor.snapshot()")
        return try XCTUnwrap(result as? [String: Any])
    }

    func pressKey(_ key: String, control: Bool = false) async throws -> Bool {
        let json = String(decoding: try JSONEncoder().encode(key), as: UTF8.self)
        let result = try await webView.evaluateJavaScript("!document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:\(json),ctrlKey:\(control),bubbles:true,cancelable:true}))")
        return result as? Bool == true
    }

    func commit() async {
        await withCheckedContinuation { continuation in session.commit { continuation.resume() } }
    }

    func close() {
        session.flush()
        pasteboard.releaseGlobally()
        window.contentView = nil
        window.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
