import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class BoardSwitcherItemsTests: XCTestCase {
    private func store() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory)
    }

    func testSectionsListEachOwnerOnceInPriorityOrder() throws {
        let store = store()
        let day = Date()
        store.addTodo("写周报", on: day)
        store.addTodo("读论文", on: day)
        let report = try XCTUnwrap(store.tasks().first { $0.task.title == "写周报" })
        let reading = try XCTUnwrap(store.ensureBoard(for: .tag("Reading")))
        let reportBoard = try XCTUnwrap(store.ensureBoard(for: .task(report.id)))
        _ = store.createTag("Idea")
        let items = BoardSwitcherItem.items(store: store, favorites: [reading.id], query: "")
        XCTAssertEqual(items.first?.section, .favorites)
        XCTAssertEqual(items.first?.boardID, reading.id)
        XCTAssertEqual(items.filter { $0.boardID == reportBoard.id }.map(\.section), [.recent])
        XCTAssertFalse(items.contains { $0.section == .tasks && $0.title == "写周报" }, "已有工作板的待办不再重复列出")
        XCTAssertTrue(items.contains { $0.section == .tasks && $0.title == "读论文" && $0.boardID == nil })
        XCTAssertTrue(items.contains { $0.section == .tags && $0.title == "#Idea" })
        XCTAssertFalse(items.contains { $0.section == .tags && $0.title == "#Reading" })
        XCTAssertEqual(items.map(\.section.rawValue), items.map(\.section.rawValue).sorted(), "分组顺序固定")
    }

    func testQueryFiltersEverySection() {
        let store = store()
        store.addTodo("写周报", on: Date())
        store.addTodo("读论文", on: Date())
        _ = store.createTag("论文")
        let items = BoardSwitcherItem.items(store: store, favorites: [], query: "论文")
        XCTAssertEqual(Set(items.map(\.title)), ["读论文", "#论文"])
    }
}
