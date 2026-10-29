import XCTest
import Combine
@testable import TimelineCore

final class ScheduleTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        JournalDates.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func date(_ day: Int, hour: Int = 0) -> Date { date(2026, 10, day, hour: hour) }

    @MainActor
    private func store() throws -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory)
    }

    @MainActor
    func testCalendarShowsDueItemsWithoutDuplicatingScheduledTasks() async throws {
        let store = try store()
        let scheduled = date(6)
        let due = date(8, hour: 15)
        store.addTodo("论文", on: scheduled)
        store.addTodo("普通待办", on: scheduled)
        let task = try XCTUnwrap(store.entry(for: scheduled).todos.first)
        store.updateTodo(task.id, scheduledDate: scheduled, dueDate: due, dueHasTime: true, reminderMinutes: 15, repeatRule: .none)
        XCTAssertTrue(store.calendarTasks(on: scheduled).isEmpty)
        XCTAssertEqual(store.calendarTasks(on: scheduled, includeScheduled: true).count, 2)
        let dueItem = try XCTUnwrap(store.calendarTasks(on: due).first)
        XCTAssertEqual(dueItem.date, scheduled)
        XCTAssertEqual(dueItem.id, task.id)
        XCTAssertEqual(store.calendarTasks(on: due, includeScheduled: true).count, 1)
        store.toggleTodo(dueItem.id, on: dueItem.date)
        XCTAssertTrue(store.entry(for: scheduled).todos[0].completed)
        store.renameTodo(dueItem.id, title: "", on: dueItem.date)
        XCTAssertTrue(store.calendarTasks(on: due).isEmpty)
    }

    @MainActor
    func testCalendarIndexRefreshesAfterMutationsAndUndo() async throws {
        let store = try store()
        let scheduled = date(6)
        store.addTodo("first", on: scheduled)
        let task = try XCTUnwrap(store.entry(for: scheduled).todos.first)
        XCTAssertTrue(store.calendarDeadlines.isEmpty)
        store.updateTodo(task.id, scheduledDate: scheduled, dueDate: date(8), dueHasTime: false,
                         reminderMinutes: nil, repeatRule: .none)
        XCTAssertEqual(store.calendarDeadlines["2026-10-08"]?.first?.id, task.id)
        store.renameCalendarName(task.id, name: "paper", on: scheduled)
        XCTAssertEqual(store.calendarDeadlines["2026-10-08"]?.first?.task.calendarName, "paper")
        store.toggleTodo(task.id, on: scheduled)
        XCTAssertEqual(store.calendarDeadlines["2026-10-08"]?.first?.task.completed, true)
        store.undo()
        XCTAssertEqual(store.calendarDeadlines["2026-10-08"]?.first?.task.completed, false)
        store.moveTodo(task.id, to: date(7))
        XCTAssertEqual(store.calendarDeadlines["2026-10-08"]?.first?.date, date(7))
        store.deleteTodo(task.id, on: date(7))
        XCTAssertTrue(store.calendarDeadlines.isEmpty)
        store.undo()
        XCTAssertEqual(store.calendarDeadlines["2026-10-08"]?.first?.id, task.id)
    }

    @MainActor
    func testTaskIndexesStayCurrentWhenObserversReadDuringPublishing() async throws {
        let store = try store()
        store.addTodo("拖动任务", on: date(6))
        let task = try XCTUnwrap(store.entry(for: date(6)).todos.first)
        store.updateTodo(task.id, scheduledDate: date(6), dueDate: date(9), dueHasTime: false,
                         reminderMinutes: nil, repeatRule: .none)
        let observation = store.objectWillChange.sink {
            _ = store.tasks()
            _ = store.calendarDeadlines
        }
        defer { observation.cancel() }
        store.moveTodo(task.id, to: date(7))
        XCTAssertEqual(store.locate(task.id)?.date, date(7))
        XCTAssertEqual(store.calendarDeadlines["2026-10-09"]?.first?.date, date(7))
        guard store.locate(task.id)?.date == date(7) else { return }
        store.moveTodo(task.id, to: date(6))
        XCTAssertEqual(store.locate(task.id)?.date, date(6))
        store.renameTodo(task.id, title: "更新标题", on: date(6))
        XCTAssertEqual(store.locate(task.id)?.task.title, "更新标题")
        store.undo()
        XCTAssertEqual(store.locate(task.id)?.task.title, "拖动任务")
        store.undo()
        XCTAssertEqual(store.locate(task.id)?.date, date(7))
        store.redo()
        XCTAssertEqual(store.locate(task.id)?.date, date(6))
        store.deleteTodo(task.id, on: date(6))
        XCTAssertNil(store.locate(task.id))
        XCTAssertTrue(store.calendarDeadlines.isEmpty)
    }

    @MainActor
    func testRepeatedMovesKeepOneTaskAndPreserveDatesNotesAndUndo() async throws {
        let store = try store()
        store.setSummary("原日期总结", on: date(6))
        store.setLogDraft("目标日期草稿", on: date(7))
        store.addTodo("任务正文", on: date(6))
        let task = try XCTUnwrap(store.entry(for: date(6)).todos.first)
        store.updateTodo(task.id, scheduledDate: date(6), dueDate: date(12, hour: 15), dueHasTime: true,
                         reminderMinutes: 30, repeatRule: .weekly, calendarName: "短标题")
        let original = try XCTUnwrap(store.locate(task.id)?.task)
        let observation = store.objectWillChange.sink { _ = store.tasks(); _ = store.calendarDeadlines }
        defer { observation.cancel() }
        for step in 0..<60 {
            let destination = date(7 + step % 3)
            store.moveTodo(task.id, to: destination)
            store.moveTodo(task.id, to: destination)
            XCTAssertEqual(store.tasks().count, 1)
            XCTAssertEqual(store.locate(task.id)?.date, destination)
            XCTAssertEqual(store.locate(task.id)?.task, original)
        }
        store.undo()
        XCTAssertEqual(store.locate(task.id)?.date, date(8))
        store.redo()
        XCTAssertEqual(store.locate(task.id)?.date, date(9))
        XCTAssertEqual(store.entry(for: date(6)).summary, "原日期总结")
        XCTAssertEqual(store.entry(for: date(7)).logDraft, "目标日期草稿")
        let reloaded = JournalStore(directory: store.directory)
        XCTAssertEqual(reloaded.locate(task.id)?.date, date(9))
        XCTAssertEqual(reloaded.locate(task.id)?.task, original)
    }

    @MainActor
    func testReorderingTasksUsesStableAnchorsAndPersistsWithUndo() async throws {
        let store = try store()
        let day = date(6)
        for title in ["第一项", "第二项", "已完成项", "第四项"] { store.addTodo(title, on: day) }
        let original = store.entry(for: day).todos
        store.toggleTodo(original[2].id, on: day)
        store.renameCalendarName(original[3].id, name: "第四", on: day)
        let fourth = try XCTUnwrap(store.locate(original[3].id)?.task)
        store.placeTodo(original[3].id, on: day, relativeTo: original[1].id)
        XCTAssertEqual(store.entry(for: day).todos.map(\.id), [original[0].id, original[3].id, original[1].id, original[2].id])
        store.placeTodo(original[0].id, on: day, relativeTo: original[2].id, after: true)
        XCTAssertEqual(store.entry(for: day).todos.map(\.id), [original[3].id, original[1].id, original[2].id, original[0].id])
        store.placeTodo(original[0].id, on: day, relativeTo: original[0].id)
        store.placeTodo(original[0].id, on: day, relativeTo: UUID())
        store.undo()
        XCTAssertEqual(store.entry(for: day).todos.map(\.id), [original[0].id, original[3].id, original[1].id, original[2].id])
        store.redo()
        store.placeTodo(original[3].id, on: day)
        XCTAssertEqual(store.entry(for: day).todos.map(\.id), [original[1].id, original[2].id, original[0].id, original[3].id])
        XCTAssertEqual(store.locate(original[3].id)?.task, fourth)
        XCTAssertEqual(store.locate(original[2].id)?.task.completed, true)
        let reloaded = JournalStore(directory: store.directory)
        XCTAssertEqual(reloaded.entry(for: day).todos, store.entry(for: day).todos)
    }

    @MainActor
    func testCrossDatePlacementIsOneUndoAndPreservesSummaries() async throws {
        let store = try store()
        store.addTodo("移动项", on: date(6))
        store.addTodo("锚点", on: date(7))
        store.setSummary("当天总结", on: date(6))
        let moving = try XCTUnwrap(store.entry(for: date(6)).todos.first)
        let anchor = try XCTUnwrap(store.entry(for: date(7)).todos.first)
        store.placeTodo(moving.id, on: date(7), relativeTo: anchor.id, after: true)
        XCTAssertEqual(store.entry(for: date(7)).todos.map(\.id), [anchor.id, moving.id])
        XCTAssertEqual(store.entry(for: date(6)).summary, "当天总结")
        store.undo()
        XCTAssertEqual(store.entry(for: date(6)).todos, [moving])
        XCTAssertEqual(store.entry(for: date(7)).todos, [anchor])
    }

    @MainActor
    func testDateQueriesDoNotWriteToJournal() async throws {
        let store = try store()
        store.addTodo("task", on: date(6))
        let saved = store.lastSaved
        let data = try store.exportedJSONForTesting()
        for day in 1...31 {
            _ = store.entry(for: date(day))
            _ = store.calendarDeadlines[JournalDates.key(date(day))]
        }
        XCTAssertEqual(store.lastSaved, saved)
        XCTAssertFalse(store.hasPendingSave)
        XCTAssertEqual(try store.exportedJSONForTesting(), data)
    }

    @MainActor
    func testCachedCalendarLookupPerformanceWithYearOfTasks() async throws {
        struct Fixture: Encodable {
            let version = 4
            let days: [String: DayEntry]
        }
        let empty = try store()
        var days: [String: DayEntry] = [:]
        for offset in 0..<365 {
            let day = JournalDates.calendar.date(byAdding: .day, value: offset, to: date(2025, 1, 1))!
            var entry = DayEntry()
            entry.todos = (0..<20).map { index in
                var task = Todo(title: "Task \(index)")
                task.dueDate = day
                return task
            }
            days[JournalDates.key(day)] = entry
        }
        try JSONEncoder().encode(Fixture(days: days)).write(to: empty.fileURL)
        let populated = JournalStore(directory: empty.directory)
        let keys = days.keys.sorted()
        XCTAssertEqual(populated.calendarDeadlines.count, 365)
        var checksum = 0
        measure {
            var count = 0
            for _ in 0..<20 {
                for key in keys { count += populated.calendarDeadlines[key]?.count ?? 0 }
            }
            checksum = count
        }
        XCTAssertEqual(checksum, 146_000)
    }

    @MainActor
    func testCalendarNamePersistsSearchesMovesAndClearsWithoutDeletingTask() async throws {
        let store = try store()
        let scheduled = date(6)
        store.addTodo("Read the entire paper and prepare notes", on: scheduled)
        let original = try XCTUnwrap(store.entry(for: scheduled).todos.first)
        store.renameCalendarName(original.id, name: "  EuroSys\n  阅读  ", on: scheduled)
        let renamed = try XCTUnwrap(store.locate(original.id)?.task)
        XCTAssertEqual(renamed.calendarName, "EuroSys 阅读")
        XCTAssertEqual(renamed.title, original.title)
        XCTAssertEqual(store.tasks(matching: "EuroSys").map(\.id), [original.id])
        store.setSummary("无关的总结", on: scheduled)
        store.undo()
        XCTAssertEqual(store.locate(original.id)?.task.calendarName, "")
        XCTAssertEqual(store.entry(for: scheduled).summary, "无关的总结")
        store.redo()
        store.moveTodo(original.id, to: date(7))
        let restored = JournalStore(directory: store.directory)
        XCTAssertEqual(restored.locate(original.id)?.task.calendarName, "EuroSys 阅读")
        restored.renameCalendarName(original.id, name: " \n ", on: date(7))
        XCTAssertEqual(restored.locate(original.id)?.task.calendarName, "")
        XCTAssertEqual(restored.locate(original.id)?.task.title, original.title)
        XCTAssertEqual(restored.tasks().count, 1)
    }

    @MainActor
    func testCalendarNameInDetailsAndRecurringSuccessor() async throws {
        let store = try store()
        let scheduled = date(6)
        store.addTodo("Read a paper every day", on: scheduled)
        let original = try XCTUnwrap(store.entry(for: scheduled).todos.first)
        store.updateTodo(original.id, scheduledDate: scheduled, dueDate: scheduled, dueHasTime: false,
                         reminderMinutes: nil, repeatRule: .daily, calendarName: "  阅读  ")
        store.toggleTodo(original.id, on: scheduled, now: scheduled)
        XCTAssertEqual(store.entry(for: date(7)).todos.first?.calendarName, "阅读")
        XCTAssertEqual(store.entry(for: date(7)).todos.first?.title, original.title)
    }

    func testOlderTaskWithoutCalendarNameStillDecodes() throws {
        let data = Data("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"title\":\"old task\",\"completed\":false}".utf8)
        let task = try JSONDecoder().decode(Todo.self, from: data)
        XCTAssertEqual(task.calendarName, "")
        XCTAssertEqual(task.title, "old task")
    }

    @MainActor
    func testMoveUndoRedoPreservesDeadlineAndUnrelatedSummaryAndDraft() async throws {
        let store = try store()
        let source = date(6)
        let target = date(7)
        let due = date(9, hour: 16)
        store.addTodo("报告", on: source)
        let task = try XCTUnwrap(store.entry(for: source).todos.first)
        store.updateTodo(task.id, scheduledDate: source, dueDate: due, dueHasTime: true, reminderMinutes: 60, repeatRule: .weekly)
        store.moveTodo(task.id, to: target)
        store.setSummary("移动后新写的总结", on: source)
        store.setDeadlineDraft("还未提交", on: target)
        store.undo()
        XCTAssertEqual(store.locate(task.id)?.date, source)
        XCTAssertEqual(store.locate(task.id)?.task.dueDate, due)
        XCTAssertEqual(store.entry(for: source).summary, "移动后新写的总结")
        XCTAssertEqual(store.entry(for: target).deadlineDraft, "还未提交")
        store.redo()
        XCTAssertEqual(store.locate(task.id)?.date, target)
        XCTAssertEqual(store.entry(for: source).summary, "移动后新写的总结")
        XCTAssertEqual(store.entry(for: target).deadlineDraft, "还未提交")
        XCTAssertEqual(JournalStore(directory: store.directory).days, store.days)
    }

    @MainActor
    func testUndoCommittedDraftDoesNotEraseNewDraft() async throws {
        let store = try store()
        let day = date(6)
        store.setDeadlineDraft("first", on: day)
        store.commitDeadline(on: day)
        store.setDeadlineDraft("second", on: day)
        store.undo()
        XCTAssertTrue(store.entry(for: day).todos.isEmpty)
        XCTAssertEqual(store.entry(for: day).deadlineDraft, "second")
        store.redo()
        XCTAssertEqual(store.entry(for: day).todos.map(\.title), ["first"])
        XCTAssertEqual(store.entry(for: day).deadlineDraft, "second")
    }

    func testAllDayAndTimedDeadlineFilters() {
        var task = Todo(title: "deadline")
        task.dueDate = date(6, hour: 9)
        XCTAssertFalse(AgendaFilter.overdue.includes(task, now: date(6, hour: 22)))
        XCTAssertTrue(AgendaFilter.upcoming.includes(task, now: date(6, hour: 22)))
        XCTAssertTrue(AgendaFilter.overdue.includes(task, now: date(7, hour: 1)))
        task.dueHasTime = true
        XCTAssertTrue(AgendaFilter.overdue.includes(task, now: date(6, hour: 10)))
        task.completed = true
        XCTAssertFalse(AgendaFilter.overdue.includes(task, now: date(7)))
        XCTAssertFalse(AgendaFilter.upcoming.includes(task, now: date(5)))
    }

    @MainActor
    func testReminderPlanUsesDeadlineAndCancelsOnCompletion() async throws {
        let store = try store()
        let day = date(6)
        store.addTodo("[paper](https://example.com)", on: day)
        let task = try XCTUnwrap(store.entry(for: day).todos.first)
        store.updateTodo(task.id, scheduledDate: day, dueDate: date(8), dueHasTime: false, reminderMinutes: 60, repeatRule: .none)
        let first = try XCTUnwrap(ReminderPlan.pending(days: store.days, now: day).first)
        XCTAssertEqual(first.fireDate, date(8, hour: 8))
        XCTAssertEqual(first.title, "paper")
        store.moveTodo(task.id, to: date(7))
        let moved = try XCTUnwrap(ReminderPlan.pending(days: store.days, now: day).first)
        XCTAssertEqual(moved.id, first.id)
        XCTAssertEqual(moved.fireDate, first.fireDate)
        XCTAssertEqual(moved.dayKey, "2026-10-08", "点提醒跳到任务的截止日期那天")
        store.updateTodo(task.id, scheduledDate: date(7), dueDate: date(8, hour: 15), dueHasTime: true, reminderMinutes: 30, repeatRule: .none)
        XCTAssertEqual(ReminderPlan.pending(days: store.days, now: day).first?.fireDate, date(8, hour: 15).addingTimeInterval(-1800))
        store.toggleTodo(task.id, on: date(7))
        XCTAssertTrue(ReminderPlan.pending(days: store.days, now: day).isEmpty)
    }

    @MainActor
    func testLateWeeklyCompletionKeepsWeekdayAndCreatesOnlyOneSuccessor() async throws {
        let store = try store()
        let scheduled = date(5)
        store.addTodo("周一例会", on: scheduled)
        let task = try XCTUnwrap(store.entry(for: scheduled).todos.first)
        store.updateTodo(task.id, scheduledDate: scheduled, dueDate: date(5, hour: 16), dueHasTime: true, reminderMinutes: nil, repeatRule: .weekly)
        store.toggleTodo(task.id, on: scheduled, now: date(8))
        let next = try XCTUnwrap(store.entry(for: date(12)).todos.first)
        XCTAssertEqual(next.dueDate, date(12, hour: 16))
        XCTAssertFalse(next.completed)
        XCTAssertEqual(store.tasks().count, 2)
        store.undo()
        XCTAssertEqual(store.tasks().count, 1)
        XCTAssertFalse(store.entry(for: scheduled).todos[0].completed)
        store.redo()
        XCTAssertEqual(store.entry(for: date(12)).todos.first?.id, next.id)
        store.toggleTodo(task.id, on: scheduled, now: date(8))
        store.toggleTodo(task.id, on: scheduled, now: date(8))
        XCTAssertEqual(store.tasks().count, 2)
    }

    func testRecurrenceSkipsWeekendAndPreservesMonthEndAnchor() {
        XCTAssertEqual(RepeatRule.weekdays.nextDate(after: date(9)), date(12))
        let february = RepeatRule.monthly.nextDate(after: date(2027, 1, 31), monthDay: 31)
        XCTAssertEqual(february, date(2027, 2, 28))
        XCTAssertEqual(RepeatRule.monthly.nextDate(after: february!, monthDay: 31), date(2027, 3, 31))
        XCTAssertEqual(RepeatRule.daily.nextDate(after: date(31)), date(2026, 11, 1))
    }

    @MainActor
    func testRestorePreviewPreservesPendingEditsAndRejectsInvalidBackup() async throws {
        let store = try store()
        let day = date(6)
        store.addTodo("原始任务", on: day)
        store.setSummary("原始总结", on: day)
        let exported = store.directory.appendingPathComponent("export.json")
        try store.export(to: exported)
        let preview = try store.inspectBackup(exported)
        XCTAssertEqual(preview.taskCount, 1)
        XCTAssertEqual(preview.summaryCount, 1)
        store.setSummary("恢复前未落盘的总结", on: day)
        try store.restore(from: exported)
        XCTAssertEqual(store.entry(for: day).summary, "原始总结")
        let recovery = try XCTUnwrap(store.backups().first { $0.url.lastPathComponent.hasPrefix("before-restore-") })
        XCTAssertTrue(String(decoding: try Data(contentsOf: recovery.url), as: UTF8.self).contains("恢复前未落盘的总结"))
        let invalid = store.directory.appendingPathComponent("invalid.json")
        try Data("{\"version\":99,\"days\":{}}".utf8).write(to: invalid)
        let original = store.days
        XCTAssertThrowsError(try store.restore(from: invalid))
        XCTAssertEqual(store.days, original)
    }

    @MainActor
    func testDailyBackupsRetainThirtySnapshotsAndDoNotOverwriteToday() async throws {
        let store = try store()
        try FileManager.default.createDirectory(at: store.backupsDirectory, withIntermediateDirectories: true)
        for offset in 1...35 {
            let previous = JournalDates.calendar.date(byAdding: .day, value: -offset, to: Date())!
            try Data("{\"version\":4,\"days\":{}}".utf8).write(to: store.backupsDirectory.appendingPathComponent("\(JournalDates.key(previous)).json"))
        }
        store.addTodo("第一条", on: date(6))
        let daily = store.backupsDirectory.appendingPathComponent("\(JournalDates.key(Date())).json")
        let initial = try Data(contentsOf: daily)
        store.addTodo("第二条", on: date(6))
        XCTAssertEqual(try Data(contentsOf: daily), initial)
        XCTAssertEqual(store.backups().count, 30)
    }

    @MainActor
    func testCorruptStoreCanRecoverWithoutLosingOriginalBytes() async throws {
        let original = try store()
        original.addTodo("可恢复", on: date(6))
        let snapshot = original.directory.appendingPathComponent("valid.json")
        try original.export(to: snapshot)
        let broken = Data("broken json".utf8)
        try broken.write(to: original.databaseURL)
        let damaged = JournalStore(directory: original.directory)
        XCTAssertTrue(damaged.isReadOnly)
        try damaged.restore(from: snapshot)
        XCTAssertFalse(damaged.isReadOnly)
        XCTAssertEqual(damaged.tasks().count, 1)
        let recovery = try XCTUnwrap(damaged.backups().first { $0.url.lastPathComponent.hasPrefix("before-restore-") })
        XCTAssertEqual(try Data(contentsOf: recovery.url), broken)
    }
}
