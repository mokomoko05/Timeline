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

/// 等界面里的工作板编辑器就绪，返回它（迟迟没就绪被重建过就是新放进界面的那个）。
@MainActor
func waitForBoardEditor(in root: NSView) async throws -> WKWebView {
    let initial = try boardWebView(in: root)
    try await waitForBoardEditor({ root.layoutSubtreeIfNeeded(); return (try? boardWebView(in: root)) ?? initial }())
    return try boardWebView(in: root)
}

@MainActor
func waitForBoardEditor(_ current: @autoclosure () -> WKWebView) async throws {
    // 编辑器网页迟迟没就绪时会被重建（换成新的视图），每次都取当前的。
    for _ in 0..<600 {
        let view = current()
        // 编辑器网页是共用的：上一个测试留下的页面可能还在重新加载，等加载完再用。
        if !view.isLoading, (try? await view.evaluateJavaScript("!!window.boardEditor?.view()")) as? Bool == true { return }
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
        fixture.session.onPreview = { [unowned fixture] in previews += 1; fixture.session.setSourceMode(false) }
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

    /// 浏览（只读预览）时也能撤销：⌘Enter 保存后的修改、勾掉的待办都能 ⌘Z 找回，撤销历史报给原生层。
    func testUndoWorksWhileBrowsingAndReportsHistory() async throws {
        let fixture = try LiveFixture(source: "Intro\n\n- [ ] Task\n")
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        fixture.session.setSourceMode(true)
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.select(5);window.boardEditor.replaceSelection(' edited')")
        fixture.session.setSourceMode(false)
        for _ in 0..<50 {
            if (try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-content').isContentEditable") as? Bool) == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await fixture.webView.evaluateJavaScript("document.querySelector('.board-check').click()")
        let checked = try await fixture.snapshot()["source"] as? String
        XCTAssertEqual(checked, "Intro edited\n\n- [x] Task\n")
        let handled = try await fixture.webView.evaluateJavaScript(
            "!document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'z',metaKey:true,bubbles:true,cancelable:true}))") as? Bool
        XCTAssertEqual(handled, true, "浏览时 ⌘Z 由编辑器处理")
        let unchecked = try await fixture.snapshot()["source"] as? String
        XCTAssertEqual(unchecked, "Intro edited\n\n- [ ] Task\n")
        for _ in 0..<50 where fixture.session.redoDepth == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(fixture.session.undoDepth, 0)
        XCTAssertEqual(fixture.session.redoDepth, 1)
        fixture.session.undo()
        try await Task.sleep(for: .milliseconds(300))
        let undone = try await fixture.snapshot()["source"] as? String
        XCTAssertEqual(undone, "Intro\n\n- [ ] Task\n")
        XCTAssertEqual(fixture.store.boards[0].markdown, "Intro\n\n- [ ] Task\n", "撤销后的内容照常保存")
        fixture.session.redo()
        try await Task.sleep(for: .milliseconds(60))
        let redone = try await fixture.snapshot()["source"] as? String
        XCTAssertEqual(redone, "Intro edited\n\n- [ ] Task\n")
        let editable = try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-content').isContentEditable") as? Bool
        XCTAssertEqual(editable, false, "撤销完仍是只读浏览")
    }

    private static let foldSource = "# A\n\nalpha\n\n## A1\n\ninside\n\n# B\n\nbeta\n\n<details>\n<summary>D</summary>\n\n## In details\n\nhidden body\n\n</details>\n"

    private func browse(_ session: BoardLiveEditorSession, _ webView: WKWebView) async throws {
        session.configure(fontSize: 13, dark: true, previewOnly: true)
        for _ in 0..<50 {
            if (try await webView.evaluateJavaScript("document.querySelector('.cm-content').isContentEditable") as? Bool) == false { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func visibleText(_ webView: WKWebView) async throws -> String {
        try await webView.evaluateJavaScript("document.querySelector('.cm-content').textContent") as? String ?? ""
    }

    /// 所有工作板共用一个编辑器（一份网页进程）：换走再换回来，正文、光标、撤销历史和折叠都还是这块工作板自己的。
    func testBoardsShareOneEditorAndKeepTheirOwnStateWhenSwitching() async throws {
        let fixture = try LiveFixture(source: Self.foldSource)
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        let first = fixture.session
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.select(0);window.boardEditor.replaceSelection('Edited ');window.boardEditor.select(3)")
        try await browse(first, fixture.webView)
        _ = try await fixture.webView.evaluateJavaScript("document.querySelector('.board-heading-fold').click()")

        let other = try XCTUnwrap(fixture.store.ensureBoard(for: .tag("Other")))
        fixture.store.setBoardMarkdown("Other board", for: other.id)
        let second = BoardLiveEditorSession(store: fixture.store, board: try XCTUnwrap(fixture.store.board(for: .tag("Other"))),
                                            defaults: fixture.defaults)
        let shared = second.makeWebView()
        XCTAssertTrue(shared === fixture.webView, "两块工作板用的是同一个编辑器")
        XCTAssertNil(first.webView, "上一块交出了编辑器")
        second.configure(fontSize: 13, dark: true, previewOnly: true)
        try await Task.sleep(for: .milliseconds(60))
        var snapshot = try await fixture.snapshot()
        XCTAssertEqual(snapshot["source"] as? String, "Other board")
        let otherFolds = try await fixture.webView.evaluateJavaScript("document.querySelectorAll('.board-fold-more').length") as? Int
        XCTAssertEqual(otherFolds, 0, "折叠记忆不串到别的工作板")

        XCTAssertTrue(first.makeWebView() === shared)
        first.configure(fontSize: 13, dark: true, previewOnly: true)
        try await Task.sleep(for: .milliseconds(60))
        snapshot = try await fixture.snapshot()
        XCTAssertEqual(snapshot["source"] as? String, "Edited " + Self.foldSource)
        XCTAssertEqual(snapshot["head"] as? Int, 3, "光标还在原处")
        let folded = try await fixture.webView.evaluateJavaScript("document.querySelectorAll('.board-fold-more').length") as? Int
        XCTAssertEqual(folded, 1, "这块工作板的折叠还在")
        first.undo()
        try await Task.sleep(for: .milliseconds(60))
        snapshot = try await fixture.snapshot()
        XCTAssertEqual(snapshot["source"] as? String, Self.foldSource, "撤销历史跟着工作板走")
    }

    /// 在元素里横向 `fraction` 处模拟一次单击（按下、松开），返回点击的纵坐标。
    private static func clickScript(_ element: String, fraction: Double = 0.3, detail: Int = 1) -> String {
        """
        (()=>{const el=\(element);const r=el.getBoundingClientRect();const x=r.left+r.width*\(fraction),y=r.top+r.height/2;
        const o={bubbles:true,cancelable:true,clientX:x,clientY:y,button:0,detail:\(detail)};
        el.dispatchEvent(new MouseEvent('mousedown',o));el.dispatchEvent(new MouseEvent('mouseup',o));return y;})()
        """
    }

    private static func lineContaining(_ text: String) -> String {
        "[...document.querySelectorAll('.cm-line')].find(l=>l.textContent.includes('\(text)'))"
    }

    /// 浏览时点标题文字的任何地方都能收起 / 展开，不用瞄准左边的小箭头。
    func testClickingAnywhereOnAHeadingWhileBrowsingTogglesTheFold() async throws {
        let fixture = try LiveFixture(source: Self.foldSource)
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        try await browse(fixture.session, fixture.webView)
        _ = try await fixture.webView.evaluateJavaScript(Self.clickScript("document.querySelector('.cm-line.cm-foldable')", fraction: 0.6))
        var text = try await visibleText(fixture.webView)
        XCTAssertFalse(text.contains("alpha"), "点标题本身就收起")
        XCTAssertTrue(text.contains("beta"))
        _ = try await fixture.webView.evaluateJavaScript(Self.clickScript("document.querySelector('.cm-line.cm-foldable')", fraction: 0.2))
        text = try await visibleText(fixture.webView)
        XCTAssertTrue(text.contains("alpha"), "再点一次展开")
        let unchanged = try await fixture.snapshot()["source"] as? String
        XCTAssertEqual(unchanged, Self.foldSource)
    }

    /// 连续快点标题：第二下（双击）也算一次收起 / 展开；连点箭头时原生层的回传不会把新状态盖回去。
    func testRapidClicksOnAHeadingEachToggleTheFold() async throws {
        let fixture = try LiveFixture(source: Self.foldSource)
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        try await browse(fixture.session, fixture.webView)
        let heading = "document.querySelector('.cm-line.cm-foldable')"
        _ = try await fixture.webView.evaluateJavaScript(Self.clickScript(heading, fraction: 0.6))
        _ = try await fixture.webView.evaluateJavaScript(Self.clickScript(heading, fraction: 0.6, detail: 2))
        var text = try await visibleText(fixture.webView)
        XCTAssertTrue(text.contains("alpha"), "双击的第二下把它展开回来")

        _ = try await fixture.webView.evaluateJavaScript("""
            (()=>{const b=()=>document.querySelector('.board-heading-fold');const first=b();first.click();
            const same=b()===first;b().click();return same;})()
            """)
        try await Task.sleep(for: .milliseconds(300))
        text = try await visibleText(fixture.webView)
        XCTAssertTrue(text.contains("alpha"), "连点两下箭头：收起再展开，不被回传改回收起")
        let reused = try await fixture.webView.evaluateJavaScript("document.querySelectorAll('.board-fold-more').length") as? Int
        XCTAssertEqual(reused, 0)
    }

    /// 浏览时点下的位置有一根光标；进入编辑（包括完整源码）时光标就在那里、那一行留在屏幕上原来的高度，回到浏览时光标还在。
    func testBrowseCaretCarriesIntoEditingAndStaysInPlace() async throws {
        let source = (1...30).map { "Paragraph \($0) **bold** text" }.joined(separator: "\n\n")
        let fixture = try LiveFixture(source: source)
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        try await browse(fixture.session, fixture.webView)
        _ = try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-scroller').scrollTop=200")
        try await Task.sleep(for: .milliseconds(60))
        let line = Self.lineContaining("Paragraph 9 ")
        _ = try await fixture.webView.evaluateJavaScript(Self.clickScript(line, fraction: 0.15))
        var caret: Int?
        for _ in 0..<50 {
            caret = try await fixture.webView.evaluateJavaScript("document.querySelectorAll('.cm-browse-caret').length") as? Int
            if caret == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(caret, 1, "浏览时看得到点下的位置")
        if let path = ProcessInfo.processInfo.environment["TIMELINE_CARET_SNAPSHOT"] {
            let image = try await fixture.webView.takeSnapshot(configuration: nil)
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        let clicked = try await fixture.snapshot()
        let head = try XCTUnwrap(clicked["head"] as? Int)
        let lineStart = (source as NSString).range(of: "Paragraph 9 ").location
        XCTAssertTrue((lineStart...(lineStart + 26)).contains(head), "光标在点下的那一行：\(head)")
        let before = try await fixture.webView.evaluateJavaScript("\(line).getBoundingClientRect().top")
        let topBefore = try XCTUnwrap(before as? Double)

        fixture.session.setMode(editing: true, raw: true)
        for _ in 0..<50 {
            if (try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-content').isContentEditable") as? Bool) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(80))
        let editing = try await fixture.snapshot()
        XCTAssertEqual(editing["anchor"] as? Int, head, "进入编辑时光标就在浏览时点下的位置")
        XCTAssertEqual(editing["head"] as? Int, head)
        let after = try await fixture.webView.evaluateJavaScript("\(line).getBoundingClientRect().top")
        let topAfter = try XCTUnwrap(after as? Double)
        XCTAssertEqual(topAfter, topBefore, accuracy: 4, "那一行留在屏幕上原来的高度")
        let raw = try await visibleText(fixture.webView)
        XCTAssertTrue(raw.contains("**bold**"), "完整源码")

        fixture.session.setMode(editing: false, raw: true)
        try await browse(fixture.session, fixture.webView)
        var caretBack: Int?
        for _ in 0..<50 {
            caretBack = try await fixture.webView.evaluateJavaScript("document.querySelectorAll('.cm-browse-caret').length") as? Int
            if caretBack == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(caretBack, 1, "回到浏览时在刚才编辑的地方留着光标")
    }

    /// 浏览时光标能用方向键移动；按住 Shift 选出的范围看得见，进入编辑后仍是选区。
    func testBrowseCaretMovesWithTheKeyboard() async throws {
        let source = "First line\n\nSecond line\n\nThird line"
        let fixture = try LiveFixture(source: source)
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        try await browse(fixture.session, fixture.webView)
        let caretAtEnd = try await fixture.snapshot()["head"] as? Int
        XCTAssertEqual(caretAtEnd, (source as NSString).length, "从编辑回到浏览，光标留在刚才编辑的地方（末尾）")
        _ = try await fixture.webView.evaluateJavaScript(Self.clickScript(Self.lineContaining("First"), fraction: 0.01))
        _ = try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-content').focus()")
        let value2 = try await fixture.snapshot()["head"] as? Int
        XCTAssertEqual(value2, 0)
        let value3 = try await fixture.pressKey("ArrowDown")
        XCTAssertTrue(value3)
        let value4 = try await fixture.pressKey("ArrowDown")
        XCTAssertTrue(value4)
        let value5 = try await fixture.snapshot()["head"] as? Int
        let moved = try XCTUnwrap(value5)
        XCTAssertEqual(moved, (source as NSString).range(of: "Second").location, "向下两行到了第二段")
        let value6 = try await fixture.pressKey("ArrowRight")
        XCTAssertTrue(value6)
        let value7 = try await fixture.snapshot()["head"] as? Int
        XCTAssertEqual(value7, moved + 1)
        let caret = try await fixture.webView.evaluateJavaScript("document.querySelectorAll('.cm-browse-caret').length") as? Int
        XCTAssertEqual(caret, 1)
        let selected = try await fixture.webView.evaluateJavaScript(
            "!document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',shiftKey:true,bubbles:true,cancelable:true}))") as? Bool
        XCTAssertEqual(selected, true)
        let range = try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-browse-range')?.textContent") as? String
        XCTAssertEqual(range, "e", "Shift 选出的范围看得见")
        XCTAssertEqual(fixture.store.boards[0].markdown, source, "浏览时按键不改动正文")
        fixture.session.setMode(editing: true, raw: false)
        for _ in 0..<50 {
            if (try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-content').isContentEditable") as? Bool) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let editing = try await fixture.snapshot()
        XCTAssertEqual(editing["anchor"] as? Int, moved + 1)
        XCTAssertEqual(editing["head"] as? Int, moved + 2, "进入编辑时选区还在")
    }

    /// 收起的标题在编辑时也收起：⌘↩ 在浏览和编辑之间切换时版面不变，光标停在同一行、屏幕上同一个高度。
    func testFoldsStayWhileEditingSoTheCaretKeepsItsPlace() async throws {
        let filler = (1...12).map { "Filler \($0)" }.joined(separator: "\n\n")
        let source = "# Top\n\n\(filler)\n\n# Target\n\n\((1...20).map { "Row \($0)" }.joined(separator: "\n\n"))"
        let fixture = try LiveFixture(source: source)
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        BoardFolds.set("h1:Top#0", true, board: fixture.store.boards[0].id, defaults: fixture.defaults)
        try await browse(fixture.session, fixture.webView)
        var text = try await visibleText(fixture.webView)
        XCTAssertFalse(text.contains("Filler 3"), "别处改的折叠记忆传到编辑器")
        _ = try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-scroller').scrollTop=120")
        try await Task.sleep(for: .milliseconds(60))
        let line = Self.lineContaining("Row 6")
        _ = try await fixture.webView.evaluateJavaScript(Self.clickScript(line, fraction: 0.1))
        let value8 = try await fixture.snapshot()["head"] as? Int
        let head = try XCTUnwrap(value8)
        let topBeforeValue = try await fixture.webView.evaluateJavaScript("\(line).getBoundingClientRect().top") as? Double
        let topBefore = try XCTUnwrap(topBeforeValue)

        fixture.session.setMode(editing: true, raw: false)
        for _ in 0..<50 {
            if (try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-content').isContentEditable") as? Bool) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(80))
        text = try await visibleText(fixture.webView)
        XCTAssertFalse(text.contains("Filler 3"), "编辑时收起的标题仍收起")
        let value10 = try await fixture.snapshot()["head"] as? Int
        XCTAssertEqual(value10, head)
        let topEditingValue = try await fixture.webView.evaluateJavaScript("\(line).getBoundingClientRect().top") as? Double
        let topEditing = try XCTUnwrap(topEditingValue)
        XCTAssertEqual(topEditing, topBefore, accuracy: 2, "进入编辑时那一行在屏幕上原来的高度")

        fixture.session.onPreview = { [unowned fixture] in fixture.session.setMode(editing: false, raw: false) }
        let saved = try await fixture.webView.evaluateJavaScript(
            "!document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',metaKey:true,bubbles:true,cancelable:true}))") as? Bool
        XCTAssertEqual(saved, true)
        try await browse(fixture.session, fixture.webView)
        try await Task.sleep(for: .milliseconds(80))
        let topBackValue = try await fixture.webView.evaluateJavaScript("\(line).getBoundingClientRect().top") as? Double
        let topBack = try XCTUnwrap(topBackValue)
        XCTAssertEqual(topBack, topBefore, accuracy: 2, "⌘↩ 回到浏览时也不动")

        // 编辑时在收起的标题末尾回车：光标进了收起的那一节，展开它。
        fixture.session.setMode(editing: true, raw: false)
        let topEnd = (source as NSString).range(of: "# Top").length
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.select(\(topEnd));window.boardEditor.replaceSelection('\\n')")
        text = try await visibleText(fixture.webView)
        XCTAssertTrue(text.contains("Filler 3"))
        XCTAssertNil(BoardFolds.load(fixture.store.boards[0].id, defaults: fixture.defaults)["h1:Top#0"])
    }

    /// 编辑器网页迟迟没就绪（网页进程没起来或卡住，收不到退出通知）：重建一个，工作板照常能用，不会一直空白。
    func testEditorPageThatNeverBecomesReadyIsRebuilt() async throws {
        autoreleasepool { BoardLiveEditorSession.releaseSharedEditor() }
        let previous = BoardLiveEditorSession.loadTimeout
        BoardLiveEditorSession.loadTimeout = .milliseconds(1)
        let fixture = try LiveFixture(source: "Rebuilt body")
        BoardLiveEditorSession.loadTimeout = previous
        defer { fixture.close() }
        let original = try XCTUnwrap(fixture.session.webView)
        for _ in 0..<50 where fixture.session.webView === original { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(fixture.session.webView === original, "没就绪的编辑器被换掉")
        try await waitForBoardEditor(fixture.webView)
        let snapshot = try await fixture.snapshot()
        XCTAssertEqual(snapshot["source"] as? String, "Rebuilt body")
        XCTAssertTrue(fixture.session.ready)
    }

    /// WebKit 收到了加载请求却一直不来问导航策略（冷启动时偶尔这样）：不用等满 `loadTimeout`，很快就重建。
    func testEditorStuckBeforeNavigationIsRebuiltQuickly() async throws {
        autoreleasepool { BoardLiveEditorSession.releaseSharedEditor() }
        let previous = BoardLiveEditorSession.navigationTimeout
        BoardLiveEditorSession.navigationTimeout = .milliseconds(1)
        let fixture = try LiveFixture(source: "Quick body")
        BoardLiveEditorSession.navigationTimeout = previous
        defer { fixture.close() }
        let original = try XCTUnwrap(fixture.session.webView)
        for _ in 0..<50 where fixture.session.webView === original { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(fixture.session.webView === original, "还没开始导航的编辑器很快被换掉")
        try await waitForBoardEditor(fixture.webView)
        let snapshot = try await fixture.snapshot()
        XCTAssertEqual(snapshot["source"] as? String, "Quick body")
    }

    /// 收起 / 展开时被点的标题留在屏幕上原来的位置，内容在它下面展开、收起；滚到底时也一样（底部临时留白，往上滚就收回）。
    func testFoldingKeepsTheHeadingInPlaceEvenAtTheBottom() async throws {
        let body = (1...15).map { "Line \($0)" }.joined(separator: "\n\n")
        let source = "# One\n\n\(body)\n\n# Two\n\n\(body)\n\n# Last\n\n\((1...6).map { "Tail \($0)" }.joined(separator: "\n\n"))\n"
        let fixture = try LiveFixture(source: source)
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        // 编辑器是共用的：等它换成这块工作板的内容再量。
        for _ in 0..<100 where (try? await fixture.snapshot()["source"] as? String) != source { try await Task.sleep(for: .milliseconds(20)) }
        try await browse(fixture.session, fixture.webView)
        let script = """
        const s=document.querySelector('.cm-scroller'), view=window.boardEditor.view();
        // 隐藏的测试窗口里网页几乎不出帧、计时器也被放慢：每一步之后手动测量一次、发一次滚动事件，相当于过了一帧。
        const settle=()=>{ for (let i=0;i<2;i++){ window.boardEditor.view().measure(); s.dispatchEvent(new Event('scroll')); } };
        const heading=name=>[...document.querySelectorAll('.cm-line')].find(l=>l.classList.contains('cm-foldable')&&l.textContent.includes(name));
        const top=name=>Math.round(heading(name).getBoundingClientRect().top);
        const click=el=>{const r=el.getBoundingClientRect();const o={bubbles:true,cancelable:true,clientX:r.left+r.width/2,clientY:r.top+r.height/2,button:0,detail:1};el.dispatchEvent(new MouseEvent('mousedown',o));el.dispatchEvent(new MouseEvent('mouseup',o));};
        const out={};
        // 换工作板时排着的滚动（滚到光标）先让它生效；再按文档位置滚过去（标题可能还在视口外、没画出来），最后按画出来的位置对齐。
        settle();
        s.scrollTop = view.lineBlockAt(view.state.doc.toString().indexOf('# Two')).top - 100; settle();
        for (let i=0;i<4;i++){ s.scrollTop += heading('Two').getBoundingClientRect().top - s.getBoundingClientRect().top - 100; settle(); }
        out.middle=[top('Two')];
        heading('Two').querySelector('.board-heading-fold').click(); settle(); out.middle.push(top('Two'));
        click(heading('Two')); settle(); out.middle.push(top('Two'));
        for (let i=0;i<4;i++){ s.scrollTop=s.scrollHeight; settle(); } out.bottom=[top('Last')];
        heading('Last').querySelector('.board-heading-fold').click(); settle(); out.bottom.push(top('Last'));
        click(heading('Last')); settle(); out.bottom.push(top('Last'));
        heading('Last').querySelector('.board-heading-fold').click(); settle();
        out.slack=document.querySelector('.cm-content').style.paddingBottom;
        s.scrollTop -= 400; settle();
        out.trimmed=document.querySelector('.cm-content').style.paddingBottom;
        return out;
        """
        let raw = try await fixture.webView.callAsyncJavaScript(script, contentWorld: .page)
        let result = try XCTUnwrap(raw as? [String: Any])
        let middle = try XCTUnwrap(result["middle"] as? [Int]), bottom = try XCTUnwrap(result["bottom"] as? [Int])
        XCTAssertEqual(Set(middle).count, 1, "页面中间收起 / 展开（点箭头或标题）标题不动：\(middle)")
        XCTAssertEqual(Set(bottom).count, 1, "滚到底时收起 / 展开标题也不动：\(bottom)")
        XCTAssertNotEqual(result["slack"] as? String, "", "滚到底收起时底部临时留白")
        XCTAssertEqual(result["trimmed"] as? String, "", "往上滚后留白收回")
        XCTAssertEqual(fixture.store.boards[0].markdown, source)
    }

    /// 默认的编辑是所见即所得：正文照样渲染，只有光标所在的那一行露出 Markdown 标记。
    func testLiveEditingShowsMarkupOnlyOnTheCaretLine() async throws {
        let fixture = try LiveFixture(source: "# Title\n\n**Strong**\n\nAfter")
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        try await browse(fixture.session, fixture.webView)
        _ = try await fixture.webView.evaluateJavaScript(Self.clickScript(Self.lineContaining("After"), fraction: 0.05))
        fixture.session.setMode(editing: true, raw: false)
        for _ in 0..<50 {
            if (try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-content').isContentEditable") as? Bool) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        var text = try await visibleText(fixture.webView)
        XCTAssertFalse(text.contains("# Title") || text.contains("**Strong**"), text)
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.select(2)")
        text = try await visibleText(fixture.webView)
        XCTAssertTrue(text.contains("# Title"), "光标所在的标题行露出标记")
        XCTAssertFalse(text.contains("**Strong**"))
    }

    /// 浏览时标题可以收起到下一个同级标题为止（不越过折叠块）；标题和折叠块的展开状态按工作板记住，重新打开照旧。
    func testHeadingsFoldWhileBrowsingAndFoldStateIsRemembered() async throws {
        let defaults = InMemoryDefaults()
        let fixture = try LiveFixture(source: Self.foldSource, defaults: defaults)
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        try await browse(fixture.session, fixture.webView)
        let arrows = try await fixture.webView.evaluateJavaScript("document.querySelectorAll('.board-heading-fold').length") as? Int
        XCTAssertEqual(arrows, 3, "A、A1、B 可以折叠；收起的折叠块里的标题看不到")
        _ = try await fixture.webView.evaluateJavaScript("document.querySelector('.board-heading-fold').click()")
        var text = try await visibleText(fixture.webView)
        XCTAssertFalse(text.contains("alpha") || text.contains("inside"), "A 下面的内容（含 A1 一节）都收起")
        XCTAssertTrue(text.contains("beta"), "下一个同级标题 B 不受影响")
        let more = try await fixture.webView.evaluateJavaScript("document.querySelectorAll('.board-fold-more').length") as? Int
        XCTAssertEqual(more, 1)
        if let path = ProcessInfo.processInfo.environment["TIMELINE_FOLD_SNAPSHOT"] {
            let image = try await fixture.webView.takeSnapshot(configuration: nil)
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        _ = try await fixture.webView.evaluateJavaScript("document.querySelector('.board-details').click()")
        text = try await visibleText(fixture.webView)
        XCTAssertTrue(text.contains("In details") && text.contains("hidden body"))
        let unchanged = try await fixture.snapshot()["source"] as? String
        XCTAssertEqual(unchanged, Self.foldSource, "折叠不改动正文")
        let boardID = fixture.store.boards[0].id
        let saved = defaults.dictionary(forKey: BoardLiveEditorSession.foldsKey(boardID)) as? [String: Bool]
        XCTAssertEqual(saved, ["h1:A#0": true, "d:D#0": true])

        // 重新打开同一个工作板：A 仍收起，折叠块仍展开。
        let reopened = BoardLiveEditorSession(store: fixture.store, board: fixture.store.boards[0], defaults: defaults)
        let webView = reopened.makeWebView()
        reopened.configure(fontSize: 13, dark: true, previewOnly: true)
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await waitForBoardEditor(webView)
        try await browse(reopened, webView)
        text = try await visibleText(webView)
        XCTAssertFalse(text.contains("alpha"), "收起状态被记住")
        XCTAssertTrue(text.contains("hidden body"), "折叠块的展开状态被记住")

        // 展开后不再记录（标题默认就是展开的）。
        _ = try await webView.evaluateJavaScript("document.querySelector('.board-fold-more').click()")
        text = try await visibleText(webView)
        XCTAssertTrue(text.contains("alpha"))
        let after = defaults.dictionary(forKey: BoardLiveEditorSession.foldsKey(boardID)) as? [String: Bool]
        XCTAssertEqual(after, ["d:D#0": true])
    }

    /// 搜索跳转：展开包住目标行的标题和折叠块，命中的文字高亮。
    func testRevealUnfoldsAndHighlightsTheTargetLine() async throws {
        let fixture = try LiveFixture(source: Self.foldSource)
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        try await browse(fixture.session, fixture.webView)
        _ = try await fixture.webView.evaluateJavaScript("document.querySelector('.board-heading-fold').click()")
        fixture.session.reveal(line: 7, query: "INSIDE")
        try await Task.sleep(for: .milliseconds(80))
        var hit = try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-search-hit')?.textContent") as? String
        XCTAssertEqual(hit, "inside", "大小写不同也能定位到命中的文字")
        var text = try await visibleText(fixture.webView)
        XCTAssertTrue(text.contains("alpha"), "收起的标题被展开")
        fixture.session.reveal(line: 18, query: "body")
        try await Task.sleep(for: .milliseconds(80))
        hit = try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-search-hit')?.textContent") as? String
        XCTAssertEqual(hit, "body")
        text = try await visibleText(fixture.webView)
        XCTAssertTrue(text.contains("hidden body"), "收起的折叠块被展开")
        let unchanged = try await fixture.snapshot()["source"] as? String
        XCTAssertEqual(unchanged, Self.foldSource)
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
    let window: NSWindow
    /// 当前的编辑器视图（迟迟没就绪被重建过就是新的那个，同时放进测试窗口）。
    var webView: WKWebView {
        guard let view = session.webView else { return window.contentView as? WKWebView ?? WKWebView() }
        if window.contentView !== view { window.contentView = view }
        return view
    }
    let pasteboard = NSPasteboard(name: .init("board-editor-\(UUID().uuidString)"))
    let defaults: UserDefaults

    init(source: String, defaults: UserDefaults = InMemoryDefaults()) throws {
        self.defaults = defaults
        store = JournalStore(directory: directory)
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Editor")))
        store.setBoardMarkdown(source, for: board.id)
        store.save()
        session = BoardLiveEditorSession(store: store, board: try XCTUnwrap(store.board(for: board.owner)), pasteboard: pasteboard,
                                         defaults: defaults)
        let webView = session.makeWebView()
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
