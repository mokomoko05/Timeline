import XCTest
@testable import TimelineCore

@MainActor
final class TaskTimeTests: XCTestCase {
    private func date(_ day: Int, _ hour: Int = 0) -> Date {
        JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    private func store() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory)
    }

    func testOldTasksDecodeAndRangesRoundTripWithoutChangingDeadline() throws {
        var task = Todo(title: "Read")
        task.dueDate = date(29, 11)
        task.dueHasTime = true
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(task)) as? [String: Any])
        object.removeValue(forKey: "startDate")
        let legacy = try JSONDecoder().decode(Todo.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.startDate)
        XCTAssertEqual(legacy.effectiveDeadline, task.dueDate)
        task.startDate = date(29, 9)
        XCTAssertEqual(try JSONDecoder().decode(Todo.self, from: encoder.encode(task)), task)
        XCTAssertEqual(task.timelineDate, date(29, 9))
        XCTAssertEqual(task.effectiveDeadline, date(29, 11))
        XCTAssertEqual(task.timelineTimeLabel, "09:00\n11:00")
        task.startDate = date(29, 12)
        XCTAssertNil(try JSONDecoder().decode(Todo.self, from: encoder.encode(task)).startDate, "坏数据不应制造负时长")
    }

    func testRangeSortReminderCalendarMoveAndUndoUseTheCorrectEndpoint() throws {
        let store = store()
        let first = try XCTUnwrap(store.addParsedTodo("Long task", on: date(29)))
        let second = try XCTUnwrap(store.addParsedTodo("Deadline", on: date(29)))
        store.updateTodo(first.id, scheduledDate: first.date, dueDate: date(30, 1), dueHasTime: true,
                         reminderMinutes: 15, repeatRule: .none, startDate: .some(date(29, 23)))
        store.updateTodo(second.id, scheduledDate: second.date, dueDate: date(29, 23).addingTimeInterval(1800), dueHasTime: true,
                         reminderMinutes: nil, repeatRule: .none)
        XCTAssertEqual(store.tasks().sorted(by: ScheduledTask.listOrder).map(\.id), [first.id, second.id])
        XCTAssertEqual(TaskSortMode.deadline.sorted(store.tasks(), now: date(29)).map(\.id), [first.id, second.id])
        XCTAssertEqual(store.calendarTasks(on: date(29)).count, 2)
        XCTAssertTrue(store.calendarTasks(on: date(30)).isEmpty)
        XCTAssertEqual(ReminderPlan.pending(days: store.days, now: date(29)).first?.fireDate, date(29, 23).addingTimeInterval(-900))
        XCTAssertEqual(ReminderPlan.pending(days: store.days, now: date(29)).first?.dayKey, "2026-10-29")
        store.setDeadline(first.id, to: date(31))
        XCTAssertEqual(store.locate(first.id)?.task.startDate, date(31, 23))
        XCTAssertEqual(store.locate(first.id)?.task.dueDate, JournalDates.calendar.date(byAdding: .day, value: 2, to: date(30, 1)))
        store.undo()
        XCTAssertEqual(store.locate(first.id)?.task.startDate, date(29, 23))
        store.setDeadline(first.id, to: nil)
        XCTAssertNil(store.locate(first.id)?.task.startDate)
        XCTAssertNil(store.locate(first.id)?.task.reminderMinutes)
        store.undo()
        store.save()
        let reloaded = JournalStore(directory: store.directory)
        XCTAssertEqual(reloaded.locate(first.id)?.task.timeRange, DateInterval(start: date(29, 23), end: date(30, 1)))
    }

    func testInvalidIntervalDoesNotWriteAndExplicitDeadlineClearsOnlyStart() throws {
        let store = store()
        let item = try XCTUnwrap(store.addParsedTodo("Task", on: date(29)))
        store.updateTodo(item.id, scheduledDate: item.date, dueDate: date(29, 10), dueHasTime: true,
                         reminderMinutes: nil, repeatRule: .none, startDate: .some(date(29, 11)))
        XCTAssertNil(store.locate(item.id)?.task.dueDate)
        store.updateTodo(item.id, scheduledDate: item.date, dueDate: date(29, 11), dueHasTime: true,
                         reminderMinutes: nil, repeatRule: .none, startDate: .some(date(29, 10)))
        store.setPriority(.high, for: item.id)
        store.moveTodo(item.id, to: date(28))
        XCTAssertEqual(store.locate(item.id)?.task.startDate, date(29, 10))
        store.updateTodo(item.id, scheduledDate: date(28), dueDate: date(29, 11), dueHasTime: true,
                         reminderMinutes: nil, repeatRule: .none, startDate: .some(nil))
        XCTAssertNil(store.locate(item.id)?.task.startDate)
        XCTAssertEqual(store.locate(item.id)?.task.dueDate, date(29, 11))
    }

    func testRepeatingTaskShiftsBothEndpointsAndKeepsDuration() throws {
        let store = store()
        let item = try XCTUnwrap(store.addParsedTodo("Night work", on: date(29)))
        store.updateTodo(item.id, scheduledDate: item.date, dueDate: date(30, 1), dueHasTime: true,
                         reminderMinutes: 30, repeatRule: .daily, startDate: .some(date(29, 23)))
        store.toggleTodo(item.id, on: item.date, now: date(29, 23))
        let next = try XCTUnwrap(store.entry(for: date(30)).todos.first)
        XCTAssertEqual(next.startDate, date(30, 23))
        XCTAssertEqual(next.dueDate, date(31, 1))
        XCTAssertEqual(next.timeRange?.duration, 7200)
        XCTAssertEqual(next.reminderMinutes, 30)
    }

    func testCreationAndDraftValidationSupportAllThreeModes() throws {
        var options = TaskCreationOptions()
        options.overridesDeadline = true
        options.dueDate = date(30, 1)
        options.dueHasTime = true
        options.startDate = date(29, 23)
        let task = options.applying(to: Todo(title: "Night work"))
        XCTAssertEqual(task.timelineTimeLabel, "23:00\n10/30\n01:00")
        let store = store()
        let created = try XCTUnwrap(store.addParsedTodo("Night work", on: date(29), options: options))
        XCTAssertEqual(created.task.timeRange, task.timeRange)
        store.undo()
        XCTAssertTrue(store.tasks().isEmpty, "新建时间段任务可一次撤销")
        var draft = TaskTimeDraft(task: task)
        XCTAssertEqual(draft.mode, .interval)
        draft.end = draft.start
        XCTAssertFalse(draft.isValid)
        draft.mode = .deadline
        XCTAssertTrue(draft.isValid)
        XCTAssertNil(draft.startDate)
        draft.mode = .allDay
        XCTAssertFalse(draft.hasTime)
    }
}
