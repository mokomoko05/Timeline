import XCTest
@testable import TimelineCore

@MainActor
final class BoardTests: XCTestCase {
    private let day = JournalDates.date(for: "2026-10-21")!

    private func makeStore() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory)
    }

    func testTaskBoardPersistsWithoutCreatingTasksLogsOrChangingContext() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addParsedTodo("阅读论文 #研究", on: day))
        store.pinTask(task.id)
        store.setFocusTask(task.id)
        let board = try XCTUnwrap(store.ensureBoard(for: .task(task.id)))
        XCTAssertEqual(store.ensureBoard(for: .task(task.id))?.id, board.id)
        store.applyBoardTemplate(["Intro & Abstract", "Background", "Design", "Experiment"], to: board.id)
        let step = try XCTUnwrap(store.boards.first?.items.first)
        store.updateBoardItem(step.id, in: board.id, body: "问题与[链接](https://example.com)", completed: true)
        let noteID = try XCTUnwrap(store.addBoardItem(to: board.id, kind: .note, title: "参考资料"))
        store.updateBoardItem(noteID, in: board.id, completed: true)
        store.save()
        let reloaded = JournalStore(directory: store.directory)
        let result = try XCTUnwrap(reloaded.board(for: .task(task.id)))
        XCTAssertEqual(result.stepCount, 4)
        XCTAssertEqual(result.completedCount, 1)
        XCTAssertEqual(result.items.first?.body, "问题与[链接](https://example.com)")
        XCTAssertEqual(result.items.last?.completed, false)
        XCTAssertEqual(store.tasks().count, 1)
        XCTAssertTrue(store.allLogs(includeFocus: true).isEmpty)
        XCTAssertEqual(store.pinnedTaskID, task.id)
        XCTAssertEqual(store.focusTaskID, task.id)
        XCTAssertFalse(try XCTUnwrap(store.locate(task.id)).task.completed)
    }

    func testReorderEditDeleteAndUndoRedo() throws {
        let store = makeStore()
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("研究")))
        store.applyBoardTemplate(["A", "B", "C"], to: board.id)
        let first = try XCTUnwrap(store.boards.first?.items.first)
        store.moveBoardItem(first.id, in: board.id, to: 2)
        XCTAssertEqual(store.boards[0].items.map(\.title), ["B", "C", "A"])
        store.undo()
        XCTAssertEqual(store.boards[0].items.map(\.title), ["A", "B", "C"])
        store.redo()
        XCTAssertEqual(store.boards[0].items.map(\.title), ["B", "C", "A"])
        store.updateBoardItem(first.id, in: board.id, title: "Updated", body: "Details")
        store.deleteBoardItem(first.id, in: board.id)
        XCTAssertEqual(store.boards[0].items.count, 2)
        store.undo()
        XCTAssertEqual(store.boards[0].items.last?.title, "Updated")
        store.undo()
        XCTAssertEqual(store.boards[0].items.last?.title, "A")
    }

    func testTagRenameMergeAndDeletePreserveBoardsAndUndoTogether() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addParsedTodo("阅读 #Paper/Design", on: day))
        let source = try XCTUnwrap(store.ensureBoard(for: .tag("Paper/Design")))
        let target = try XCTUnwrap(store.ensureBoard(for: .tag("Research/Design")))
        store.addBoardItem(to: source.id, title: "Source")
        store.addBoardItem(to: target.id, title: "Target")
        XCTAssertEqual(store.board(for: .tag("paper/design"))?.id, source.id)
        XCTAssertFalse(store.removeEmptyTag("Research"))
        XCTAssertEqual(store.renameTag("Paper", to: "Research"), "Research")
        XCTAssertEqual(store.boards.count, 2)
        XCTAssertTrue(store.boards.allSatisfy { $0.owner.matches(.tag("Research/Design")) })
        XCTAssertEqual(store.locate(task.id)?.task.tags, ["Research/Design"])
        store.undo()
        XCTAssertEqual(store.boards[0].owner, .tag("Paper/Design"))
        XCTAssertEqual(store.locate(task.id)?.task.tags, ["Paper/Design"])
        store.redo()
        store.deleteTag("Research")
        XCTAssertTrue(store.boards.allSatisfy(\.archived))
        XCTAssertEqual(store.boards.flatMap(\.items).map(\.title), ["Source", "Target"])
        XCTAssertTrue(store.allTags().isEmpty)
        store.undo()
        XCTAssertTrue(store.boards.allSatisfy { !$0.archived })
        XCTAssertEqual(store.locate(task.id)?.task.tags, ["Research/Design"])
    }

    func testDeletedTaskBoardBecomesArchivedAndReappearsOnUndo() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addParsedTodo("Meeting", on: day))
        let board = try XCTUnwrap(store.ensureBoard(for: .task(task.id)))
        store.addBoardItem(to: board.id, title: "Agenda", body: "Talking points")
        store.renameTodo(task.id, title: "Renamed meeting", on: task.date)
        store.deleteTodo(task.id, on: task.date)
        XCTAssertTrue(store.isBoardArchived(store.boards[0]))
        XCTAssertEqual(store.boardTitle(store.boards[0]), "Renamed meeting")
        store.undo()
        XCTAssertFalse(store.isBoardArchived(store.boards[0]))
        store.toggleTodo(task.id, on: task.date)
        XCTAssertEqual(store.boards[0].items[0].body, "Talking points")
        XCTAssertFalse(store.isBoardArchived(store.boards[0]))
    }

    func testExportRestoreAndReadOnlySnapshot() throws {
        let store = makeStore()
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Project")))
        store.addBoardItem(to: board.id, title: "Original")
        let export = store.directory.appendingPathComponent("export.json")
        try store.export(to: export)
        store.addBoardItem(to: board.id, title: "Later")
        try store.restore(from: export)
        XCTAssertEqual(store.boards[0].items.map(\.title), ["Original"])
        store.undo()
        XCTAssertEqual(store.boards[0].items.map(\.title), ["Original", "Later"])
        store.save()
        let before = try Data(contentsOf: store.fileURL)
        let snapshot = JournalStore(directory: store.directory, readOnlySnapshot: true)
        XCTAssertNotNil(snapshot.ensureBoard(for: .tag("Project")))
        XCTAssertNil(snapshot.ensureBoard(for: .tag("Other")))
        snapshot.deleteBoardItem(snapshot.boards[0].items[0].id, in: board.id)
        XCTAssertEqual(snapshot.boards[0].items.count, 2)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    }

    func testVersionSixLoadsWithoutBoardsAndUpgradesOnSave() throws {
        let store = makeStore()
        try Data("{\"version\":6,\"days\":{}}".utf8).write(to: store.fileURL)
        let reloaded = JournalStore(directory: store.directory)
        XCTAssertFalse(reloaded.isReadOnly)
        XCTAssertTrue(reloaded.boards.isEmpty)
        XCTAssertNotNil(reloaded.ensureBoard(for: .tag("New")))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        XCTAssertEqual(raw["version"] as? Int, 7)
    }
}
