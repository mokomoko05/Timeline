import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class TaskTimelineNavigationTests: XCTestCase {
    func testSelectingTheSameTaskAgainAfterScrollingReturnsItToView() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let today = JournalDates.calendar.startOfDay(for: Date())
        var tasks: [ScheduledTask] = []
        for offset in 0..<35 {
            let item = try XCTUnwrap(store.addParsedTodo("Task \(offset)", on: today))
            store.setDeadline(item.id, to: JournalDates.calendar.date(byAdding: .day, value: offset, to: today)!)
            tasks.append(try XCTUnwrap(store.locate(item.id)))
        }
        let target = tasks[2]
        let interaction = WorkspaceInteraction()
        let host = NSHostingView(rootView: TaskTimelinePane(store: store, tasks: tasks, today: today, selectedDate: today,
            presentation: TaskTimelinePresentation(), requestedEdit: .constant(nil), scrollTarget: .constant(nil),
            scrollGroup: .constant(nil), rowRegions: TaskRowRegions(), navigate: { _ in }, next: {})
            .environmentObject(interaction))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        func views<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { views(type, $0) }
        }
        try await Task.sleep(for: .milliseconds(100))
        interaction.selectedTaskID = target.id
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let first = try XCTUnwrap(views(TaskHandleView.self, host).first { $0.taskID == target.id })
        XCTAssertFalse(first.visibleRect.isEmpty)
        let scroll = try XCTUnwrap(views(NSScrollView.self, host).first)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1400))
        scroll.reflectScrolledClipView(scroll.contentView)
        interaction.selectedTaskID = nil
        try await Task.sleep(for: .milliseconds(100))
        interaction.selectedTaskID = target.id
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let selected = views(TaskHandleView.self, host).first { $0.taskID == target.id }
        XCTAssertTrue(selected.map { !$0.visibleRect.isEmpty } ?? false, "Reselecting the task must scroll even when the previous navigation request targeted the same task")
    }

    func testRevealUndatedTaskInLazyTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let today = JournalDates.calendar.startOfDay(for: Date())
        for offset in 0..<50 {
            let item = try XCTUnwrap(store.addParsedTodo("Dated task \(offset)", on: today))
            store.setDeadline(item.id, to: JournalDates.calendar.date(byAdding: .day, value: offset, to: today)!)
        }
        let target = try XCTUnwrap(store.addParsedTodo("Undated target", on: today))
        let defaults = InMemoryDefaults()
        defaults.set(true, forKey: "tasksPaneExpanded")
        let host = NSHostingView(rootView: ContentView(store: store, loginItem: LoginItem())
            .environmentObject(ReminderScheduler(store: store)).environmentObject(WorkspaceInteraction())
            .environmentObject(CommandCenter()).environmentObject(ToastCenter()).defaultAppStorage(defaults))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        NotificationCenter.default.post(name: .timelineReveal, object: target.id)
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        func handles(_ view: NSView) -> [TaskHandleView] {
            (view as? TaskHandleView).map { [$0] } ?? view.subviews.flatMap(handles)
        }
        let handle = try XCTUnwrap(handles(host).first { $0.taskID == target.id && $0.reorder != nil })
        XCTAssertFalse(handle.visibleRect.intersection(handle.bounds).isEmpty, "Revealed undated task must be visible")
    }
}
