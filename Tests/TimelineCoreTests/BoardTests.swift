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
        let source = "# Paper\n\n- [x] Intro & Abstract\n- [ ] Design\n\n问题与[链接](https://example.com)"
        store.setBoardMarkdown(source, for: board.id)
        store.save()
        let reloaded = JournalStore(directory: store.directory)
        let result = try XCTUnwrap(reloaded.board(for: .task(task.id)))
        XCTAssertEqual(result.markdown, source)
        XCTAssertEqual(store.tasks().count, 1)
        XCTAssertTrue(store.allLogs(includeFocus: true).isEmpty)
        XCTAssertEqual(store.pinnedTaskID, task.id)
        XCTAssertEqual(store.focusTaskID, task.id)
        XCTAssertFalse(try XCTUnwrap(store.locate(task.id)).task.completed)
    }

    func testEditClearAndUndoRedo() throws {
        let store = makeStore()
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("研究")))
        store.setBoardMarkdown("# Original\n\nDetails", for: board.id)
        store.setBoardMarkdown("", for: board.id)
        XCTAssertEqual(store.boards[0].markdown, "")
        store.undo()
        XCTAssertEqual(store.boards[0].markdown, "# Original\n\nDetails")
        store.redo()
        XCTAssertEqual(store.boards[0].markdown, "")
        store.save()
        XCTAssertEqual(JournalStore(directory: store.directory).boards[0].markdown, "")
    }

    func testBoardLookupCacheTracksCreationEditsRenameArchiveAndUndo() throws {
        let store = makeStore()
        XCTAssertNil(store.board(for: .tag("Reading")))
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Reading")))
        XCTAssertEqual(store.board(for: .tag("READING"))?.id, board.id)
        store.setBoardMarkdown("- [ ] Intro", for: board.id)
        XCTAssertTrue(try XCTUnwrap(store.board(for: .tag("reading"))).hasContent)
        _ = store.renameTag("Reading", to: "Paper")
        XCTAssertNil(store.board(for: .tag("Reading")))
        XCTAssertEqual(store.board(for: .tag("paper"))?.id, board.id)
        store.deleteTag("Paper")
        XCTAssertNil(store.board(for: .tag("Paper")))
        store.undo()
        XCTAssertEqual(store.board(for: .tag("Paper"))?.markdown, "- [ ] Intro")
        store.setBoardMarkdown(" \n\t", for: board.id)
        XCTAssertFalse(try XCTUnwrap(store.board(for: .tag("Paper"))).hasContent)
    }

    func testTagRenameMergeAndDeletePreserveBoardsAndUndoTogether() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addParsedTodo("阅读 #Paper/Design", on: day))
        let source = try XCTUnwrap(store.ensureBoard(for: .tag("Paper/Design")))
        let target = try XCTUnwrap(store.ensureBoard(for: .tag("Research/Design")))
        store.setBoardMarkdown("Source", for: source.id)
        store.setBoardMarkdown("Target", for: target.id)
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
        XCTAssertEqual(store.boards.map(\.markdown), ["Source", "Target"])
        XCTAssertTrue(store.allTags().isEmpty)
        store.undo()
        XCTAssertTrue(store.boards.allSatisfy { !$0.archived })
        XCTAssertEqual(store.locate(task.id)?.task.tags, ["Research/Design"])
    }

    func testDeletedTaskBoardBecomesArchivedAndReappearsOnUndo() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addParsedTodo("Meeting", on: day))
        let board = try XCTUnwrap(store.ensureBoard(for: .task(task.id)))
        store.setBoardMarkdown("# Agenda\n\nTalking points", for: board.id)
        store.renameTodo(task.id, title: "Renamed meeting", on: task.date)
        store.deleteTodo(task.id, on: task.date)
        XCTAssertTrue(store.isBoardArchived(store.boards[0]))
        XCTAssertEqual(store.boardTitle(store.boards[0]), "Renamed meeting")
        store.undo()
        XCTAssertFalse(store.isBoardArchived(store.boards[0]))
        store.toggleTodo(task.id, on: task.date)
        XCTAssertEqual(store.boards[0].markdown, "# Agenda\n\nTalking points")
        XCTAssertFalse(store.isBoardArchived(store.boards[0]))
    }

    func testExportRestoreAndReadOnlySnapshot() throws {
        let store = makeStore()
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Project")))
        store.setBoardMarkdown("Original", for: board.id)
        let export = store.directory.appendingPathComponent("export.json")
        try store.export(to: export)
        store.setBoardMarkdown("Later", for: board.id)
        try store.restore(from: export)
        XCTAssertEqual(store.boards[0].markdown, "Original")
        store.undo()
        XCTAssertEqual(store.boards[0].markdown, "Later")
        store.save()
        let before = try Data(contentsOf: store.fileURL)
        let snapshot = JournalStore(directory: store.directory, readOnlySnapshot: true)
        XCTAssertNotNil(snapshot.ensureBoard(for: .tag("Project")))
        XCTAssertNil(snapshot.ensureBoard(for: .tag("Other")))
        snapshot.setBoardMarkdown("Modified", for: board.id)
        XCTAssertEqual(snapshot.boards[0].markdown, "Later")
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
        XCTAssertEqual(raw["version"] as? Int, 8)
    }

    private func legacyData(id: UUID) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "version": 7, "days": [:], "tags": ["Reading"],
            "boards": [[
                "id": id.uuidString, "owner": ["tag": ["_0": "Reading"]],
                "title": "Reading", "archived": true, "createdAt": 100, "updatedAt": 200,
                "items": [
                    ["id": UUID().uuidString, "kind": "step", "title": "Intro", "body": "line one\n[Paper](https://example.com)", "completed": true],
                    ["id": UUID().uuidString, "kind": "note", "title": "Notes", "body": "## Background\n\nDetails", "completed": false],
                    ["id": UUID().uuidString, "kind": "step", "title": "Design", "body": "", "completed": false]
                ]
            ]]
        ])
    }

    func testVersionSevenMigrationPreservesContentAndBacksUpOriginal() throws {
        let store = makeStore()
        let id = UUID()
        let original = try legacyData(id: id)
        try original.write(to: store.fileURL)
        let migrated = JournalStore(directory: store.directory)
        let board = try XCTUnwrap(migrated.boards.first)
        XCTAssertFalse(migrated.isReadOnly)
        XCTAssertEqual(board.id, id)
        XCTAssertEqual(board.owner, .tag("Reading"))
        XCTAssertTrue(board.archived)
        XCTAssertEqual(board.createdAt, Date(timeIntervalSinceReferenceDate: 100))
        XCTAssertEqual(board.updatedAt, Date(timeIntervalSinceReferenceDate: 200))
        XCTAssertEqual(board.markdown, "- [x] Intro\n\n  line one\n  [Paper](https://example.com)\n\n## Notes\n\n## Background\n\nDetails\n\n- [ ] Design")
        XCTAssertEqual(try Data(contentsOf: migrated.backupsDirectory.appendingPathComponent("before-board-markdown-v7.json")), original)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: migrated.fileURL)) as? [String: Any])
        XCTAssertEqual(document["version"] as? Int, 8)
        let saved = try XCTUnwrap((document["boards"] as? [[String: Any]])?.first)
        XCTAssertNil(saved["items"])
        XCTAssertEqual(saved["markdown"] as? String, board.markdown)
        XCTAssertEqual(JournalStore(directory: store.directory).boards, migrated.boards)
    }

    func testLegacyReadOnlySnapshotConvertsWithoutWriting() throws {
        let store = makeStore()
        let original = try legacyData(id: UUID())
        try original.write(to: store.fileURL)
        let snapshot = JournalStore(directory: store.directory, readOnlySnapshot: true)
        XCTAssertTrue(snapshot.isReadOnly)
        XCTAssertTrue(try XCTUnwrap(snapshot.boards.first).markdown.contains("- [x] Intro"))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.backupsDirectory.path))
    }

    func testEmptyMarkdownTakesPrecedenceOverLegacyItems() throws {
        let data = try legacyData(id: UUID())
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var boards = try XCTUnwrap(document["boards"] as? [[String: Any]])
        boards[0]["markdown"] = ""
        document["boards"] = boards
        let store = makeStore()
        try JSONSerialization.data(withJSONObject: document).write(to: store.fileURL)
        XCTAssertEqual(JournalStore(directory: store.directory).boards.first?.markdown, "")
    }

    func testToggleMarkdownTaskChangesOnlyTheRequestedMarker() throws {
        let store = makeStore()
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Paper")))
        let source = "# 中文标题\r\n\r\n- [ ] Same\r\n  - [X] Same\r\n> 1. [ ] 引用\r\n正文 [ ] 保留\r\n"
        store.setBoardMarkdown(source, for: board.id)
        store.toggleBoardMarkdownTask(atLine: 4, in: board.id)
        XCTAssertEqual(store.boards[0].markdown, source.replacingOccurrences(of: "  - [X]", with: "  - [ ]"))
        store.toggleBoardMarkdownTask(atLine: 5, in: board.id)
        XCTAssertTrue(store.boards[0].markdown.contains("> 1. [x] 引用\r\n"))
        let unchanged = store.boards[0].markdown
        for line in [0, 6, 100] { store.toggleBoardMarkdownTask(atLine: line, in: board.id) }
        XCTAssertEqual(store.boards[0].markdown, unchanged)
        store.undo()
        XCTAssertFalse(store.boards[0].markdown.contains("> 1. [x]"))
        store.save()
        let snapshot = JournalStore(directory: store.directory, readOnlySnapshot: true)
        let before = snapshot.boards
        snapshot.toggleBoardMarkdownTask(atLine: 3, in: board.id)
        XCTAssertEqual(snapshot.boards, before)
    }
}
