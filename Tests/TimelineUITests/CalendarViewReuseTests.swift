import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class CalendarViewReuseTests: XCTestCase {
    func testMainCalendarShowsEveryDateAndFirstWeekTasksAcrossMonthChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        func date(_ month: Int, _ day: Int = 1) -> Date {
            JournalDates.calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
        }
        for day in 1...7 {
            let task = try XCTUnwrap(store.addParsedTodo("November day \(day)", on: date(11, day)))
            store.setDeadline(task.id, to: date(11, day))
        }
        func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
        }
        for sundayFirst in [false, true] {
            let defaults = InMemoryDefaults()
            defaults.set(sundayFirst, forKey: Prefs.weekStartsSunday)
            let host = NSHostingView(rootView: ContentView(store: store, loginItem: LoginItem())
                .environmentObject(ReminderScheduler(store: store)).environmentObject(WorkspaceInteraction())
                .environmentObject(CommandCenter()).environmentObject(ToastCenter())
                .defaultAppStorage(defaults))
            let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            defer { window.contentView = nil; window.close() }
            try await Task.sleep(for: .milliseconds(100))
            for month in [11, 10, 11, 12, 11] {
                NotificationCenter.default.post(name: .timelineNavigate, object: date(month))
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let expected = JournalDates.monthGrid(date(month), weekStart: sundayFirst ? 1 : 2)
                let cells = descendants(CalendarClickView.self, in: host)
                XCTAssertEqual(cells.count, expected.count, "Every date must have a cell, including the first seven grid positions; month=\(month), sundayFirst=\(sundayFirst)")
                let frames = cells.map { $0.convert($0.bounds, to: host) }
                XCTAssertEqual(Set(frames.map { "\($0.minX),\($0.minY)" }).count, expected.count, "Date cells must not overlap each other")
                if month == 11 {
                    let previews = descendants(InteractiveTaskText.self, in: host).filter(\.compactLines)
                    for day in 1...7 {
                        let preview = previews.first { $0.source == "November day \(day)" }
                        XCTAssertNotNil(preview, "November \(day) must show its task preview")
                    }
                }
            }
        }
    }

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
