import AppKit
import QuartzCore
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

/// 隐藏窗口里测日历定位到布局完成的延迟；不把它当成屏幕实际呈现的 FPS。
@MainActor
final class TaskTimelinePerformanceProbe: XCTestCase {
    func testExpandAndCollapseLongHistory() throws {
        guard ProcessInfo.processInfo.environment["TIMELINE_TASK_PROBE"] == "1" else { throw XCTSkip("probe only") }
        let today = JournalDates.calendar.startOfDay(for: Date())
        let days = (-90...6).map { JournalDates.calendar.date(byAdding: .day, value: $0, to: today)! }
        let tasks = days.flatMap { day in
            (0..<8).map { index -> ScheduledTask in
                var task = Todo(title: "Task \(index): Read **observations** #Research", completed: index % 3 != 0)
                task.dueDate = day
                return ScheduledTask(date: today, task: task)
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        for lazy in [false, true] {
            let presentation = TaskTimelinePresentation()
            let host = NSHostingView(rootView: HistoryProbeContent(store: store, tasks: tasks, today: today, presentation: presentation, lazy: lazy)
                .environmentObject(WorkspaceInteraction()))
            let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            defer { window.contentView = nil; window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            for expanding in [true, false] {
                TextLayoutProbe.reset()
                let started = CACurrentMediaTime()
                presentation.revealedDates = expanding ? Set(days) : []
                presentation.expanded = expanding ? Set(tasks.map(\.id)) : []
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                print(String(format: "TASK HISTORY lazy=%@ expand=%@ tasks=%d layout=%.2fms", String(lazy), String(expanding), tasks.count, (CACurrentMediaTime() - started) * 1000))
                TextLayoutProbe.report("history-\(lazy)-\(expanding)")
            }
        }
    }

    func testCalendarNavigationAndHistoryExpansion() throws {
        guard ProcessInfo.processInfo.environment["TIMELINE_TASK_PROBE"] == "1" else { throw XCTSkip("probe only") }
        let defaults = UserDefaults.standard
        let keys = ["tasksPaneExpanded", Prefs.hideCompleted]
        let previous = keys.map { defaults.object(forKey: $0) }
        defaults.set(true, forKey: keys[0]); defaults.set(false, forKey: keys[1])
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let today = JournalDates.calendar.startOfDay(for: Date())
        func day(_ offset: Int) -> Date { JournalDates.calendar.date(byAdding: .day, value: offset, to: today)! }
        var entry = DayEntry()
        for offset in -90...6 {
            for index in 0..<8 {
                var task = Todo(title: "Task \(offset)/\(index): Read the paper and record **observations** #Research", completed: offset < 0 && index % 3 != 0)
                task.dueDate = day(offset)
                task.number = entry.todos.count + 1
                entry.todos.append(task)
            }
        }
        struct Document: Encodable { let version = 8; let days: [String: DayEntry] }
        try JSONEncoder().encode(Document(days: [JournalDates.key(today): entry]))
            .write(to: directory.appendingPathComponent("journal.json"))
        let store = JournalStore(directory: directory)
        let host = NSHostingView(rootView: ContentView(store: store, loginItem: LoginItem())
            .environmentObject(ReminderScheduler(store: store)).environmentObject(WorkspaceInteraction())
            .environmentObject(CommandCenter()).environmentObject(ToastCenter()))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        for offset in [-60, -30, -15, -60, -60, -59, -58, -59, -59] {
            TextLayoutProbe.reset()
            let started = CACurrentMediaTime()
            NotificationCenter.default.post(name: .timelineNavigate, object: day(offset))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let first = (CACurrentMediaTime() - started) * 1000
            var longest = first
            let deadline = Date().addingTimeInterval(0.25)
            while Date() < deadline {
                let tick = CACurrentMediaTime()
                RunLoop.main.run(until: Date().addingTimeInterval(0.003))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                longest = max(longest, (CACurrentMediaTime() - tick) * 1000)
            }
            print(String(format: "TASK PROBE date=%d tasks=%d first-layout=%.2fms longest-main-step=%.2fms", offset, store.tasks().count, first, longest))
            TextLayoutProbe.report("task-navigation-\(offset)")
        }
    }
}

private struct HistoryProbeContent: View {
    let store: JournalStore
    let tasks: [ScheduledTask]
    let today: Date
    @ObservedObject var presentation: TaskTimelinePresentation
    let lazy: Bool

    var body: some View {
        ScrollView {
            TaskTimelineView(store: store, tasks: tasks, today: today, selectedDate: today,
                expanded: $presentation.expanded, requestedEdit: .constant(nil), navigate: { _ in },
                revealedDates: $presentation.revealedDates, usesLazyLayout: lazy)
        }
    }
}
