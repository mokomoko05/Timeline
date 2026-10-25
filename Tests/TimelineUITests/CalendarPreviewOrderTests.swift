import XCTest
import TimelineCore
@testable import Timeline

final class CalendarPreviewOrderTests: XCTestCase {
    private func task(_ title: String, due: Date, hasTime: Bool = false, position: Double? = nil) -> ScheduledTask {
        var todo = Todo(title: title)
        todo.dueDate = due
        todo.dueHasTime = hasTime
        todo.listPosition = position
        return ScheduledTask(date: due, task: todo)
    }

    func testCalendarCellFollowsTheManualOrderOfTheDay() {
        let day = JournalDates.calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let morning = day.addingTimeInterval(9 * 3600)
        let items = [
            task("A", due: morning, hasTime: true, position: 3),
            task("B", due: day, position: 1),
            task("C", due: day, position: 2),
        ]
        XCTAssertEqual(DeadlineDayCell.previewItems(dueItems: items, hideCompleted: false).map(\.task.title), ["B", "C", "A"],
                       "和时间轴里拖动调整后的顺序一致，而不是按截止时间重排")
    }

    func testCalendarCellMatchesTheTimelineOrderWithoutManualPositions() {
        let day = JournalDates.calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let items = [task("late", due: day.addingTimeInterval(15 * 3600), hasTime: true), task("early", due: day.addingTimeInterval(8 * 3600), hasTime: true)]
        XCTAssertEqual(DeadlineDayCell.previewItems(dueItems: items, hideCompleted: false).map(\.task.title),
                       items.sorted(by: TaskTimelineSection.precedes).map(\.task.title))
    }
}
