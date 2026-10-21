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

    init(source: String, vim: Bool = false) throws {
        store = JournalStore(directory: directory)
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Editor")))
        store.setBoardMarkdown(source, for: board.id)
        store.save()
        session = BoardLiveEditorSession(store: store, board: try XCTUnwrap(store.board(for: board.owner)))
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

    func commit() async {
        await withCheckedContinuation { continuation in session.commit { continuation.resume() } }
    }

    func close() {
        session.flush()
        window.contentView = nil
        window.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
