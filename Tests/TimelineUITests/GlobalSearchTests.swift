import AppKit
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class GlobalSearchTests: XCTestCase {
    func testSearchFindsBoardContentWithMatchingLine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Reading")))
        store.setBoardMarkdown("# 议程\n\n  - 讨论 Transformer 结构\n- 其他", for: board.id)
        let other = try XCTUnwrap(store.ensureBoard(for: .tag("Old")))
        store.setBoardMarkdown("Transformer 旧笔记", for: other.id)

        let hits = AgendaView.searchHits(store: store, query: "transformer", filter: .all)
        let boards = hits.compactMap { hit -> (UUID, String)? in
            if case .board(let found, let line) = hit { return (found.id, line) }
            return nil
        }
        XCTAssertEqual(boards.map(\.0).sorted { $0.uuidString < $1.uuidString },
                       [board.id, other.id].sorted { $0.uuidString < $1.uuidString })
        XCTAssertTrue(boards.contains { $0.0 == board.id && $0.1 == "- 讨论 Transformer 结构" }, "命中的那一行去掉缩进后显示")
        XCTAssertTrue(AgendaView.searchHits(store: store, query: "", filter: .all).allSatisfy {
            if case .board = $0 { return false } else { return true }
        }, "空搜索不列出工作板")
    }
}

@MainActor
final class NotesSearchShortcutTests: XCTestCase {
    private static var keepAlive: [NotesWindowController] = []

    private func focusedPlaceholder(_ window: NSWindow) -> String? {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSTextField else { return nil }
        return field.placeholderString
    }

    func testCommandFFocusesTheSearchFieldOfTheVisiblePage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let controller = NotesWindowController(nav: NotesNavigation(defaults: InMemoryDefaults()))
        Self.keepAlive.append(controller)
        controller.show(store: store, taskID: nil, reveal: { _ in }, openDay: { _ in })
        let window = try XCTUnwrap(controller.window)
        defer { controller.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        controller.workspace.focusSearch()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(focusedPlaceholder(window), AppLocalized("搜索任务或标签（#标签）"))

        controller.setDate(Date())
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.makeFirstResponder(nil)
        controller.workspace.focusSearch()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(focusedPlaceholder(window), AppLocalized("搜索日期或日志"), "日记页聚焦自己的搜索框，不是隐藏的笔记页")
    }
}
