import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class CalendarViewReuseTests: XCTestCase {
    func testCalendarPreviewReusesTextAndUpdatesTaskActionsAfterChangingDates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let day = JournalDates.calendar.startOfDay(for: Date())
        let next = JournalDates.calendar.date(byAdding: .month, value: 1, to: day)!
        var first = Todo(title: "Original [link](https://example.com/first)")
        first.dueDate = day
        var second = Todo(title: "Replacement [link](https://example.com/second)", completed: true)
        second.dueDate = next
        second.calendarName = "Calendar alias"
        var edits: [UUID] = []
        func cell(_ task: Todo, _ date: Date) -> DeadlineDayCell {
            let item = ScheduledTask(date: day, task: task)
            return DeadlineDayCell(store: store, date: date, selectedDate: date,
                displayedMonth: JournalDates.monthStart(date), height: 150, items: [item], dueToday: [item],
                logCount: 0, readOnly: false, today: false, select: {}, open: {}, editTask: { edits.append($0.id) })
        }
        let host = NSHostingView(rootView: cell(first, day))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 150), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        func texts(_ view: NSView) -> [InteractiveTaskText] {
            (view as? InteractiveTaskText).map { [$0] } ?? view.subviews.flatMap(texts)
        }
        func handles(_ view: NSView) -> [TaskHandleView] {
            (view as? TaskHandleView).map { [$0] } ?? view.subviews.flatMap(handles)
        }
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        let original = try XCTUnwrap(texts(host).first)
        original.setSelectedRange(NSRange(location: 2, length: 3))
        host.rootView = cell(second, next)
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        let updated = try XCTUnwrap(texts(host).first)
        XCTAssertTrue(original === updated, "Changing the date should update the text view in its existing preview slot")
        XCTAssertEqual(updated.dragTaskID, second.id)
        XCTAssertTrue(updated.completed)
        XCTAssertEqual(updated.string, "Calendar alias")
        XCTAssertEqual(updated.selectedRange().length, 0)
        XCTAssertEqual(updated.linkRegions().first?.url.absoluteString, "https://example.com/second")
        updated.onEdit?()
        XCTAssertEqual(edits, [second.id], "Double-click editing must use the replacement task")
        XCTAssertEqual(handles(host).compactMap(\.taskID), [second.id], "Drag and priority controls must use the replacement task")
        var third = Todo(title: second.title, completed: true)
        third.calendarName = second.calendarName
        third.dueDate = next
        updated.setSelectedRange(NSRange(location: 0, length: 3))
        host.rootView = cell(third, next)
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        let sameTitle = try XCTUnwrap(texts(host).first)
        XCTAssertTrue(sameTitle === updated)
        XCTAssertEqual(sameTitle.selectedRange().length, 0, "Different tasks with identical titles must not share a selection")
        XCTAssertEqual(sameTitle.dragTaskID, third.id)
        sameTitle.onEdit?()
        XCTAssertEqual(edits, [second.id, third.id])
    }
}
