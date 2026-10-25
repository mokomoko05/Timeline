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

final class CalendarOverflowTests: XCTestCase {
    func testOverflowRowReplacesTheLastRowThatDoesNotFit() {
        // 可用高度 120 - 12 - 18 = 90，每行 22 + 3：放得下 3 行。
        XCTAssertEqual(DeadlineDayCell.visibleCount(total: 2, cellHeight: 120, headerHeight: 18, rowHeight: 22), 2)
        XCTAssertEqual(DeadlineDayCell.visibleCount(total: 3, cellHeight: 120, headerHeight: 18, rowHeight: 22), 3)
        XCTAssertEqual(DeadlineDayCell.visibleCount(total: 7, cellHeight: 120, headerHeight: 18, rowHeight: 22), 2, "第三行换成「还有 5 项」")
        XCTAssertEqual(DeadlineDayCell.visibleCount(total: 4, cellHeight: 20, headerHeight: 18, rowHeight: 22), 0)
    }
}
