import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class TaskTimelineTests: XCTestCase {
    func testFinishedRunsFoldInPlaceAndRevealOnlyTheRequestedTask() {
        let day = Date()
        func task(_ title: String, completed: Bool = false, dropped: Bool = false) -> ScheduledTask {
            var todo = Todo(title: title)
            todo.completed = completed
            todo.dropped = dropped
            return ScheduledTask(date: day, task: todo)
        }
        let tasks = [task("completed", completed: true), task("dropped", completed: true, dropped: true),
                     task("open"), task("later completed", completed: true), task("later open")]
        let folded = TaskTimelineItem.items(for: tasks)
        XCTAssertEqual(folded.map(\.folded), [true, false, true, false])
        XCTAssertEqual(folded[0].tasks.map(\.id), tasks.prefix(2).map(\.id))
        XCTAssertEqual(folded.flatMap(\.tasks).map(\.id), tasks.map(\.id), "Folding preserves chronological order")
        let revealed = TaskTimelineItem.items(for: tasks, expanded: [tasks[1].id])
        XCTAssertEqual(revealed.map(\.folded), [true, false, false, true, false])
        XCTAssertEqual(revealed[1].id, tasks[1].id)
        XCTAssertEqual(TaskTimelineItem.items(for: tasks, expanded: Set(tasks.map(\.id))).count, tasks.count)
        XCTAssertTrue(TaskTimelineItem.items(for: []).isEmpty)
    }

    func testHundredsOfFinishedTasksOccupyOneTimelineRow() {
        let tasks = (0..<300).map { index in
            var task = Todo(title: "Task \(index)")
            task.completed = index < 299
            return ScheduledTask(date: Date(), task: task)
        }
        let rows = TaskTimelineItem.items(for: tasks)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].tasks.count, 299)
        XCTAssertFalse(rows[1].folded)
    }

    func testConnectorsMeetAcrossSpacingAndStopAtTheFirstAndLastNodes() {
        let size = CGRect(x: 0, y: 0, width: 30, height: 60)
        let first = TaskTimelineConnector(position: .init(hasPrevious: false, hasNext: true)).path(in: size).boundingRect
        let middle = TaskTimelineConnector(position: .init(hasPrevious: true, hasNext: true)).path(in: size).boundingRect
        let last = TaskTimelineConnector(position: .init(hasPrevious: true, hasNext: false)).path(in: size).boundingRect
        XCTAssertEqual(first.minY, size.midY + 6)
        XCTAssertEqual(first.maxY, size.maxY + TaskReorderModel.spacing / 2)
        XCTAssertEqual(middle.minY, -TaskReorderModel.spacing / 2)
        XCTAssertEqual(middle.maxY, first.maxY)
        XCTAssertEqual(last.maxY, size.midY - 6)
        XCTAssertTrue(TaskTimelineConnector(position: .init(hasPrevious: false, hasNext: false)).path(in: size).isEmpty)
    }

    func testTimelineRowsKeepLongTitlesReadableAtLargerTextSizes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let focus = FocusSession()
        focus.store = store
        let tasks = try ["Read the paper #reading", "Collect reference material #reading", "Compare the results with the previous experiments and write observations", "Write a short review #writing"].map {
            try XCTUnwrap(store.addParsedTodo($0, on: Date()))
        }
        store.setDeadline(tasks[0].id, to: Date())
        store.setDeadline(tasks[2].id, to: JournalDates.calendar.date(byAdding: .day, value: 2, to: Date())!)
        store.dropTodo(tasks[3].id, on: tasks[3].date)
        store.setPriority(.high, for: tasks[0].id)
        store.setPriority(.lower, for: tasks[1].id)
        store.toggleTodo(tasks[1].id, on: tasks[1].date)
        let updated = try tasks.map { try XCTUnwrap(store.locate($0.id)) }
        for scale in [1.0, 1.2] {
            let view = VStack(spacing: TaskReorderModel.spacing) {
                ForEach(Array(updated.enumerated()), id: \.element.id) { index, item in
                    ManagedTaskRow(store: store, date: item.date, task: item.task, requestedEdit: .constant(nil),
                                   timeline: .init(hasPrevious: index > 0, hasNext: index < tasks.count - 1))
                }
            }
            .padding(16).frame(width: 480).background(Palette.background)
            .environmentObject(WorkspaceInteraction()).environment(\.focusSession, focus)
            .environment(\.typography, AppTypography(scale: scale))
            let host = NSHostingView(rootView: view)
            let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            func titles(_ view: NSView) -> [InteractiveTaskText] {
                (view as? InteractiveTaskText).map { [$0] } ?? view.subviews.flatMap(titles)
            }
            XCTAssertEqual(titles(host).count, tasks.count - 2)
            func handles(_ view: NSView) -> [TaskHandleView] {
                (view as? TaskHandleView).map { [$0] } ?? view.subviews.flatMap(handles)
            }
            XCTAssertEqual(handles(host).count, tasks.count)
            XCTAssertTrue(handles(host).allSatisfy { $0.priorityColor != nil && !$0.drawsHandle },
                          "Every task uses its priority dot as the only native drag handle")
            for title in titles(host) { XCTAssertGreaterThan(title.bounds.width, 100) }
            XCTAssertLessThan(host.fittingSize.height, 350)
            if let destination = ProcessInfo.processInfo.environment["TIMELINE_LIST_SNAPSHOT"],
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination + "-\(Int(scale * 100)).png"))
            }
        }
    }

    func testCompletedTimelineRowStaysOneLineWithLargeTextAndRestoresItsControls() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let item = try XCTUnwrap(store.addParsedTodo(String(repeating: "A long completed task ", count: 12) + "#reading", on: Date()))
        store.toggleTodo(item.id, on: item.date)
        let completed = try XCTUnwrap(store.locate(item.id))
        for scale in [1.0, 1.2, 1.5] {
            let row = ManagedTaskRow(store: store, date: completed.date, task: completed.task, requestedEdit: .constant(nil),
                                     timeline: .init(hasPrevious: true, hasNext: true))
                .frame(width: 360).environmentObject(WorkspaceInteraction())
                .environment(\.typography, AppTypography(scale: scale))
            let host = NSHostingView(rootView: row)
            let size = host.fittingSize
            XCTAssertEqual(size.width, 360, accuracy: 1)
            XCTAssertLessThanOrEqual(size.height, 26 * scale)
        }
        store.toggleTodo(item.id, on: item.date)
        let restored = try XCTUnwrap(store.locate(item.id))
        let host = NSHostingView(rootView:
            ManagedTaskRow(store: store, date: restored.date, task: restored.task, requestedEdit: .constant(nil),
                           timeline: .init(hasPrevious: true, hasNext: true))
                .frame(width: 360).environmentObject(WorkspaceInteraction()))
        XCTAssertGreaterThan(host.fittingSize.height, 40)
    }
}
