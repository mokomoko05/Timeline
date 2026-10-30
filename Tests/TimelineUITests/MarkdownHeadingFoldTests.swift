import AppKit
import SwiftUI
import TimelineCore
import XCTest
@testable import Timeline

/// 笔记里的 Markdown 标题和工作板一样可以折叠：收起到下一个同级或更高级标题为止，点标题右边的按钮切换，状态按笔记记住。
@MainActor
final class MarkdownHeadingFoldTests: XCTestCase {
    private let source = "# A\n\nalpha\n\n## A1\n\ninside\n\n# B\n\nbeta\n\n# Empty\n# A\n\nagain"

    private func render(_ folds: Set<String>?) -> NSAttributedString {
        MarkdownText.render(source, color: .labelColor, fontSize: 13, folds: folds)
    }

    private func keys(_ text: NSAttributedString) -> [String] {
        var result: [String] = []
        text.enumerateAttribute(MarkdownText.headingFoldKey, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let key = value as? String { result.append(key) }
        }
        return result
    }

    func testOnlyHeadingsWithContentAreFoldableAndKeysMatchTheBoard() {
        XCTAssertEqual(keys(render([])), ["h1:A#0", "h2:A1#0", "h1:B#0", "h1:A#1"], "没有内容的标题不能折叠；同名标题按次序编号")
        XCTAssertTrue(keys(render(nil)).isEmpty, "没有折叠标识时和以前一样")
    }

    func testFoldingHidesTheSectionUpToTheNextHeadingOfTheSameLevel() {
        let folded = render(["h1:A#0"]).string
        XCTAssertFalse(folded.contains("alpha") || folded.contains("inside") || folded.contains("A1"), "A 下面（含 A1 一节）都收起")
        XCTAssertTrue(folded.contains("beta") && folded.contains("again"))
        XCTAssertFalse(folded.contains("⋯"), "收起不再在标题后面加「⋯」，状态看右边的按钮")
        let inner = render(["h2:A1#0"]).string
        XCTAssertTrue(inner.contains("alpha") && !inner.contains("inside") && inner.contains("beta"))
    }

    func testTheButtonRightOfTheHeadingTogglesAndIsRememberedPerNote() {
        let defaults = InMemoryDefaults()
        let previous = HeadingFolds.defaults
        HeadingFolds.defaults = defaults
        defer { HeadingFolds.defaults = previous }

        let view = InteractiveTaskText(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
        view.markdown = true
        var toggled: [String] = []
        view.onToggleHeading = { key in toggled.append(key); HeadingFolds.toggle(key, in: "log.1") }
        view.textStorage?.setAttributedString(render([]))
        let regions = view.headingRegions()
        let first = try? XCTUnwrap(regions.first { $0.key == "h1:A#0" })
        XCTAssertNotNil(first)
        if let first {
            XCTAssertGreaterThan(first.rect.width, 18, "按钮够大")
            XCTAssertGreaterThan(first.rect.minX, 300, "按钮在标题行的最右边")
            XCTAssertEqual(view.headingKey(at: NSPoint(x: first.rect.midX, y: first.rect.midY)), "h1:A#0")
            XCTAssertNil(view.headingKey(at: NSPoint(x: 20, y: first.rect.midY)), "点标题文字不收起，留给选择和编辑")
        }
        if let path = ProcessInfo.processInfo.environment["TIMELINE_NOTE_FOLD_SNAPSHOT"] {
            view.textStorage?.setAttributedString(render(["h2:A1#0"]))
            view.appearance = NSAppearance(named: .darkAqua)
            view.drawsBackground = true
            view.backgroundColor = .windowBackgroundColor
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        view.onToggleHeading?("h1:A#0")
        XCTAssertEqual(HeadingFolds.folded(in: "log.1"), ["h1:A#0"])
        XCTAssertTrue(HeadingFolds.folded(in: "log.2").isEmpty, "按笔记分别记住")
        view.onToggleHeading?("h1:A#0")
        XCTAssertNil(defaults.object(forKey: HeadingFolds.key("log.1")), "展开后不再记录")
    }

    /// 工作板正文的折叠范围和键与编辑器一致：到下一个同级或更高级标题为止，不越过折叠块，末尾空行不算。
    /// 标题上快速连点：第二下（双击）也收起 / 展开，不进入编辑。
    func testDoubleClickOnAHeadingTogglesInsteadOfEditing() throws {
        let view = InteractiveTaskText(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
        view.markdown = true
        var toggled: [String] = []
        var edited = false
        view.onToggleHeading = { toggled.append($0) }
        view.onEdit = { edited = true }
        view.textStorage?.setAttributedString(render([]))
        let region = try XCTUnwrap(view.headingRegions().first { $0.key == "h1:A#0" })
        let window = QuietWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        let point = view.convert(NSPoint(x: region.rect.midX, y: region.rect.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        view.mouseDown(with: event)
        XCTAssertEqual(toggled, ["h1:A#0"])
        XCTAssertFalse(edited)
    }

    func testBoardFoldLayoutMatchesTheEditor() {
        let board = "# A\n\nalpha\n\n## A1\n\ninside\n\n# B\n\nbeta\n\n<details>\n<summary>D</summary>\n\n## In details\n\nhidden body\n\n</details>\n\n```\n# not a heading\n```\n# **Bold** title ##\n"
        let layout = BoardFoldLayout(board)
        XCTAssertEqual(layout.headings.map(\.key), ["h1:A#0", "h2:A1#0", "h1:B#0", "h2:In details#0"])
        XCTAssertEqual(layout.headings.map(\.lastLine), [6, 6, 23, 17])
        XCTAssertEqual(layout.disclosureKeys, [12: "d:D#0"])
        XCTAssertEqual(layout.hiddenRanges(["h1:A#0": true, "h2:A1#0": false]), [1...6])
        XCTAssertEqual(BoardFoldLayout("# **Bold** title ##\nbody").headings.map(\.key), ["h1:**Bold** title#0"], "标题文字取原文，和编辑器一样")
    }

    /// 引用里的标题也能折叠：只管到这个引用的结尾，不吞掉引用外面的内容，键和编辑器一样（同名标题在整篇里按次序编号）。
    func testHeadingsInsideQuotesFoldWithinTheQuote() {
        let quoted = "# A\n\ntop\n\n> ## A\n> inner\n>\n> ## B\n> second\n\nafter\n\n## A\n\nlast"
        func text(_ folds: Set<String>) -> NSAttributedString { MarkdownText.render(quoted, color: .labelColor, fontSize: 13, folds: folds) }
        XCTAssertEqual(keys(text([])), ["h1:A#0", "h2:A#0", "h2:B#0", "h2:A#1"])
        let folded = text(["h2:A#0"]).string
        XCTAssertFalse(folded.contains("inner"))
        XCTAssertTrue(folded.contains("second") && folded.contains("after") && folded.contains("top") && folded.contains("last"))
        XCTAssertEqual(keys(MarkdownText.render(quoted, color: .labelColor, fontSize: 13, folds: ["h1:A#0"])), ["h1:A#0"], "外层收起时里面的标题不画")
        XCTAssertEqual(keys(text(["h2:A#0"])), ["h1:A#0", "h2:A#0", "h2:B#0", "h2:A#1"], "收起不改变后面同名标题的编号")

        let view = InteractiveTaskText(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
        view.markdown = true
        view.onToggleHeading = { _ in }
        view.textStorage?.setAttributedString(text([]))
        let regions = view.headingRegions()
        XCTAssertEqual(regions.map(\.key).sorted(), ["h1:A#0", "h2:A#0", "h2:A#1", "h2:B#0"], "引用里的标题也有按钮")
        let inQuote = regions.first { $0.key == "h2:B#0" }
        XCTAssertLessThan(inQuote?.rect.maxX ?? .infinity, 360, "按钮在引用框里")
        if let path = ProcessInfo.processInfo.environment["TIMELINE_QUOTE_FOLD_SNAPSHOT"] {
            view.appearance = NSAppearance(named: .darkAqua)
            view.drawsBackground = true
            view.backgroundColor = .windowBackgroundColor
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }

        let board = BoardFoldLayout(quoted)
        XCTAssertEqual(board.headings.map(\.key), ["h1:A#0", "h2:A#0", "h2:B#0", "h2:A#1"], "和编辑器的键一样")
        XCTAssertEqual(board.headings.map(\.lastLine), [14, 5, 8, 14], "引用里的标题不越过引用；引用外的标题不被引用里的标题打断")
        XCTAssertEqual(BoardFoldLayout("> ```\n> # not a heading\n> ```\n> # Real\n> body").headings.map(\.key), ["h1:Real#0"], "引用里的代码块不算标题")
        XCTAssertEqual(BoardFoldLayout("> # T\n>\n\nafter").headings.map(\.key), [], "标题下面只有空的 > 行：没有东西可收")
    }

    /// 笔记里的看板内容和工作板共用折叠记忆：工作板里收起的标题在这里也收起，这里点标题，工作板那边也跟着变。
    func testBoardPreviewInNotesFollowsTheBoardsFolds() async throws {
        let defaults = InMemoryDefaults()
        let previous = BoardFolds.defaults
        BoardFolds.defaults = defaults
        defer { BoardFolds.defaults = previous }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Folds")))
        store.setBoardMarkdown("# A\n\nalpha\n\n```\ncode under A\n```\n\nafter code\n\n# B\n\nbeta\n\n<details>\n<summary>D</summary>\n\nhidden body\n\n</details>\n", for: board.id)
        BoardFolds.set("h1:A#0", true, board: board.id)
        BoardFolds.set("d:D#0", true, board: board.id)
        let host = NSHostingView(rootView: BoardMarkdownPreview(store: store, board: try XCTUnwrap(store.boards.first)).frame(width: 380).padding(12))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        func visibleText() async throws -> String {
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            func texts(_ view: NSView) -> [InteractiveTaskText] {
                (view as? InteractiveTaskText).map { [$0] } ?? view.subviews.flatMap(texts)
            }
            return texts(host).filter { !$0.isHiddenOrHasHiddenAncestor && $0.frame.height > 1 }.map(\.string).joined(separator: "\n")
        }
        var text = try await visibleText()
        XCTAssertFalse(text.contains("alpha") || text.contains("after code"), "工作板里收起的 A 在这里也收起（跨过代码块）")
        XCTAssertTrue(text.contains("A") && text.contains("beta"))
        XCTAssertTrue(text.contains("hidden body"), "工作板里展开的折叠块在这里也展开")

        // 工作板那边展开 A：这里跟着展开。
        BoardFolds.set("h1:A#0", false, board: board.id)
        text = try await visibleText()
        XCTAssertTrue(text.contains("alpha") && text.contains("after code"))

        // 这里收起 B：存进工作板的折叠记忆。
        let notified = expectation(forNotification: .boardFoldsChanged, object: nil)
        let view = try XCTUnwrap({ () -> InteractiveTaskText? in
            func texts(_ view: NSView) -> [InteractiveTaskText] { (view as? InteractiveTaskText).map { [$0] } ?? view.subviews.flatMap(texts) }
            return texts(host).first { $0.string.contains("beta") }
        }())
        view.onToggleHeading?("h1:B#0")
        await fulfillment(of: [notified], timeout: 1)
        XCTAssertEqual(BoardFolds.load(board.id), ["d:D#0": true, "h1:B#0": true])
        text = try await visibleText()
        XCTAssertFalse(text.contains("beta") || text.contains("hidden body"))
    }

    /// 笔记、日记里的标题收起 / 展开时也留在原来的位置；滚到底时收起，底部临时留白撑住，不往下跳。
    func testNativeHeadingStaysInPlaceWhenFoldingAtTheBottom() async throws {
        let defaults = InMemoryDefaults()
        let previous = HeadingFolds.defaults
        HeadingFolds.defaults = defaults
        defer { HeadingFolds.defaults = previous }
        let body = (1...12).map { "Line \($0)" }.joined(separator: "\n\n")
        let text = "# One\n\n\(body)\n\n# Last\n\n\((1...6).map { "Tail \($0)" }.joined(separator: "\n\n"))"
        let host = NSHostingView(rootView: ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<8, id: \.self) { Text("Filler \($0)").frame(height: 30) }
                TaskLinkText(source: text, completed: false, color: Palette.ink, fontSize: 13, edit: {}, open: { _ in },
                             maxLines: 0, markdown: true, compactLines: true, foldID: "fold.bottom")
            }
        })
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        func find<T: NSView>(_ view: NSView, _ type: T.Type) -> T? { (view as? T) ?? view.subviews.lazy.compactMap { find($0, type) }.first }
        let scroll = try XCTUnwrap(find(host, NSScrollView.self))
        let view = try XCTUnwrap(find(host, InteractiveTaskText.self))
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: try XCTUnwrap(scroll.documentView).frame.height - clip.bounds.height))
        scroll.reflectScrolledClipView(clip)
        func top() -> CGFloat {
            guard let rect = view.headingRegions().first(where: { $0.key == "h1:Last#0" })?.rect else { return .nan }
            return view.convert(rect, to: clip).minY - clip.bounds.minY
        }
        let start = top()
        view.toggleHeading("h1:Last#0")
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.string.contains("Tail 3"), "收起了")
        XCTAssertEqual(top(), start, accuracy: 1, "滚到底收起时标题不往下跳")
        XCTAssertGreaterThan(clip.contentInsets.bottom, 0, "底部临时留白")
        view.toggleHeading("h1:Last#0")
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.string.contains("Tail 3"))
        XCTAssertEqual(top(), start, accuracy: 1, "展开时标题不动，内容往下展开")
        XCTAssertEqual(clip.contentInsets.bottom, 0, "展开后看不到的留白收回")
    }
}
