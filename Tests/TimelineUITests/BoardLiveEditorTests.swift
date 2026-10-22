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
    func testBrowsingHidesCursorBeforeSavingAndKeepsItHiddenWhenFocusReturns() async throws {
        let fixture = try LiveFixture(source: "# Title\n\n- [ ] Task\n\nEnd", vim: true)
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        _ = try await fixture.webView.evaluateJavaScript("""
        document.hasFocus=()=>true;
        window.writeStates=[];
        const handler=window.webkit.messageHandlers.boardEditor;
        const original=handler.postMessage.bind(handler);
        handler.postMessage=message=>{
          if(message.kind==='mode'||message.kind==='write') window.writeStates.push({
            kind:message.kind,browsing:window.boardEditor.snapshot().browsing,
            hidden:[...document.querySelectorAll('.cm-cursorLayer')].every(e=>getComputedStyle(e).display==='none')
          });
          original(message);
        };
        window.boardEditor.focus();
        """)
        try await fixture.writeCommand()
        let states = try await fixture.webView.evaluateJavaScript("window.writeStates") as? [[String: Any]] ?? []
        XCTAssertEqual(states.compactMap { $0["kind"] as? String }, ["mode", "write"])
        XCTAssertTrue(states.allSatisfy { $0["browsing"] as? Bool == true && $0["hidden"] as? Bool == true })
        for _ in 0..<3 {
            fixture.window.resignKey()
            _ = try await fixture.webView.evaluateJavaScript("document.activeElement?.blur();window.boardEditor.view().dispatch({})")
            try await Task.sleep(for: .milliseconds(30))
            fixture.window.makeKey()
            _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.focus();window.boardEditor.select(0);window.boardEditor.view().measure()")
            try await Task.sleep(for: .milliseconds(30))
            let state = try await fixture.webView.evaluateJavaScript("""
            ({browsing:window.boardEditor.snapshot().browsing,
              hidden:[...document.querySelectorAll('.cm-cursorLayer')].every(e=>getComputedStyle(e).display==='none'),
              caret:getComputedStyle(document.querySelector('.cm-content')).caretColor==='rgba(0, 0, 0, 0)',
              readonly:window.boardEditor.view().state.readOnly,
              labelled:document.querySelector('.cm-content').getAttribute('aria-label').includes('i')})
            """) as? [String: Bool]
            XCTAssertEqual(state, ["browsing": true, "hidden": true, "caret": true, "readonly": true, "labelled": true])
        }
        _ = try await fixture.pressKey("i")
        let editing = try await fixture.webView.evaluateJavaScript("!window.boardEditor.snapshot().browsing&&document.querySelector('.cm-content').isContentEditable&&[...document.querySelectorAll('.cm-cursorLayer')].some(e=>getComputedStyle(e).display!=='none')") as? Bool
        XCTAssertEqual(editing, true)
    }

    func testVimWriteSavesToDiskAndBrowsesUntilExplicitInsert() async throws {
        let source = "# Title\n\n**Body** [Paper](https://example.com)\n\n<details>\n<summary>Agenda</summary>\n\nDiscussion\n\n</details>\n\n- [ ] Task\n\n```\ncode\n```\n\nEnd"
        let fixture = try LiveFixture(source: source, vim: true)
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.focus();window.boardEditor.select(2)")
        _ = try await fixture.pressKey("i")
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.replaceSelection('New ')")
        _ = try await fixture.pressKey("Escape")
        try await fixture.writeCommand()
        XCTAssertTrue(fixture.session.browsing)
        let saved = try await fixture.snapshot()
        XCTAssertEqual(saved["source"] as? String, source.replacingOccurrences(of: "# Title", with: "# New Title"))
        XCTAssertEqual(JournalStore(directory: fixture.directory).boards[0].markdown, saved["source"] as? String)
        let rendered = try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-content').textContent") as? String ?? ""
        XCTAssertFalse(rendered.contains("# New"))
        XCTAssertFalse(rendered.contains("**Body**"))
        let readonly = try await fixture.webView.evaluateJavaScript("({readonly:window.boardEditor.view().state.readOnly,editable:document.querySelector('.cm-content').isContentEditable,hidden:[...document.querySelectorAll('.cm-cursorLayer')].every(e=>getComputedStyle(e).display==='none')})") as? [String: Bool]
        XCTAssertEqual(readonly, ["readonly": true, "editable": false, "hidden": true])
        _ = try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-heading-1').dispatchEvent(new MouseEvent('mousedown',{bubbles:true,button:0}));document.querySelector('.cm-heading-1').dispatchEvent(new MouseEvent('dblclick',{bubbles:true,button:0}));window.boardEditor.select(4);window.boardEditor.replaceSelection('ACCIDENTAL')")
        _ = try await fixture.pressKey("d")
        _ = try await fixture.pressKey("d")
        let afterClick = try await fixture.snapshot()
        XCTAssertEqual(afterClick["source"] as? String, saved["source"] as? String)
        XCTAssertEqual(afterClick["browsing"] as? Bool, true)
        fixture.session.configure(vim: true, fontSize: 14, dark: false, sourceMode: true)
        try await Task.sleep(for: .milliseconds(50))
        let stillRendered = try await fixture.webView.evaluateJavaScript("!document.querySelector('.cm-content').textContent.includes('# New')") as? Bool
        XCTAssertEqual(stillRendered, true)
        _ = try await fixture.pressKey("i")
        let editing = try await fixture.webView.evaluateJavaScript("({insert:window.boardEditor.view().cm.state.vim.insertMode,editable:document.querySelector('.cm-content').isContentEditable,browsing:window.boardEditor.snapshot().browsing})") as? [String: Bool]
        XCTAssertEqual(editing, ["insert": true, "editable": true, "browsing": false])
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.replaceSelection('Edited ')")
        let changed = try await fixture.snapshot()
        XCTAssertTrue((changed["source"] as? String)?.contains("Edited ") == true)
        _ = try await fixture.pressKey("Escape")
        try await fixture.writeCommand("write")
        XCTAssertTrue(fixture.session.browsing)
        fixture.session.beginEditing()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(fixture.session.browsing)
        fixture.session.saveAndBrowse()
        try await Task.sleep(for: .milliseconds(50))
        fixture.session.webViewWebContentProcessDidTerminate(fixture.webView)
        for _ in 0..<200 {
            if fixture.webView.isLoading { try await Task.sleep(for: .milliseconds(10)) }
            else { break }
        }
        try await waitForBoardEditor(fixture.webView)
        let restored = try await fixture.snapshot()
        XCTAssertEqual(restored["browsing"] as? Bool, true)
        XCTAssertEqual(restored["source"] as? String, changed["source"] as? String)
    }

    func testBrowsingKeepsLinksTasksFoldsAndCopyUsableWithoutEnteringEdit() async throws {
        let source = "[Paper](https://example.com)\n\n<details>\n<summary>Agenda</summary>\n\n**Discussion**\n\n</details>\n\n- [ ] Task\n\n```\ncode\n```\n\nEnd"
        let fixture = try LiveFixture(source: source, vim: true)
        defer { fixture.close() }
        let (activate, launch) = (SafariLinks.activateExistingTab, SafariLinks.launch)
        defer { SafariLinks.activateExistingTab = activate; SafariLinks.launch = launch }
        var opened: [URL] = []
        SafariLinks.activateExistingTab = { opened.append($0); return true }
        SafariLinks.launch = { _ in XCTFail("Should reuse Safari tab") }
        try await waitForBoardEditor(fixture.webView)
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.focus()")
        try await fixture.writeCommand()
        _ = try await fixture.webView.evaluateJavaScript("document.querySelector('[data-url]').dispatchEvent(new MouseEvent('click',{bubbles:true}));document.querySelector('.board-details').click();document.querySelector('.board-details').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));document.querySelector('.board-check').click();document.querySelector('.board-copy-code').click()")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com"])
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "code\n")
        let state = try await fixture.webView.evaluateJavaScript("({browsing:window.boardEditor.snapshot().browsing,open:document.querySelector('.board-details').getAttribute('aria-expanded')==='true',editable:document.querySelector('.cm-content').isContentEditable,raw:document.querySelector('.cm-content').textContent.includes('<summary>')})") as? [String: Bool]
        XCTAssertEqual(state, ["browsing": true, "open": true, "editable": false, "raw": false])
        XCTAssertEqual(fixture.store.boards[0].markdown, source.replacingOccurrences(of: "- [ ]", with: "- [x]"))
        _ = try await fixture.pressKey("i")
        _ = try await fixture.pressKey("Escape")
        fixture.session.saveAndBrowse()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(fixture.session.browsing)
        _ = try await fixture.pressKey("v")
        _ = try await fixture.pressKey("l")
        _ = try await fixture.pressKey("i")
        let resumedInsert = try await fixture.webView.evaluateJavaScript("window.boardEditor.view().cm.state.vim.insertMode&&!window.boardEditor.view().cm.state.vim.visualMode") as? Bool
        XCTAssertEqual(resumedInsert, true)
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
        let rightAligned = try await fixture.webView.evaluateJavaScript("getComputedStyle(document.querySelector('.board-copy-code')).float === 'right'") as? Bool
        XCTAssertEqual(rightAligned, true)
        _ = try await fixture.webView.evaluateJavaScript("(()=>{const editor=window.boardEditor;const start=editor.snapshot().source.indexOf('1');editor.select(start,start+1);editor.replaceSelection('42')})()")
        let before = try await fixture.snapshot()
        _ = try await fixture.webView.evaluateJavaScript("document.querySelector('.board-copy-code').click()")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "  let value = 42\n\n  print(value)\n")
        let feedback = try await fixture.webView.evaluateJavaScript("document.querySelector('.board-copy-code').dataset.copied") as? String
        XCTAssertEqual(feedback, "true")
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
        fixture.session.configure(vim: false, fontSize: 13, dark: false, sourceMode: true)
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

    func testTypingPreservesCaretThroughStoreRefreshAndTemplateUndo() async throws {
        let fixture = try LiveFixture(source: "Before\n\nBody\n\nAfter")
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.select(8,12);window.boardEditor.replaceSelection('中文 body')")
        let before = try await fixture.snapshot()
        fixture.session.configure(vim: false, fontSize: 13, dark: true)
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

    func testVimNormalInsertAndUndoRemainActiveAfterAutosave() async throws {
        let fixture = try LiveFixture(source: "one two\nthree\n", vim: true)
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.focus();window.boardEditor.select(0)")
        func key(_ key: String) async throws {
            let json = String(decoding: try JSONEncoder().encode(key), as: UTF8.self)
            _ = try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:\(json),bubbles:true,cancelable:true}))")
        }
        try await key("w")
        let moved = try await fixture.snapshot()
        XCTAssertEqual(moved["head"] as? Int, 4)
        try await key("i")
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.replaceSelection('VIM ')")
        try await key("Escape")
        await fixture.commit()
        fixture.session.configure(vim: true, fontSize: 13, dark: true)
        try await key("0")
        let start = try await fixture.snapshot()
        XCTAssertEqual(start["head"] as? Int, 0)
        try await key("u")
        let undone = try await fixture.snapshot()
        XCTAssertEqual(undone["source"] as? String, "one two\nthree\n")
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

    func testControlBracketAndRepeatedEscapeKeepVimNormalAndDisclosuresOpen() async throws {
        let source = "<details open>\n<summary>Agenda</summary>\n\nDiscussion\n\n</details>\n\nEnd"
        let fixture = try LiveFixture(source: source, vim: true)
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.focus()")
        for mode in ["i", "v"] {
            _ = try await fixture.pressKey(mode)
            let controlBracketHandled = try await fixture.pressKey("[", control: true)
            XCTAssertTrue(controlBracketHandled)
            let normal = try await fixture.webView.evaluateJavaScript("(()=>{const vim=window.boardEditor.view().cm.state.vim;return !vim.insertMode&&!vim.visualMode})()") as? Bool
            XCTAssertEqual(normal, true)
        }
        _ = try await fixture.pressKey("i")
        for _ in 0..<3 {
            let escapeHandled = try await fixture.pressKey("Escape")
            XCTAssertTrue(escapeHandled)
        }
        _ = try await fixture.pressKey("v")
        _ = try await fixture.pressKey("l")
        _ = try await fixture.pressKey("Escape")
        let state = try await fixture.webView.evaluateJavaScript("({normal:!window.boardEditor.view().cm.state.vim.insertMode&&!window.boardEditor.view().cm.state.vim.visualMode,focused:document.activeElement===document.querySelector('.cm-content'),open:document.querySelector('.board-details').getAttribute('aria-expanded')==='true'})") as? [String: Bool]
        XCTAssertEqual(state, ["normal": true, "focused": true, "open": true])
        let snapshot = try await fixture.snapshot()
        XCTAssertEqual(snapshot["source"] as? String, source)
        fixture.session.configure(vim: false, fontSize: 13, dark: true)
        try await Task.sleep(for: .milliseconds(30))
        let escapeHandled = try await fixture.pressKey("Escape")
        XCTAssertTrue(escapeHandled)
    }

    func testCursorsRemainVisibleWithStrongContrastInBothAppearances() async throws {
        let fixture = try LiveFixture(source: "Cursor visibility", vim: true)
        defer { fixture.close() }
        try await waitForBoardEditor(fixture.webView)
        for dark in [true, false] {
            fixture.session.configure(vim: true, fontSize: 13, dark: dark)
            _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.focus();window.boardEditor.select(3);window.boardEditor.view().measure();window.boardEditor.view().dom.classList.add('cm-focused')")
            try await Task.sleep(for: .milliseconds(60))
            let normal = try await fixture.webView.evaluateJavaScript("(()=>{const cursor=document.querySelector('.cm-fat-cursor');if(!cursor)return {contrast:false,visible:false};const style=getComputedStyle(cursor);const contentStyle=getComputedStyle(document.querySelector('.cm-content'));return {contrast:style.backgroundColor===contentStyle.color&&style.color!==style.backgroundColor,visible:cursor.getBoundingClientRect().width>2&&getComputedStyle(cursor.parentElement).animationName==='none'}})()") as? [String: Bool]
            XCTAssertEqual(normal, ["contrast": true, "visible": true])
            _ = try await fixture.pressKey("i")
            try await Task.sleep(for: .milliseconds(60))
            _ = try await fixture.webView.evaluateJavaScript("window.boardEditor.view().measure();window.boardEditor.view().dom.classList.add('cm-focused')")
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
        fixture.session.configure(vim: false, fontSize: 13, dark: true, sourceMode: true)
        try await Task.sleep(for: .milliseconds(40))
        let raw = try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-content').textContent") as? String
        XCTAssertTrue(raw?.contains("# Title") == true)
        XCTAssertTrue(raw?.contains("**Strong**") == true)
        fixture.session.configure(vim: false, fontSize: 13, dark: true)
        try await Task.sleep(for: .milliseconds(40))
        let rendered = try await fixture.webView.evaluateJavaScript("document.querySelector('.cm-content').textContent") as? String
        XCTAssertFalse(rendered?.contains("# Title") == true)
        let selection = try await fixture.snapshot()
        XCTAssertEqual(selection["head"] as? Int, 23)
        fixture.store.setBoardMarkdown("# Updated\n\nExternal\n\nAfter", for: fixture.store.boards[0].id)
        fixture.session.configure(vim: false, fontSize: 13, dark: true)
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

    init(source: String, vim: Bool = false) throws {
        store = JournalStore(directory: directory)
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Editor")))
        store.setBoardMarkdown(source, for: board.id)
        store.save()
        session = BoardLiveEditorSession(store: store, board: try XCTUnwrap(store.board(for: board.owner)), pasteboard: pasteboard)
        webView = session.makeWebView()
        session.configure(vim: vim, fontSize: 13, dark: true)
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

    func writeCommand(_ command: String = "w") async throws {
        _ = try await pressKey(":")
        let json = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
        _ = try await webView.evaluateJavaScript("(()=>{const input=document.querySelector('.cm-vim-panel input');if(!input)throw new Error('Missing Vim command input');input.value=\(json);input.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:13,bubbles:true,cancelable:true}))})()")
        try await Task.sleep(for: .milliseconds(100))
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
