import XCTest
@testable import TimelineCore

@MainActor
final class SpotlightTests: XCTestCase {
    private func store() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SpotlightTests-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory)
    }

    func testItemsCoverLogsTasksAndBoards() throws {
        let store = store()
        let day = Date()
        store.addParsedTodo("写周报 #工作", on: day)
        _ = try store.quickLog("## 读书\n第二行 **加粗** [链接](https://example.com)", on: day, now: day)
        let board = store.ensureBoard(for: .tag("读书"))!
        store.setBoardMarkdown("# 第一章\n- [ ] 做笔记", for: board.id)
        _ = store.ensureBoard(for: .tag("空白"))

        let items = store.spotlightItems()
        let task = try XCTUnwrap(items.first { $0.kind == .task })
        XCTAssertEqual(task.title, "写周报")
        XCTAssertEqual(task.tags, ["工作"])
        let log = try XCTUnwrap(items.first { $0.kind == .log })
        XCTAssertEqual(log.title, "读书")
        XCTAssertTrue(log.detail.contains("第二行 加粗 链接"), log.detail)
        let boardItem = try XCTUnwrap(items.first { $0.kind == .board })
        XCTAssertEqual(boardItem.title, "#读书")
        XCTAssertEqual(boardItem.detail, "第一章 · 做笔记")
        // 空工作板不进 Spotlight。
        XCTAssertEqual(items.filter { $0.kind == .board }.count, 1)
    }

    func testIdentifierRoundTripsAndSignatureTracksContent() throws {
        let store = store()
        store.addTodo("原标题", on: Date())
        let before = try XCTUnwrap(store.spotlightItems().first)
        XCTAssertEqual(SpotlightItem.parse(before.identifier)?.id, before.id)
        XCTAssertEqual(SpotlightItem.parse(before.identifier)?.kind, .task)
        XCTAssertNil(SpotlightItem.parse("note:123"))
        XCTAssertEqual(before.signature, store.spotlightItems().first?.signature, "同样的内容指纹不变")
        store.renameTodo(before.id, title: "新标题", on: Date())
        XCTAssertNotEqual(before.signature, store.spotlightItems().first?.signature)
    }
}
