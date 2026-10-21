import XCTest
@testable import TimelineCore

final class JournalTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        JournalDates.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    @MainActor
    func testExistingRecordsWithoutDeadlinesRemainReadable() async throws {
        let directory = try temporaryDirectory()
        let legacyData = Data("{\"version\":1,\"days\":{\"2026-10-06\":{\"todos\":[],\"summary\":\"已有总结\"}}}".utf8)
        try legacyData.write(to: directory.appendingPathComponent("journal.json"))
        let store = JournalStore(directory: directory)
        let today = date(2026, 10, 6)
        XCTAssertFalse(store.isReadOnly)
        XCTAssertEqual(store.entry(for: today).summary, "已有总结")
        XCTAssertTrue(store.entry(for: today).deadlines.isEmpty)
        store.setDeadlineDraft("提交报告", on: today)
        store.commitDeadline(on: today)
        let reloaded = JournalStore(directory: directory)
        XCTAssertEqual(reloaded.entry(for: today).summary, "已有总结")
        XCTAssertEqual(reloaded.entry(for: today).deadlines.map(\.title), ["提交报告"])
    }

    @MainActor
    func testDeadlinesAreIsolatedByDateAndSurviveExport() async throws {
        let store = JournalStore(directory: try temporaryDirectory())
        let firstDay = date(2026, 10, 6)
        let secondDay = date(2026, 10, 7)
        store.setDeadlineDraft("论文提交 23:59\n项目报告", on: firstDay)
        store.commitDeadline(on: firstDay)
        store.setDeadlineDraft("作业截止", on: secondDay)
        store.commitDeadline(on: secondDay)
        let exported = try temporaryDirectory()
        try store.export(to: exported.appendingPathComponent("journal.json"))
        let reloaded = JournalStore(directory: exported)
        XCTAssertEqual(reloaded.entry(for: firstDay).deadlines.map(\.title), ["论文提交 23:59", "项目报告"])
        XCTAssertEqual(reloaded.entry(for: secondDay).deadlines.map(\.title), ["作业截止"])
        XCTAssertTrue(reloaded.entry(for: firstDay).hasContent)
        XCTAssertEqual(reloaded.entry(for: firstDay).todos, reloaded.entry(for: firstDay).deadlines)
    }

    @MainActor
    func testClearingDeadlinePreservesOtherContentAndRemovesEmptyDays() async throws {
        let store = JournalStore(directory: try temporaryDirectory())
        let today = date(2026, 10, 6)
        store.setDeadlineDraft("提交报告", on: today)
        store.commitDeadline(on: today)
        store.setSummary("总结", on: today)
        store.deleteDeadline(try XCTUnwrap(store.entry(for: today).deadlines.first).id, on: today)
        XCTAssertEqual(store.entry(for: today).summary, "总结")
        XCTAssertTrue(store.entry(for: today).hasContent)
        store.setDeadlineDraft("提交报告", on: today)
        store.commitDeadline(on: today)
        store.setSummary("", on: today)
        XCTAssertTrue(store.entry(for: today).hasContent)
        store.deleteDeadline(try XCTUnwrap(store.entry(for: today).deadlines.first).id, on: today)
        XCTAssertFalse(store.entry(for: today).hasContent)
        XCTAssertTrue(store.days.isEmpty)
    }

    func testMonthGridStartsMondayAndIncludesLeapDay() {
        let grid = JournalDates.monthGrid(date(2024, 2, 14))
        XCTAssertEqual(grid.count, 35)
        XCTAssertEqual(JournalDates.calendar.component(.weekday, from: grid[0]), 2)
        XCTAssertEqual(JournalDates.key(grid[0]), "2024-01-29")
        XCTAssertTrue(grid.contains { JournalDates.key($0) == "2024-02-29" })
        XCTAssertEqual(Set(grid.map(JournalDates.key)).count, 35)
    }

    func testMonthGridUsesOnlyNecessaryWeeks() {
        XCTAssertEqual(JournalDates.monthGrid(date(2021, 2, 1)).count, 28)
        XCTAssertEqual(JournalDates.monthGrid(date(2026, 10, 1)).count, 35)
        XCTAssertEqual(JournalDates.monthGrid(date(2026, 3, 1)).count, 42)
    }

    @MainActor
    func testLegacyMultilineDeadlineMigratesWithoutLosingSummaryOrTodos() async throws {
        let directory = try temporaryDirectory()
        let original = """
        {"version":1,"days":{"2026-10-06":{"todos":[{"id":"00000000-0000-0000-0000-000000000001","title":"待办","completed":true}],"summary":"总结","deadline":" 报告提交\\n\\n论文截止 "}}}
        """
        try Data(original.utf8).write(to: directory.appendingPathComponent("journal.json"))
        let store = JournalStore(directory: directory)
        let today = date(2026, 10, 6)
        XCTAssertFalse(store.isReadOnly)
        XCTAssertEqual(store.entry(for: today).deadlines.map(\.title), ["待办", "报告提交", "论文截止"])
        XCTAssertEqual(store.entry(for: today).summary, "总结")
        XCTAssertEqual(store.entry(for: today).completedCount, 1)
        let first = store.entry(for: today).deadlines[1]
        store.toggleDeadline(first.id, on: today)
        let restored = JournalStore(directory: directory)
        XCTAssertEqual(restored.entry(for: today).deadlines[1].id, first.id)
        XCTAssertTrue(restored.entry(for: today).deadlines[1].completed)
        XCTAssertEqual(restored.entry(for: today).deadlines.count, 3)
    }

    @MainActor
    func testDeadlineDraftCommitEditAndCompletionAreIndependent() async throws {
        let directory = try temporaryDirectory()
        let store = JournalStore(directory: directory)
        let today = date(2026, 10, 6)
        store.setDeadlineDraft("报告", on: today)
        store.save()
        XCTAssertTrue(store.entry(for: today).deadlines.isEmpty)
        XCTAssertEqual(JournalStore(directory: directory).entry(for: today).deadlineDraft, "报告")
        store.commitDeadline(on: today)
        store.setDeadlineDraft("论文", on: today)
        store.commitDeadline(on: today)
        store.setDeadlineDraft(" \n ", on: today)
        store.commitDeadline(on: today)
        let items = store.entry(for: today).deadlines
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(store.entry(for: today).deadlineDraft, "")
        store.toggleDeadline(items[0].id, on: today)
        store.renameDeadline(items[0].id, title: "报告 18:00", on: today)
        let restored = JournalStore(directory: directory)
        XCTAssertTrue(restored.entry(for: today).deadlines[0].completed)
        XCTAssertFalse(restored.entry(for: today).deadlines[1].completed)
        XCTAssertEqual(restored.entry(for: today).deadlines[0].title, "报告 18:00")
        restored.toggleDeadline(items[0].id, on: today)
        XCTAssertFalse(restored.entry(for: today).deadlines[0].completed)
        XCTAssertEqual(restored.entry(for: today).todos, restored.entry(for: today).deadlines)
    }

    @MainActor
    func testDeadlineDeletionCanBeUndoneOnOriginalDate() async throws {
        let store = JournalStore(directory: try temporaryDirectory())
        let today = date(2026, 10, 6)
        store.setDeadlineDraft("报告\n论文", on: today)
        store.commitDeadline(on: today)
        let original = store.entry(for: today).deadlines
        store.deleteDeadline(original[0].id, on: today)
        store.setDeadlineDraft("另一日期", on: date(2026, 10, 7))
        store.undoDelete()
        XCTAssertEqual(store.entry(for: today).deadlines, original)
        XCTAssertEqual(store.entry(for: today).todos, original)
        XCTAssertFalse(store.canUndoDelete)
    }

    func testGridCrossesYearAndDaylightSavingBoundaries() {
        XCTAssertEqual(JournalDates.key(JournalDates.monthGrid(date(2027, 1, 1))[0]), "2026-12-28")
        for month in [3, 11] {
            let grid = JournalDates.monthGrid(date(2026, month, 15))
            for index in 1..<grid.count {
                XCTAssertEqual(JournalDates.calendar.dateComponents([.day], from: grid[index - 1], to: grid[index]).day, 1)
            }
        }
    }

    @MainActor
    func testTodoAndCalendarUseSameItemsForAllMutations() async throws {
        let directory = try temporaryDirectory()
        let store = JournalStore(directory: directory)
        let today = date(2026, 10, 6)
        store.addTodo("从左侧新增", on: today)
        let item = try XCTUnwrap(store.entry(for: today).deadlines.first)
        XCTAssertEqual(item.title, "从左侧新增")
        store.toggleDeadline(item.id, on: today)
        XCTAssertEqual(store.entry(for: today).completedCount, 1)
        store.renameTodo(item.id, title: "从左侧修改", on: today)
        XCTAssertEqual(store.entry(for: today).deadlines[0].title, "从左侧修改")
        store.renameDeadline(item.id, title: "从右侧修改", on: today)
        XCTAssertEqual(store.entry(for: today).todos[0].title, "从右侧修改")
        store.setDeadlineDraft("从右侧新增", on: today)
        store.commitDeadline(on: today)
        XCTAssertEqual(store.entry(for: today).todos.map(\.title), ["从右侧修改", "从右侧新增"])
        store.deleteTodo(item.id, on: today)
        XCTAssertEqual(store.entry(for: today).deadlines.count, 1)
        store.undoDelete()
        let restored = JournalStore(directory: directory)
        XCTAssertEqual(restored.entry(for: today).deadlines, restored.entry(for: today).todos)
        XCTAssertEqual(restored.entry(for: today).todos.count, 2)
    }

    @MainActor
    func testClearedTitlesDeleteFromBothViewsAndCanBeUndone() async throws {
        let store = JournalStore(directory: try temporaryDirectory())
        let today = date(2026, 10, 6)
        store.addTodo("清空后删除", on: today)
        let item = try XCTUnwrap(store.entry(for: today).todos.first)
        store.renameDeadline(item.id, title: " \n ", on: today)
        XCTAssertTrue(store.entry(for: today).deadlines.isEmpty)
        XCTAssertTrue(store.entry(for: today).todos.isEmpty)
        store.undoDelete()
        XCTAssertEqual(store.entry(for: today).todos, [item])
        store.renameTodo(item.id, title: "", on: today)
        XCTAssertTrue(store.days.isEmpty)
    }

    @MainActor
    func testVersionTwoListsMergeOnceWithoutDuplicatingSharedIDs() async throws {
        let directory = try temporaryDirectory()
        let original = """
        {"version":2,"days":{"2026-10-06":{"todos":[{"id":"00000000-0000-0000-0000-000000000001","title":"左侧","completed":true}],"deadlines":[{"id":"00000000-0000-0000-0000-000000000001","title":"左侧","completed":true},{"id":"00000000-0000-0000-0000-000000000002","title":"右侧","completed":false}],"summary":"总结","deadlineDraft":"草稿"}}}
        """
        try Data(original.utf8).write(to: directory.appendingPathComponent("journal.json"))
        let store = JournalStore(directory: directory)
        let today = date(2026, 10, 6)
        XCTAssertEqual(store.entry(for: today).todos.map(\.title), ["左侧", "右侧"])
        XCTAssertEqual(store.entry(for: today).completedCount, 1)
        store.save()
        let restored = JournalStore(directory: directory)
        XCTAssertEqual(restored.entry(for: today), store.entry(for: today))
        XCTAssertEqual(restored.entry(for: today).todos.count, 2)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        XCTAssertEqual(raw["version"] as? Int, 8)
    }

    @MainActor
    func testTypingSavesAfterShortPauseAndExplicitSaveFlushes() async throws {
        let directory = try temporaryDirectory()
        let store = JournalStore(directory: directory)
        let today = date(2026, 10, 6)
        store.setSummary("刚开始", on: today)
        store.setSummary("最新内容", on: today)
        XCTAssertTrue(store.hasPendingSave)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertFalse(store.hasPendingSave)
        XCTAssertEqual(JournalStore(directory: directory).entry(for: today).summary, "最新内容")
        store.setDeadlineDraft("尚未按回车", on: today)
        store.save()
        XCTAssertFalse(store.hasPendingSave)
        XCTAssertEqual(JournalStore(directory: directory).entry(for: today).deadlineDraft, "尚未按回车")
    }

    @MainActor
    func testTodosAndSummarySurviveReloadAndStayOnTheirDates() async throws {
        let directory = try temporaryDirectory()
        let store = JournalStore(directory: directory)
        let firstDay = date(2026, 10, 6)
        let nextDay = date(2026, 10, 7)
        store.addTodo("  完成日历应用  ", on: firstDay)
        let todo = try XCTUnwrap(store.entry(for: firstDay).todos.first)
        store.toggleTodo(todo.id, on: firstDay)
        store.renameTodo(todo.id, title: "完成第一版 ✅", on: firstDay)
        store.setSummary("今天完成了第一版。\n明天继续完善。", on: firstDay)
        store.addTodo("下一天的任务", on: nextDay)
        let reloaded = JournalStore(directory: directory)
        XCTAssertEqual(reloaded.entry(for: firstDay).completedCount, 1)
        XCTAssertEqual(reloaded.entry(for: firstDay).todos[0].title, "完成第一版 ✅")
        XCTAssertEqual(reloaded.entry(for: firstDay).summary, "今天完成了第一版。\n明天继续完善。")
        XCTAssertEqual(reloaded.entry(for: nextDay).todos.count, 1)
        XCTAssertEqual(reloaded.entry(for: nextDay).summary, "")
        XCTAssertNil(reloaded.errorMessage)
    }

    @MainActor
    func testEmptyTasksIgnoredAndCompletionCanBeReversed() async throws {
        let store = JournalStore(directory: try temporaryDirectory())
        let today = date(2026, 10, 6)
        store.addTodo(" \n ", on: today)
        XCTAssertTrue(store.days.isEmpty)
        store.addTodo("任务", on: today)
        let todo = try XCTUnwrap(store.entry(for: today).todos.first)
        store.toggleTodo(todo.id, on: today)
        store.toggleTodo(todo.id, on: today)
        XCTAssertFalse(store.entry(for: today).todos[0].completed)
        store.deleteTodo(todo.id, on: today)
        XCTAssertFalse(store.entry(for: today).hasContent)
        XCTAssertTrue(store.days.isEmpty)
    }

    @MainActor
    func testDeleteUndoRestoresOriginalDayAndPosition() async throws {
        let store = JournalStore(directory: try temporaryDirectory())
        let today = date(2026, 10, 6)
        store.addTodo("第一项", on: today)
        store.addTodo("第二项", on: today)
        let original = store.entry(for: today)
        store.deleteTodo(original.todos[0].id, on: today)
        store.addTodo("其他日期", on: date(2026, 10, 7))
        store.undoDelete()
        XCTAssertEqual(store.entry(for: today), original)
        XCTAssertFalse(store.canUndoDelete)
    }

    @MainActor
    func testSummaryOnlyDayAndClearingLastContent() async throws {
        let store = JournalStore(directory: try temporaryDirectory())
        let today = date(2026, 10, 6)
        store.setSummary("仅写总结", on: today)
        XCTAssertTrue(store.entry(for: today).hasContent)
        store.setSummary("", on: today)
        XCTAssertTrue(store.days.isEmpty)
    }

    @MainActor
    func testCorruptDocumentIsNeverOverwritten() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("journal.json")
        let original = Data("{corrupted".utf8)
        try original.write(to: url)
        let store = JournalStore(directory: directory)
        XCTAssertTrue(store.isReadOnly)
        XCTAssertNotNil(store.errorMessage)
        store.addTodo("不可覆盖原数据", on: date(2026, 10, 6))
        store.save()
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor
    func testFutureSchemaIsProtected() async throws {
        let directory = try temporaryDirectory()
        try Data("{\"version\":9,\"days\":{}}".utf8).write(to: directory.appendingPathComponent("journal.json"))
        let store = JournalStore(directory: directory)
        XCTAssertTrue(store.isReadOnly)
    }

    @MainActor
    func testBackupPreservesPreviousSessionAndExportCanBeRestored() async throws {
        let directory = try temporaryDirectory()
        let original = JournalStore(directory: directory)
        let today = date(2026, 10, 6)
        original.setSummary("第一次保存", on: today)
        original.save()
        let firstData = try Data(contentsOf: original.fileURL)
        let nextSession = JournalStore(directory: directory)
        nextSession.setSummary("第二次保存", on: today)
        XCTAssertEqual(try Data(contentsOf: nextSession.backupURL), firstData)
        let exportDirectory = try temporaryDirectory()
        try nextSession.export(to: exportDirectory.appendingPathComponent("journal.json"))
        XCTAssertEqual(JournalStore(directory: exportDirectory).entry(for: today).summary, "第二次保存")
    }

    @MainActor
    func testFailedSaveKeepsEditsAndCanBeRetried() async throws {
        let directory = try temporaryDirectory()
        let store = JournalStore(directory: directory)
        try FileManager.default.removeItem(at: directory)
        try Data("blocking file".utf8).write(to: directory)
        let today = date(2026, 10, 6)
        store.setSummary("保留在内存中的修改", on: today)
        store.save()
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.entry(for: today).summary, "保留在内存中的修改")
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store.save()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(JournalStore(directory: directory).entry(for: today).summary, "保留在内存中的修改")
    }
}
