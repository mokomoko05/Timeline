import XCTest
@testable import TimelineCore

final class TaskPriorityTests: XCTestCase {
    private func date(_ day: Int, _ hour: Int = 0) -> Date {
        JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    private func item(_ number: Int, day: Int? = 18, hour: Int? = nil, priority: TaskPriority = .normal, position: Double? = nil) -> ScheduledTask {
        var task = Todo(title: "Task \(number)")
        task.number = number
        task.dueDate = day.map { date($0, hour ?? 0) }
        task.dueHasTime = hour != nil
        task.priority = priority
        task.listPosition = position
        return ScheduledTask(date: date(18), task: task)
    }

    func testLegacyAndUnknownPriorityDecodeAsNormal() throws {
        for suffix in ["", ",\"priority\":\"future-value\""] {
            let json = "{\"id\":\"\(UUID())\",\"title\":\"old\",\"completed\":false\(suffix)}"
            XCTAssertEqual(try JSONDecoder().decode(Todo.self, from: Data(json.utf8)).priority, .normal)
        }
        var task = Todo(title: "new")
        task.priority = .high
        XCTAssertEqual(try JSONDecoder().decode(Todo.self, from: JSONEncoder().encode(task)).priority, .high)
    }

    func testEveryColorPriorityPersistsAndSortsFromHighestToLowest() throws {
        let priorities: [TaskPriority] = [.urgent, .high, .normal, .lower, .low]
        for priority in priorities {
            var task = Todo(title: priority.rawValue)
            task.priority = priority
            XCTAssertEqual(try JSONDecoder().decode(Todo.self, from: JSONEncoder().encode(task)).priority, priority)
        }
        let tasks = priorities.reversed().enumerated().map { item($0.offset, priority: $0.element) }
        XCTAssertEqual(tasks.sorted(by: TaskSortMode.priority.precedes).map(\.task.priority), priorities)
    }

    func testDeadlineOrderUsesTimeThenPriorityAndKeepsAllDayBeforeNextDay() {
        let tasks = [item(1, hour: 15), item(2, priority: .high), item(3, hour: 9, priority: .low),
                     item(4, hour: 15, priority: .high), item(5, day: 19, hour: 0)]
        XCTAssertEqual(tasks.sorted(by: TaskSortMode.deadline.precedes).map { $0.task.number! }, [3, 4, 1, 2, 5])
    }

    func testPrioritySortRetainsDateGroupsAndManualPositionsOnlyAffectManualMode() {
        let tasks = [item(1, hour: 15, priority: .low, position: 0),
                     item(2, hour: 16, priority: .high, position: 1),
                     item(3, day: 19, priority: .high), item(4, day: nil, priority: .high)]
        XCTAssertEqual(TaskSortMode.priority.sorted(tasks, now: date(18, 8)).map { $0.task.number! }, [2, 1, 3, 4])
        let reversed = [item(1, hour: 15, position: 1), item(2, hour: 16, position: 0)]
        XCTAssertEqual(TaskSortMode.deadline.sorted(reversed, now: date(18, 8)).map { $0.task.number! }, [1, 2])
        XCTAssertEqual(TaskSortMode.manual.sorted(reversed, now: date(18, 8)).map { $0.task.number! }, [2, 1])
    }

    @MainActor
    func testCompletionKeepsItsDateGroupAndPositionAcrossSortModesUndoAndReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let now = date(18, 8)
        let tasks = try (0..<3).map { index in
            try XCTUnwrap(store.addParsedTodo("Task \(index)", on: now))
        }
        for (index, task) in tasks.enumerated() {
            store.setDeadline(task.id, to: date(18, 9 + index))
        }
        store.reorderTasks(tasks.reversed().map(\.id))
        let orders = TaskSortMode.allCases.map { $0.sorted(store.tasks(), now: now).map(\.id) }
        let target = tasks[1]
        store.toggleTodo(target.id, on: target.date, now: now)
        for (mode, order) in zip(TaskSortMode.allCases, orders) {
            XCTAssertEqual(mode.sorted(store.tasks(), now: now).map(\.id), order)
            XCTAssertEqual(TaskSortMode.group(for: try XCTUnwrap(store.locate(target.id)).task, now: now), 1)
        }
        store.undo()
        XCTAssertFalse(try XCTUnwrap(store.locate(target.id)).task.completed)
        store.redo()
        store.save()
        let reloaded = JournalStore(directory: directory)
        for (mode, order) in zip(TaskSortMode.allCases, orders) {
            XCTAssertEqual(mode.sorted(reloaded.tasks(), now: now).map(\.id), order)
        }
        reloaded.toggleTodo(target.id, on: target.date, now: now)
        for (mode, order) in zip(TaskSortMode.allCases, orders) {
            XCTAssertEqual(mode.sorted(reloaded.tasks(), now: now).map(\.id), order)
        }
        reloaded.dropTodo(target.id, on: target.date, now: now)
        XCTAssertEqual(TaskSortMode.group(for: try XCTUnwrap(reloaded.locate(target.id)).task, now: now), 7)
    }

    @MainActor
    func testPriorityPersistenceUndoRecurrenceAndBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let task = try XCTUnwrap(store.addParsedTodo("Read", on: date(18), priority: .high))
        store.undo()
        XCTAssertNil(store.locate(task.id), "Priority and creation share one undo step")
        store.redo()
        XCTAssertEqual(store.locate(task.id)?.task.priority, .high)
        store.setPriority(.low, for: task.id)
        store.undo()
        XCTAssertEqual(store.locate(task.id)?.task.priority, .high)
        store.redo()
        XCTAssertEqual(store.locate(task.id)?.task.priority, .low)
        store.updateTodo(task.id, scheduledDate: date(18), dueDate: date(18, 15), dueHasTime: true,
                         reminderMinutes: 30, repeatRule: .daily, priority: .high)
        store.toggleTodo(task.id, on: date(18), now: date(18, 16))
        let next = try XCTUnwrap(store.tasks().first { !$0.task.completed })
        XCTAssertEqual(next.task.priority, .high)
        XCTAssertEqual(next.task.dueDate, date(19, 15))
        store.save()
        let snapshot = JournalStore(directory: directory, readOnlySnapshot: true)
        XCTAssertEqual(snapshot.locate(next.id)?.task.priority, .high)
        snapshot.setPriority(.low, for: next.id)
        XCTAssertEqual(snapshot.locate(next.id)?.task.priority, .high)
        let backup = directory.appendingPathComponent("export.json")
        try store.export(to: backup)
        store.setPriority(.low, for: next.id)
        try store.restore(from: backup)
        XCTAssertEqual(store.locate(next.id)?.task.priority, .high)
        store.setDeadline(next.id, to: nil)
        XCTAssertEqual(store.locate(next.id)?.task.priority, .high)
        XCTAssertNil(store.locate(next.id)?.task.reminderMinutes)
    }
}
