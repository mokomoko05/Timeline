import AppKit
import SwiftUI
import TimelineCore
import XCTest
@testable import Timeline

/// 笔记里的 Markdown 标题和工作板一样可以折叠：收起到下一个同级或更高级标题为止，点整行标题切换，状态按笔记记住。
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
        XCTAssertTrue(folded.contains("⋯"))
        let inner = render(["h2:A1#0"]).string
        XCTAssertTrue(inner.contains("alpha") && !inner.contains("inside") && inner.contains("beta"))
    }

    func testClickingAnywhereOnTheHeadingLineTogglesAndIsRememberedPerNote() {
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
            XCTAssertGreaterThan(first.rect.width, 300, "整行都能点，不只是左边的箭头")
            XCTAssertEqual(view.headingKey(at: NSPoint(x: first.rect.maxX - 10, y: first.rect.midY)), "h1:A#0")
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
    func testBoardFoldLayoutMatchesTheEditor() {
        let board = "# A\n\nalpha\n\n## A1\n\ninside\n\n# B\n\nbeta\n\n<details>\n<summary>D</summary>\n\n## In details\n\nhidden body\n\n</details>\n\n```\n# not a heading\n```\n# **Bold** title ##\n"
        let layout = BoardFoldLayout(board)
        XCTAssertEqual(layout.headings.map(\.key), ["h1:A#0", "h2:A1#0", "h1:B#0", "h2:In details#0"])
        XCTAssertEqual(layout.headings.map(\.lastLine), [6, 6, 23, 17])
        XCTAssertEqual(layout.disclosureKeys, [12: "d:D#0"])
        XCTAssertEqual(layout.hiddenRanges(["h1:A#0": true, "h2:A1#0": false]), [1...6])
        XCTAssertEqual(BoardFoldLayout("# **Bold** title ##\nbody").headings.map(\.key), ["h1:**Bold** title#0"], "标题文字取原文，和编辑器一样")
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
        XCTAssertTrue(text.contains("⋯") && text.contains("beta"))
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
}
