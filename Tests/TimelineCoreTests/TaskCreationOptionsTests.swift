import XCTest
@testable import TimelineCore

@MainActor
final class TaskCreationOptionsTests: XCTestCase {
    func testCreationChoicesOverrideParsedDeadlineForBatchAndUndoTogether() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let day = JournalDates.calendar.startOfDay(for: Date())
        let due = day.addingTimeInterval(15 * 3600)
        var options = TaskCreationOptions()
        options.priority = .urgent
        options.overridesDeadline = true
        options.dueDate = due
        options.dueHasTime = true
        store.setDeadlineDraft("明天 读论文 #reading\n后天 写总结", on: day)
        let tasks = store.commitDraft(on: day, options: options)
        XCTAssertEqual(tasks.count, 2)
        XCTAssertTrue(tasks.allSatisfy { $0.task.priority == .urgent && $0.task.dueDate == due && $0.task.dueHasTime })
        XCTAssertEqual(tasks.first?.task.tags, ["reading"])
        store.undo()
        XCTAssertTrue(store.tasks().isEmpty)
        store.redo()
        XCTAssertEqual(store.tasks().count, 2)
        options.dueDate = nil
        let cleared = try XCTUnwrap(store.addParsedTodo("明天 提前30分钟 Read", on: day, options: options))
        XCTAssertNil(cleared.task.dueDate)
        XCTAssertNil(cleared.task.reminderMinutes)
        XCTAssertFalse(cleared.task.dueHasTime)
        XCTAssertEqual(cleared.task.priority, .urgent)
        let parsed = try XCTUnwrap(store.addParsedTodo("明天 Read", on: day))
        XCTAssertNotNil(parsed.task.dueDate, "Without an explicit choice natural-language dates still work")
    }
}
