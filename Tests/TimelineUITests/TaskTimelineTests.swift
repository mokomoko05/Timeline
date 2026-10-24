import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class TaskTimelineTests: XCTestCase {
    func testCalendarReturnKeepsSourceAndDestinationDotsReorderable() async throws {
        for destination in [day(1), nil] as [Date?] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory); TaskDragSession.shared.end() }
            let store = JournalStore(directory: directory)
            let source = try ["Moving", "Source first", "Source second"].map { try XCTUnwrap(store.addParsedTodo($0, on: today)) }
            for item in source { store.setDeadline(item.id, to: today) }
            let target = try ["Target first", "Target second"].map { try XCTUnwrap(store.addParsedTodo($0, on: today)) }
            if let destination { for item in target { store.setDeadline(item.id, to: destination) } }
            let host = NSHostingView(rootView: LiveTaskTimeline(store: store, today: today))
            let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.contentView = nil; window.close() }
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()

            TaskDragSession.shared.begin(source[0].id, origin: .calendar)
            try await Task.sleep(for: .milliseconds(50))
            let drop = CalendarTaskDropTarget(store: store, destination: destination, calendarSourceOnly: true, targeted: .constant(false))
            XCTAssertTrue(drop.receive([TaskDragPayload.provider(source[0].id)]))
            XCTAssertNil(TaskDragSession.shared.activeID)
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()

            func handles(_ view: NSView) -> [TaskHandleView] {
                (view as? TaskHandleView).map { [$0] } ?? view.subviews.flatMap(handles)
            }
            func moveToBottom(_ id: UUID) throws {
                let dot = try XCTUnwrap(handles(host).first { $0.taskID == id })
                let start = dot.convert(NSPoint(x: dot.bounds.midX, y: dot.bounds.midY), to: nil)
                let hit = try XCTUnwrap(host.hitTest(host.superview?.convert(start, from: nil) ?? start))
                XCTAssertTrue(hit === dot, "日历放置结束后，圆点必须能收到鼠标事件")
                func event(_ type: NSEvent.EventType, delta: CGFloat = 0) throws -> NSEvent {
                    try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x, y: start.y - delta), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                }
                window.sendEvent(try event(.leftMouseDown))
                window.sendEvent(try event(.leftMouseDragged, delta: 1000))
                XCTAssertTrue(dot.isReordering, "从日历摘下任务后，原组和目标组都应能立即拿起圆点")
                window.sendEvent(try event(.leftMouseUp, delta: 1000))
            }
            try moveToBottom(source[1].id)
            XCTAssertEqual(store.tasks().filter { $0.task.dueDate == today }.sorted(by: TaskTimelineSection.precedes).map(\.id), [source[2].id, source[1].id])
            try moveToBottom(source[0].id)
            let expectedTarget = [target[0].id, target[1].id, source[0].id]
            let saved = JournalStore(directory: directory).tasks()
            XCTAssertEqual(saved.filter { $0.task.dueDate == destination }.sorted(by: TaskTimelineSection.precedes).map(\.id), expectedTarget)
            XCTAssertEqual(saved.first { $0.id == source[0].id }?.task.dueDate, destination)
        }
    }

    func testMainWindowDispatchesDotReorderAfterSelectionRefresh() async throws {
        let defaults = UserDefaults.standard
        let previousExpanded = defaults.object(forKey: "tasksPaneExpanded")
        defaults.set(true, forKey: "tasksPaneExpanded")
        defer {
            if let previousExpanded { defaults.set(previousExpanded, forKey: "tasksPaneExpanded") }
            else { defaults.removeObject(forKey: "tasksPaneExpanded") }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let items = try ["First", "Second", "Third"].map { try XCTUnwrap(store.addParsedTodo($0, on: today)) }
        for item in items { store.setDeadline(item.id, to: today) }
        let interaction = WorkspaceInteraction()
        let host = NSHostingView(rootView: ContentView(store: store, loginItem: LoginItem())
            .environmentObject(ReminderScheduler(store: store))
            .environmentObject(interaction)
            .environmentObject(CommandCenter())
            .environmentObject(ToastCenter()))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        func handles(_ view: NSView) -> [TaskHandleView] {
            (view as? TaskHandleView).map { [$0] } ?? view.subviews.flatMap(handles)
        }
        let dot = try XCTUnwrap(handles(host).first { $0.taskID == items[0].id && $0.reorder != nil })
        let start = dot.convert(NSPoint(x: dot.bounds.midX, y: dot.bounds.midY), to: nil)
        let hit = try XCTUnwrap(host.hitTest(host.superview?.convert(start, from: nil) ?? start))
        XCTAssertTrue(hit === dot, "Main window dot hit: \(type(of: hit))")
        func mouse(_ type: NSEvent.EventType, _ delta: CGFloat = 0) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x, y: start.y - delta), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        window.sendEvent(try mouse(.leftMouseDown))
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(interaction.selectedTaskID, items[0].id)
        window.sendEvent(try mouse(.leftMouseDragged, 5))
        XCTAssertTrue(dot.isReordering)
        window.sendEvent(try mouse(.leftMouseDragged, 1000))
        window.sendEvent(try mouse(.leftMouseUp, 1000))
        XCTAssertEqual(store.tasks().sorted(by: TaskTimelineSection.precedes).map(\.id), [items[1].id, items[2].id, items[0].id])
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let displayedDots = handles(host).filter { $0.reorder != nil }
            .sorted { host.convert($0.bounds, from: $0).midY < host.convert($1.bounds, from: $1).midY }
        XCTAssertEqual(displayedDots.compactMap(\.taskID), [items[1].id, items[2].id, items[0].id], "松手后界面也应更新顺序")
        let nextDot = try XCTUnwrap(displayedDots.first)
        let nextStart = nextDot.convert(NSPoint(x: nextDot.bounds.midX, y: nextDot.bounds.midY), to: nil)
        func nextMouse(_ type: NSEvent.EventType, _ delta: CGFloat = 0) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: nextStart.x, y: nextStart.y - delta), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        window.sendEvent(try nextMouse(.leftMouseDown))
        try await Task.sleep(for: .milliseconds(100))
        window.sendEvent(try nextMouse(.leftMouseDragged, 1000))
        XCTAssertTrue(nextDot.isReordering)
        window.sendEvent(try nextMouse(.leftMouseUp, 1000))
        XCTAssertEqual(store.tasks().sorted(by: TaskTimelineSection.precedes).map(\.id), [items[2].id, items[0].id, items[1].id])
    }

    func testFinishedRunsExpandAndCollapseInPlaceWithinTheirDay() {
        let day = Date()
        func task(_ title: String, completed: Bool = false, dropped: Bool = false) -> ScheduledTask {
            var todo = Todo(title: title)
            todo.completed = completed
            todo.dropped = dropped
            return ScheduledTask(date: day, task: todo)
        }
        let tasks = [task("completed", completed: true), task("dropped", completed: true, dropped: true),
                     task("open"), task("later completed", completed: true), task("later open")]
        // 已放弃的事项收进末尾固定的一组，已完成的仍在原位折叠。
        let folded = TaskTimelineItem.items(for: tasks)
        XCTAssertEqual(folded.map(\.folded), [true, false, true, false, true])
        XCTAssertEqual(folded[0].tasks.map(\.id), [tasks[0].id])
        XCTAssertEqual(folded.last?.tasks.map(\.id), [tasks[1].id])
        XCTAssertTrue(folded.last?.droppedGroup == true)
        XCTAssertEqual(folded.flatMap(\.tasks).map(\.id), [0, 2, 3, 4, 1].map { tasks[$0].id })
        let revealed = TaskTimelineItem.items(for: tasks, expanded: [tasks[0].id])
        XCTAssertEqual(revealed.map(\.folded), [false, false, true, false, true])
        XCTAssertTrue(revealed[0].expandedFinished)
        XCTAssertTrue(TaskTimelineItem.items(for: tasks, expanded: Set(tasks.map(\.id))).allSatisfy { !$0.folded })
        let collapsed = TaskTimelineItem.items(for: tasks, expanded: Set(tasks.map(\.id)).subtracting([tasks[0].id]))
        XCTAssertTrue(collapsed[0].folded)
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

    private let calendar = JournalDates.calendar
    private var today: Date { JournalDates.date(for: "2026-10-20")! }
    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
    private func scheduled(_ title: String, offset: Int?, completed: Bool = false) -> ScheduledTask {
        var task = Todo(title: title, completed: completed)
        task.dueDate = offset.map(day)
        return ScheduledTask(date: today, task: task)
    }
    private func dates(_ sections: [TaskTimelineSection]) -> [Date] {
        sections.compactMap { if case .day(let date, _) = $0 { return date }; return nil }
    }

    func testEmptyTimelineAlwaysIncludesTodayAndTomorrow() {
        let sections = TaskTimelineSection.sections(for: [], today: today)
        XCTAssertEqual(dates(sections), (0...1).map(day))
        XCTAssertEqual(sections.count, 5, "Two days plus two open gaps and the undated section")
        XCTAssertTrue(sections.allSatisfy { $0.tasks.isEmpty })
    }

    func testOnlyTaskDatesAndNearTermDatesHaveTicksAndDistantGapsStayCompact() {
        let tasks = [scheduled("late", offset: 20), scheduled("early", offset: -5),
                     scheduled("next day", offset: 21), scheduled("no date", offset: nil)]
        let sections = TaskTimelineSection.sections(for: tasks, today: today)
        XCTAssertEqual(dates(sections), [-5, 0, 1, 20, 21].map(day))
        XCTAssertEqual(sections.compactMap { section -> [Int]? in
            if case .gap(let a?, let b?) = section { return [calendar.dateComponents([.day], from: today, to: a).day!, calendar.dateComponents([.day], from: today, to: b).day!] }
            return nil
        }, [[-5, 0], [1, 20]])
        XCTAssertEqual(sections.flatMap(\.tasks).map(\.id), [tasks[1].id, tasks[0].id, tasks[2].id, tasks[3].id])
        let distant = TaskTimelineSection.sections(for: [scheduled("far future", offset: 30_000)], today: today)
        XCTAssertEqual(dates(distant), [0, 1, 30_000].map(day), "A huge empty gap must not create empty ticks")
        guard case .undated(let undated) = sections.last else { return XCTFail("Undated tasks must remain at the finite tail") }
        XCTAssertEqual(undated.map(\.id), [tasks[3].id])
    }

    func testDateWindowsRecalculateAfterMovesAndRemovalAndIgnoreManualOrder() {
        let first = scheduled("near", offset: 0)
        var last = scheduled("later", offset: 8)
        var lastTodo = last.task
        lastTodo.priority = .urgent
        lastTodo.listPosition = -100
        last = ScheduledTask(date: last.date, task: lastTodo)
        let sections = TaskTimelineSection.sections(for: [last, first], today: today)
        XCTAssertEqual(sections.flatMap(\.tasks).map(\.id), [first.id, last.id])
        XCTAssertTrue(dates(sections).contains(day(8)))
        XCTAssertFalse(dates(sections).contains(day(9)))
        let removed = TaskTimelineSection.sections(for: [first], today: today)
        XCTAssertEqual(dates(removed), [0, 1].map(day))
        lastTodo.dueDate = day(2)
        last = ScheduledTask(date: last.date, task: lastTodo)
        let moved = TaskTimelineSection.sections(for: [last, first], today: today)
        XCTAssertFalse(dates(moved).contains(day(8)))
        XCTAssertEqual(moved.flatMap(\.tasks).map(\.id), [first.id, last.id])
    }

    func testEmptyDatesOutsideTheNearTermWindowDoNotCreateTicks() {
        let sections = TaskTimelineSection.sections(for: [], today: today)
        XCTAssertFalse(dates(sections).contains(day(90)))
        XCTAssertEqual(dates(sections), (0...1).map(day))
        XCTAssertEqual(TaskTimelineSection.navigationID(for: day(90), in: sections), sections[3].id)
        XCTAssertEqual(TaskTimelineSection.navigationID(for: day(-90), in: sections), sections[0].id)
        XCTAssertEqual(TaskTimelineSection.navigationID(for: day(1), in: sections), TaskTimelineSection.dayID(day(1)))
    }

    func testFinishedRunsNeverFoldAcrossDates() {
        let tasks = [scheduled("one", offset: 0, completed: true), scheduled("two", offset: 1, completed: true),
                     scheduled("undated", offset: nil, completed: true)]
        XCTAssertEqual(TaskTimelineItem.items(for: tasks).count, 3)
    }

    func testSparseHistoryPreservesRecordsWithoutFillingEmptyDays() {
        let offsets = [-1000, -400, -20, -5]
        let finished = offsets.map { scheduled("Finished", offset: $0, completed: true) }
        let overdue = scheduled("Still open", offset: -12)
        let sections = TaskTimelineSection.sections(for: finished + [overdue], today: today)
        XCTAssertEqual(dates(sections), [-12, 0, 1].map(day))
        XCTAssertEqual(sections.flatMap(\.tasks).count, finished.count + 1)
        XCTAssertEqual(Set(sections.flatMap(\.tasks).map(\.id)), Set((finished + [overdue]).map(\.id)))
    }

    func testFinishedOnlyDatesMergeAcrossGapsButStopAtOpenTasksAndNearTermDates() {
        let finished = [-30, -20, -8, -3, 0, 1, 10, 18].map { scheduled("Finished", offset: $0, completed: true) }
        let open = scheduled("Unfinished", offset: -12)
        let undated = scheduled("Undated", offset: nil, completed: true)
        let sections = TaskTimelineSection.sections(for: finished + [open, undated], today: today)
        let runs = sections.compactMap { section -> [Date]? in
            if case .finished(let dates, _) = section { return dates }; return nil
        }
        XCTAssertEqual(runs, [[-30, -20], [-8, -3], [10, 18]].map { $0.map(day) })
        XCTAssertEqual(dates(sections), [-12, 0, 1].map(day))
        XCTAssertEqual(sections.flatMap(\.tasks).count, finished.count + 2)
        XCTAssertEqual(Set(sections.map(\.id)).count, sections.count)
        let group = sections.first { if case .finished = $0 { return true }; return false }!
        XCTAssertTrue(group.visibleTasks(expanded: []).isEmpty)
        XCTAssertEqual(group.visibleTasks(expanded: [finished[1].id]).map(\.id), [finished[0].id, finished[1].id])
        XCTAssertEqual(TaskTimelineSection.navigationID(for: day(-25), in: sections), group.id)
        guard case .undated(let tail) = sections.last else { return XCTFail("No Due must remain separate") }
        XCTAssertEqual(tail.map(\.id), [undated.id])
    }

    func testMergedFinishedDatesExpandWithoutMovingTheirToggleAndCollapseToOneRow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let tasks = [-30, -20, -8].map { scheduled("Finished", offset: $0, completed: true) }
        func height(expanded: Set<UUID>) -> CGFloat {
            let host = NSHostingView(rootView: FinishedTimelineDatesView(store: store, dates: [-30, -20, -8].map(day),
                tasks: tasks, selectedDate: today, expanded: .constant(expanded), requestedEdit: .constant(nil),
                navigate: { _ in }, selectTask: {}, next: {}).frame(width: 520)
                .environmentObject(WorkspaceInteraction()))
            return host.fittingSize.height
        }
        XCTAssertEqual(height(expanded: []), 44, accuracy: 1)
        XCTAssertGreaterThan(height(expanded: [tasks[0].id]), height(expanded: []) + 120)
        XCTAssertEqual(height(expanded: Set(tasks.map(\.id))), height(expanded: [tasks[0].id]), accuracy: 1)
    }

    func testDateAndNoDueDotsReorderPersistentlyWithoutChangingDeadlines() async throws {
        for due in [today, nil] as [Date?] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = JournalStore(directory: directory)
            let items = try ["First", "Second", "Third"].map { try XCTUnwrap(store.addParsedTodo($0, on: today)) }
            if let due { for item in items { store.setDeadline(item.id, to: due) } }
            let otherDay = try XCTUnwrap(JournalDates.calendar.date(byAdding: .day, value: 1, to: today))
            let outsiders = try ["Other date first", "Other date second"].map { try XCTUnwrap(store.addParsedTodo($0, on: today)) }
            for item in outsiders { store.setDeadline(item.id, to: otherDay) }
            let originals = store.tasks()
            let host = NSHostingView(rootView: ScrollView {
                TaskTimelineView(store: store, tasks: store.tasks(), today: today, selectedDate: today,
                    expanded: .constant([]), requestedEdit: .constant(nil), navigate: { _ in })
            }.frame(width: 520, height: 700).environmentObject(WorkspaceInteraction()))
            let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            func handles(_ view: NSView) -> [TaskHandleView] {
                (view as? TaskHandleView).map { [$0] } ?? view.subviews.flatMap(handles)
            }
            let dot = try XCTUnwrap(handles(host).first { $0.taskID == items[0].id })
            XCTAssertNotNil(dot.reorder)
            let start = dot.convert(NSPoint(x: dot.bounds.midX, y: dot.bounds.midY), to: nil)
            let hit = try XCTUnwrap(host.hitTest(host.superview?.convert(start, from: nil) ?? start))
            XCTAssertTrue(hit === dot, "圆点必须实际收到鼠标事件，当前命中：\(type(of: hit))")
            let outside = NSPoint(x: start.x, y: start.y - 10_000)
            func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            window.sendEvent(try mouse(.leftMouseDown, at: start))
            window.sendEvent(try mouse(.leftMouseDragged, at: outside))
            XCTAssertTrue(dot.isReordering, "Actual priority dot must stay in its date interval even outside the timeline")
            window.sendEvent(try mouse(.leftMouseUp, at: outside))
            let saved = JournalStore(directory: directory).tasks().sorted(by: TaskTimelineSection.precedes)
            let ownGroup = saved.filter { item in items.contains { $0.id == item.id } }
            XCTAssertEqual(ownGroup.map(\.id), [items[1].id, items[2].id, items[0].id])
            XCTAssertTrue(ownGroup.allSatisfy { $0.task.dueDate == due })
            XCTAssertEqual(saved.filter { $0.task.dueDate == otherDay }.map(\.id), outsiders.map(\.id))
            for outsider in outsiders {
                XCTAssertEqual(saved.first { $0.id == outsider.id }?.task, originals.first { $0.id == outsider.id }?.task)
            }
            store.undo()
            XCTAssertEqual(store.tasks().sorted(by: TaskTimelineSection.precedes).map(\.id), originals.sorted(by: TaskTimelineSection.precedes).map(\.id))
        }
    }

    func testScrollingHasAFiniteTailWithVisibleUndatedTask() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let tasks = [scheduled("Old record", offset: -10_000, completed: true),
                     scheduled("Distant plan", offset: 10_000), scheduled("Undated observation", offset: nil)]
        let content = GeometryReader { geometry in
            ScrollView {
                TaskTimelineView(store: store, tasks: tasks, today: self.today, selectedDate: self.today,
                    expanded: .constant([]), requestedEdit: .constant(nil), navigate: { _ in })
                    .padding(.vertical, 12)
            }
        }.frame(width: 520, height: 300).environmentObject(WorkspaceInteraction())
        let host = NSHostingView(rootView: content)
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
        }
        let scroll = try XCTUnwrap(descendants(host, of: NSScrollView.self).first)
        let document = try XCTUnwrap(scroll.documentView)
        let height = document.frame.height
        XCTAssertLessThan(height, 800, "Large date spans must remain compact")
        for _ in 0..<5 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(30))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(document.frame.height, height, accuracy: 1, "Reaching the tail must not add more dates")
        let undated = try XCTUnwrap(descendants(host, of: InteractiveTaskText.self).first { $0.string.contains("Undated observation") })
        XCTAssertTrue(scroll.contentView.bounds.intersects(undated.convert(undated.bounds, to: document)), "Undated task must be reachable at the finite tail")
    }

    func testAxisIsIndependentOfTheTaskNodesAndFillsItsContainerHeight() {
        for height in [34.0, 120.0, 800.0] {
            let path = TaskTimelineAxis(x: 79).path(in: CGRect(x: 0, y: 0, width: 480, height: height))
            XCTAssertEqual(path.boundingRect.minY, 0)
            XCTAssertEqual(path.boundingRect.maxY, height)
            XCTAssertEqual(path.boundingRect.minX, 79)
            XCTAssertEqual(path.boundingRect.maxX, 79)
        }
    }

    func testDayHeightGrowsWithTasksAndShrinksWhenFinishedTasksCollapse() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let a = scheduled("A task", offset: 0)
        let b = scheduled("Another task", offset: 0)
        let finished = (0..<8).map { scheduled("Finished \($0)", offset: 0, completed: true) }
        func height(_ tasks: [ScheduledTask], expanded: Set<UUID> = []) -> CGFloat {
            let host = NSHostingView(rootView: TimelineDayView(store: store, date: today, tasks: tasks, selectedDate: today,
                expanded: .constant(expanded), requestedEdit: .constant(nil), navigate: { _ in }, selectTask: {}, next: {})
                .frame(width: 480).environmentObject(WorkspaceInteraction()))
            return host.fittingSize.height
        }
        let empty = height([])
        XCTAssertLessThanOrEqual(empty, 36)
        XCTAssertGreaterThan(height([a, b]), height([a]) + 20)
        XCTAssertGreaterThan(height(finished, expanded: Set(finished.map(\.id))), height(finished) + 100)
        XCTAssertLessThan(height(finished), height([a]))
    }

    func testTimelineViewportRendersFlatRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let item = try XCTUnwrap(store.addParsedTodo("Read the paper and write observations", on: today))
        store.setDeadline(item.id, to: today)
        let second = try XCTUnwrap(store.addParsedTodo("Prepare experiment", on: today))
        store.setDeadline(second.id, to: day(2))
        let third = try XCTUnwrap(store.addParsedTodo("Review previous results", on: today))
        store.setDeadline(third.id, to: day(-2))
        let content = ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    TaskTimelineView(store: store, tasks: store.tasks(), today: self.today, selectedDate: self.today,
                        expanded: .constant([]), requestedEdit: .constant(nil), navigate: { _ in })
                        .padding(.vertical, 12).padding(.horizontal, 16)
                }.onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo(TaskTimelineSection.dayID(self.today), anchor: .center)
                    }
                }
            }
        }.frame(width: 520, height: 540).background(Palette.background).environmentObject(WorkspaceInteraction())
        let host = NSHostingView(rootView: content)
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 540), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        if let prefix = ProcessInfo.processInfo.environment["TIMELINE_AXIS_SNAPSHOT"] {
            func snapshot(_ suffix: String) throws {
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: prefix + suffix + ".png"))
            }
            try snapshot("-viewport")
        }
        XCTAssertEqual(host.bounds.size, CGSize(width: 520, height: 540))
    }

    func testFullAxisAndPaletteRenderAtLargeTypeSizes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let tasks = [scheduled("Archived observation", offset: -20, completed: true),
                     scheduled("Archived experiment", offset: -10, completed: true),
                     scheduled("Review the paper #reading", offset: 0), scheduled("Write observations", offset: 0),
                     scheduled("Finished review", offset: 0, completed: true), scheduled("Prepare experiment", offset: 2),
                     scheduled("Submit report", offset: 15), scheduled("Collect references", offset: nil)]
        for scale in [1.0, 1.2] {
            let content = TaskTimelineView(store: store, tasks: tasks, today: today, selectedDate: today,
                expanded: .constant([]), requestedEdit: .constant(nil), navigate: { _ in })
                .padding(16).frame(width: 520).background(Palette.background)
                .environmentObject(WorkspaceInteraction()).environment(\.typography, AppTypography(scale: scale))
            let host = NSHostingView(rootView: content)
            let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, 520, accuracy: 1)
            XCTAssertLessThan(host.fittingSize.height, 2200)
            if let prefix = ProcessInfo.processInfo.environment["TIMELINE_AXIS_SNAPSHOT"],
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: prefix + "-\(Int(scale * 100)).png"))
            }
        }
        let items = TaskPriorityButton(store: store, task: tasks[0].task).items
        let host = NSHostingView(rootView: PriorityPaletteView(items: items))
        XCTAssertLessThanOrEqual(host.fittingSize.width, 310)
        XCTAssertGreaterThan(host.fittingSize.height, 70)
        if let prefix = ProcessInfo.processInfo.environment["TIMELINE_AXIS_SNAPSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: prefix + "-palette.png"))
        }
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
                                   timeline: true)
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
            for handle in handles(host) {
                let frame = handle.convert(handle.bounds, to: host)
                XCTAssertEqual(frame.midX, 16 + TaskTimelineLayout.axisX(AppTypography(scale: scale)), accuracy: 0.5,
                               "Task dots must sit on the independently drawn timeline axis")
            }
            for title in titles(host) { XCTAssertGreaterThan(title.bounds.width, 90) }
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
                                     timeline: true)
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
                           timeline: true)
                .frame(width: 360).environmentObject(WorkspaceInteraction()))
        XCTAssertGreaterThan(host.fittingSize.height, 40)
    }
}

private struct LiveTaskTimeline: View {
    @ObservedObject var store: JournalStore
    let today: Date

    var body: some View {
        ScrollView {
            TaskTimelineView(store: store, tasks: store.tasks(), today: today, selectedDate: today,
                expanded: .constant([]), requestedEdit: .constant(nil), navigate: { _ in })
        }
        .frame(width: 520, height: 700)
        .environmentObject(WorkspaceInteraction())
    }
}
