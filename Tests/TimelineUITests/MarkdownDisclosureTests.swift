import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class MarkdownDisclosureTests: XCTestCase {
    func testNestedDetailsPreserveMarkdownAndAbsoluteTaskLines() throws {
        let source = "开头\n\n<details>\n<summary>Outer &amp; 中文</summary>\n\n- [ ] First\n\n<details open><summary>Nested</summary>\n\n- [x] Second\n\n</details>\n\n</details>\n\n结尾"
        let nodes = MarkdownDisclosures.parse(source)
        XCTAssertEqual(nodes.count, 3)
        guard case .disclosure(let outer) = nodes[1] else { return XCTFail("Missing outer disclosure") }
        XCTAssertEqual(outer.title, "Outer & 中文")
        XCTAssertFalse(outer.initiallyOpen)
        XCTAssertEqual(outer.children.count, 2)
        guard case .markdown(let first) = outer.children[0],
              case .disclosure(let nested) = outer.children[1],
              case .markdown(let second) = nested.children.first else { return XCTFail("Missing nested body") }
        XCTAssertTrue(nested.initiallyOpen)
        XCTAssertEqual(first.lineOffset, 4)
        XCTAssertEqual(second.lineOffset, 8)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Reading")))
        store.setBoardMarkdown(source, for: board.id)
        let rendered = MarkdownText.render(second.source, color: .labelColor, fontSize: 13, interactiveTasks: true)
        var line: Int?
        rendered.enumerateAttribute(MarkdownText.taskLineKey, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if let value = value as? Int { line = value + second.lineOffset }
        }
        XCTAssertEqual(line, 10)
        store.toggleBoardMarkdownTask(atLine: try XCTUnwrap(line), in: board.id)
        XCTAssertEqual(store.boards[0].markdown, source.replacingOccurrences(of: "- [x] Second", with: "- [ ] Second"))
    }

    func testFencedIndentedAndUnclosedExamplesStayLiteral() throws {
        let source = "~~~html\n<details>\n<summary>Example</summary>\nbody\n</details>\n~~~\n\n    <details>\n    <summary>Indented</summary>\n    body\n    </details>\n\n<details>\n<summary>Unclosed</summary>\nKeep this text"
        let nodes = MarkdownDisclosures.parse(source)
        XCTAssertEqual(nodes.count, 3)
        guard case .code(let fenced) = nodes[0], case .code(let indented) = nodes[1],
              case .markdown(let fragment) = nodes[2] else { return XCTFail("Expected literal code and unclosed Markdown") }
        XCTAssertEqual(fenced.language, "html")
        XCTAssertEqual(fenced.content, "<details>\n<summary>Example</summary>\nbody\n</details>\n")
        XCTAssertTrue(indented.content.contains("<summary>Indented</summary>"))
        XCTAssertTrue(fragment.source.contains("<summary>Unclosed</summary>"))
        XCTAssertEqual(fragment.lineOffset, 12)
    }

    func testCodeInsideDisclosureHasNoFencesAndPreservesFollowingTaskLine() throws {
        let source = "<details open><summary>Title</summary>\n\n```swift\nlet value = 42\n```\n\n- [ ] Action\n\n</details>\n\n~~~text\nunclosed\n"
        let nodes = MarkdownDisclosures.parse(source)
        guard case .disclosure(let disclosure) = nodes[0], case .code(let code) = disclosure.children[0],
              case .markdown(let task) = disclosure.children[1], case .code(let unclosed) = nodes[1] else {
            return XCTFail("Missing native code blocks")
        }
        XCTAssertEqual(code.language, "swift")
        XCTAssertEqual(code.content, "let value = 42\n")
        XCTAssertEqual(code.id, 2)
        XCTAssertEqual(unclosed.content, "unclosed\n")
        let rendered = MarkdownText.render(task.source, color: .labelColor, fontSize: 13, interactiveTasks: true)
        var absoluteLine: Int?
        rendered.enumerateAttribute(MarkdownText.taskLineKey, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if let line = value as? Int { absoluteLine = task.lineOffset + line }
        }
        XCTAssertEqual(absoluteLine, 7)
    }

    func testNativeCodeAndLongDisclosureTitleFitWithoutTruncation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Preview")))
        let title = String(repeating: "完整显示折叠内容的标题和阅读目标", count: 4)
        store.setBoardMarkdown("## Reading\n\n```swift\nlet answer = 42\nprint(answer)\n```\n\n<details open><summary>\(title)</summary>\n\n- [ ] Action\n\n</details>", for: board.id)
        let cache = MarkdownDisclosureCache()
        let host = NSHostingView(rootView: DisclosureHarness(store: store, cache: cache).padding(12))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 500),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 230)
        XCTAssertLessThan(host.fittingSize.height, 500)
        if let path = ProcessInfo.processInfo.environment["TIMELINE_NATIVE_BOARD_SNAPSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    func testCRLFOpenAttributeEmptyBodyAndPlainMarkdownRemainIntact() throws {
        let source = "<details open=\"open\">\r\n<summary>Title</summary>\r\n</details>\r\n\r\n# After\r\n"
        let nodes = MarkdownDisclosures.parse(source)
        XCTAssertEqual(nodes.count, 2)
        guard case .disclosure(let disclosure) = nodes[0], case .markdown(let after) = nodes[1] else {
            return XCTFail("Missing disclosure or trailing Markdown")
        }
        XCTAssertTrue(disclosure.initiallyOpen)
        XCTAssertTrue(disclosure.children.isEmpty)
        XCTAssertEqual(after.lineOffset, 3)
        XCTAssertTrue(after.source.contains("# After\r\n"))
        let plain = "# Header\n\n- [ ] Task\n\n[Link](https://example.com)\n"
        guard case .markdown(let original) = MarkdownDisclosures.parse(plain).first else { return XCTFail("Missing Markdown") }
        XCTAssertEqual(original.source, plain)
    }

    func testTemplateWrapsSelectionKeepsSurroundingTextAndSelectsTitle() throws {
        let source = "Before\n\nSelected 中文\n\nAfter"
        let range = (source as NSString).range(of: "Selected 中文")
        let result = BoardMarkdownTemplate.disclosure.insertion(into: source, selection: range)
        XCTAssertTrue(result.source.hasPrefix("Before\n\n<details>"))
        XCTAssertTrue(result.source.hasSuffix("</details>\n\nAfter"))
        XCTAssertTrue(result.source.contains("\n\nSelected 中文\n\n"))
        XCTAssertEqual((result.source as NSString).substring(with: result.selectedRange), AppLocalized("折叠标题"))
        let appended = BoardMarkdownTemplate.disclosure.insertion(into: "Existing")
        XCTAssertTrue(appended.source.hasPrefix("Existing\n\n<details>"))
        XCTAssertTrue(appended.source.contains(AppLocalized("在这里填写内容，支持 Markdown、链接和待办。")))
    }

    func testTemplateInsertsAtNativeEditorSelectionAndUndoRestoresTheDocument() throws {
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        editor.isRichText = false
        editor.allowsUndo = true
        editor.string = "Before\n\nBody\n\nAfter"
        let window = QuietWindow(contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        defer { window.contentView = nil; window.close() }
        editor.setSelectedRange((editor.string as NSString).range(of: "Body"))
        let original = editor.string
        XCTAssertTrue(BoardMarkdownTemplate.disclosure.insert(into: editor))
        XCTAssertTrue(editor.string.contains("\n\nBody\n\n</details>"))
        XCTAssertEqual((editor.string as NSString).substring(with: editor.selectedRange()), AppLocalized("折叠标题"))
        XCTAssertTrue(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, original)
    }

    func testPreviewShowsOnlyOneSummaryLineUntilExpanded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Reading")))
        let source = "<details>\n<summary>Reading goals</summary>\n\n- [ ] Intro\n\n[Paper](https://example.com)\n\n</details>"
        store.setBoardMarkdown(source, for: board.id)
        let cache = MarkdownDisclosureCache()
        let host = NSHostingView(rootView: DisclosureHarness(store: store, cache: cache).padding(12))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        func texts(_ view: NSView) -> [InteractiveTaskText] {
            (view as? InteractiveTaskText).map { [$0] } ?? view.subviews.flatMap(texts)
        }
        XCTAssertTrue(texts(host).isEmpty)
        XCTAssertLessThan(host.fittingSize.height, 70)
        guard case .disclosure(let disclosure) = cache.parse(source).first else { return XCTFail("Missing disclosure") }
        XCTAssertFalse(cache.isExpanded(disclosure))
        cache.toggle(disclosure)
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        let body = try XCTUnwrap(texts(host).first)
        XCTAssertTrue(body.string.contains("Intro"))
        XCTAssertEqual(body.taskRegions().first?.line, 2)
        XCTAssertEqual(store.boards[0].markdown, source)
        let circle = try XCTUnwrap(body.taskRegions().first)
        body.activate(at: NSPoint(x: circle.rect.midX, y: circle.rect.midY))
        XCTAssertEqual(store.boards[0].markdown, source.replacingOccurrences(of: "- [ ] Intro", with: "- [x] Intro"))
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(cache.isExpanded(disclosure))
        XCTAssertTrue(texts(host).contains { $0.source?.contains("- [x] Intro") == true })
        if let destination = ProcessInfo.processInfo.environment["TIMELINE_DISCLOSURE_SNAPSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination))
        }
        cache.toggle(disclosure)
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(texts(host).filter { !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty }.isEmpty)
    }
}

private struct DisclosureHarness: View {
    @ObservedObject var store: JournalStore
    let cache: MarkdownDisclosureCache

    var body: some View {
        if let board = store.boards.first {
            BoardMarkdownPreview(store: store, board: board, cache: cache)
        }
    }
}
