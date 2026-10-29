import XCTest
@testable import TimelineCore

final class IncrementalRecordTests: XCTestCase {
    func testScopedChangesMatchFullRecordDiffIncludingMovesAndDeletions() throws {
        var first = DayEntry(), second = DayEntry()
        first.todos = [Todo(title: "Move"), Todo(title: "Stay")]
        first.logs = [DailyLogEntry(createdAt: Date(), kind: .note, text: "Delete"), DailyLogEntry(createdAt: Date(), kind: .note, text: "Keep")]
        first.summary = "Clear"
        let board = Board(owner: .tag("Project"), title: "Project", markdown: "Old")
        let before = SyncContent(days: ["2026-10-29": first, "2026-10-30": second], boards: [board], tags: ["Remove", "Keep"], pinnedTask: first.todos[0].id, nextTaskNumber: 1, boardFavoriteOrder: [board.id])
        var after = before
        second.todos = [first.todos.removeFirst()]
        first.logs.removeFirst(); first.summary = ""
        after.days = ["2026-10-29": first, "2026-10-30": second]
        after.boards[0].markdown = "New"
        after.tags = ["Keep", "Added"]
        after.pinnedTask = nil; after.boardFavoriteOrder = []
        let old = try before.records(), new = try after.records()
        let expected = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
        let delta = try after.recordChanges(since: before)
        XCTAssertEqual(delta.scope, Set(expected))
        XCTAssertEqual(delta.values, new.filter { expected.contains($0.key) })
        let merge = SyncMerge(device: "test", now: Date())
        var full: [String: SyncRecord] = [:]
        merge.stampLocalChanges(old, into: &full)
        var incremental = full
        merge.stampLocalChanges(new, into: &full)
        merge.stampLocalChanges(delta.values, into: &incremental, scope: delta.scope)
        XCTAssertEqual(incremental, full, "Unchanged records must not be tombstoned by a partial update")
    }

    func testDraftOnlyChangesDoNotEncodeOrDeleteSynchronizedEntities() throws {
        var day = DayEntry(); day.todos = [Todo(title: "Unchanged")]
        let before = SyncContent(days: ["2026-10-30": day], boards: [], tags: [], nextTaskNumber: 1)
        var after = before
        after.days["2026-10-30"]?.logDraft = "Typing"
        let delta = try after.recordChanges(since: before)
        XCTAssertTrue(delta.scope.isEmpty)
        XCTAssertTrue(delta.values.isEmpty)
    }
}
