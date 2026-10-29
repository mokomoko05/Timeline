import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class TaskTimeRangeTests: XCTestCase {
    func testCrossDayIntervalBelongsToStartDayAndLabelsBothEndpoints() {
        let day = JournalDates.calendar.startOfDay(for: Date())
        var task = Todo(title: "Night work")
        task.startDate = day.addingTimeInterval(23 * 3600)
        task.dueDate = day.addingTimeInterval(25 * 3600)
        task.dueHasTime = true
        let sections = TaskTimelineSection.sections(for: [ScheduledTask(date: day, task: task)], today: day)
        let found = sections.first { $0.tasks.contains(where: { $0.id == task.id }) }
        XCTAssertEqual(found?.id, TaskTimelineSection.dayID(day))
        XCTAssertEqual(TaskDeadlineButton.label(for: task, compact: true), task.timelineTimeLabel)
        XCTAssertTrue(TaskDeadlineButton.label(for: task).contains("23:00"))
        XCTAssertTrue(TaskDeadlineButton.label(for: task).contains("01:00"))
    }

    func testEditorsAndIntervalRowsRenderWithoutClippingAtNarrowWidths() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let day = JournalDates.calendar.startOfDay(for: Date())
        let created = try XCTUnwrap(store.addParsedTodo("Read and take notes #reading", on: day))
        store.updateTodo(created.id, scheduledDate: day, dueDate: day.addingTimeInterval(12 * 3600), dueHasTime: true,
                         reminderMinutes: nil, repeatRule: .none, startDate: .some(day.addingTimeInterval(9 * 3600)))
        let task = try XCTUnwrap(store.locate(created.id)).task
        var crossDay = task
        crossDay.dueDate = day.addingTimeInterval(25 * 3600)
        for (name, view, width) in [
            ("editor", AnyView(TaskDeadlineEditor(store: store, task: task, close: {})), 360.0),
            ("row", AnyView(ManagedTaskRow(store: store, date: day, task: task, requestedEdit: .constant(nil), timeline: true)
                .environmentObject(WorkspaceInteraction())), 400.0),
            ("cross-day", AnyView(ManagedTaskRow(store: store, date: day, task: crossDay, requestedEdit: .constant(nil), timeline: true)
                .environmentObject(WorkspaceInteraction())), 400.0)
        ] {
            let host = NSHostingView(rootView: LocalizedRoot { view.frame(width: width) })
            let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            try await Task.sleep(for: .milliseconds(50))
            window.setContentSize(NSSize(width: width, height: host.fittingSize.height))
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1)
            XCTAssertGreaterThan(host.fittingSize.height, name == "editor" ? 100 : 32)
            XCTAssertLessThan(host.fittingSize.height, name == "editor" ? 400 : 140)
            if let output = ProcessInfo.processInfo.environment["TIMELINE_TIME_PREVIEW"],
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output + "/" + name + ".png"))
            }
        }
    }
}
