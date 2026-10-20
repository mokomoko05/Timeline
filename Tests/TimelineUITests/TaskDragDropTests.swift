import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

final class TaskDragDropTests: XCTestCase {
    @MainActor
    func testDraftDotCreatesOnceOnPressAndDragsTheCreatedTaskWithoutASecondSubmission() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); PriorityPaletteController.shared.dismiss() }
        let store = JournalStore(directory: directory)
        let source = try XCTUnwrap(JournalDates.date(for: "2026-10-20"))
        let target = try XCTUnwrap(JournalDates.date(for: "2026-10-24"))
        store.setDeadlineDraft("Write report #work", on: source)
        var options = TaskCreationOptions()
        options.priority = .high
        let dot = TaskHandleView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        dot.draftEnabled = true
        var submissions = 0
        dot.prepareTask = {
            submissions += 1
            return store.commitDraft(on: source, options: options).last?.task
        }
        dot.priorityItems = [RadialItem(id: "high", symbol: "circle.fill", title: "High", action: {})]
        func event(_ type: NSEvent.EventType, x: CGFloat = 10) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 10), modifierFlags: [], timestamp: 0,
                              windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        dot.rightMouseDown(with: event(.rightMouseDown))
        XCTAssertEqual(submissions, 0, "Choosing a color must not create a task")
        dot.mouseDown(with: event(.leftMouseDown))
        let created = try XCTUnwrap(store.tasks().first)
        XCTAssertEqual(created.id, dot.taskID)
        XCTAssertEqual(created.task.priority, .high)
        XCTAssertEqual(created.task.tags, ["work"])
        XCTAssertEqual(store.entry(for: source).deadlineDraft, "")
        var dragged: UUID?
        dot.startNativeDrag = { id, title, _, _ in
            dragged = id
            XCTAssertEqual(title, created.task.title)
            TaskDragSession.shared.begin(id)
            XCTAssertTrue(TaskDragDrop.receive([TaskDragPayload.provider(id)], store: store, destination: target))
        }
        dot.mouseDragged(with: event(.leftMouseDragged, x: 30))
        dot.mouseDragged(with: event(.leftMouseDragged, x: 40))
        dot.mouseUp(with: event(.leftMouseUp, x: 40))
        XCTAssertEqual(dragged, created.id)
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(store.tasks().count, 1)
        XCTAssertEqual(store.locate(created.id)?.task.dueDate, target)
        dot.mouseDown(with: event(.leftMouseDown))
        XCTAssertNil(dot.taskID, "Pressing an empty draft cannot pick up the previous task")
        XCTAssertEqual(store.tasks().count, 1)
    }

    @MainActor
    func testCardDragSurfacePassesThroughButtonAndEditorRegions() async {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let surface = TaskHandleView(frame: NSRect(x: 20, y: 30, width: 300, height: 110))
        surface.taskID = UUID()
        surface.edgeOnly = true
        surface.drawsHandle = false
        container.addSubview(surface)
        XCTAssertNil(surface.hitTest(NSPoint(x: 70, y: 85)))
        XCTAssertNil(surface.hitTest(NSPoint(x: 230, y: 55)))
        XCTAssertTrue(surface.hitTest(NSPoint(x: 22, y: 85)) === surface)
        XCTAssertTrue(surface.hitTest(NSPoint(x: 80, y: 32)) === surface)
        surface.taskID = nil
        XCTAssertNil(surface.hitTest(NSPoint(x: 22, y: 85)))
    }

    @MainActor
    func testLocalDropPlacesImmediatelyWithoutLoadingProviderOrWaitingForDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); TaskDragSession.shared.end() }
        let store = JournalStore(directory: directory)
        let day = try XCTUnwrap(JournalDates.date(for: "2026-10-07"))
        store.addTodo("首项", on: day)
        store.addTodo("次项", on: day)
        let tasks = store.entry(for: day).todos
        let savedAt = store.lastSaved
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: TaskDragPayload.type.identifier, visibility: .ownProcess) { _ in
            XCTFail("Local drops must not load an asynchronous representation")
            return nil
        }
        // 把任务拖到日历某一天：立刻把那天设为截止日期，不等待异步载荷，也不等磁盘。
        let target = try XCTUnwrap(JournalDates.date(for: "2026-10-12"))
        TaskDragSession.shared.begin(tasks[1].id)
        XCTAssertTrue(TaskDragDrop.receive([provider], store: store, destination: target))
        XCTAssertEqual(store.locate(tasks[1].id)?.task.dueDate, target)
        XCTAssertNil(store.locate(tasks[0].id)?.task.dueDate)
        XCTAssertNil(TaskDragSession.shared.activeID)
        XCTAssertEqual(store.sortedTasks().map(\.id), [tasks[1].id, tasks[0].id], "有截止日期的排在前面")
        XCTAssertNotEqual(store.lastSaved, nil)
        XCTAssertEqual(JournalStore(directory: directory).locate(tasks[1].id)?.task.dueDate, target)
        _ = savedAt
        let beforeCancel = store.days
        TaskDragSession.shared.begin(tasks[0].id)
        TaskDragSession.shared.end()
        XCTAssertNil(TaskDragSession.shared.activeID)
        XCTAssertEqual(store.days, beforeCancel)
    }

    @MainActor
    func testAxisDropMovesCalendarEntryKeepsTimeAndCanClearDeadline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); TaskDragSession.shared.end() }
        let store = JournalStore(directory: directory)
        let source = try XCTUnwrap(JournalDates.date(for: "2026-10-20"))
        let destination = try XCTUnwrap(JournalDates.date(for: "2026-10-23"))
        let item = try XCTUnwrap(store.addParsedTodo("Write report", on: source))
        let due = try XCTUnwrap(JournalDates.calendar.date(bySettingHour: 14, minute: 30, second: 0, of: source))
        store.updateTodo(item.id, scheduledDate: item.date, dueDate: due, dueHasTime: true, reminderMinutes: 15, repeatRule: .none)
        _ = store.calendarDeadlines // Populate the index before moving.
        TaskDragSession.shared.begin(item.id)
        XCTAssertTrue(TaskDragDrop.receive([TaskDragPayload.provider(item.id)], store: store, destination: destination))
        let moved = try XCTUnwrap(store.locate(item.id))
        XCTAssertEqual(JournalDates.calendar.component(.hour, from: moved.task.dueDate!), 14)
        XCTAssertEqual(JournalDates.calendar.component(.minute, from: moved.task.dueDate!), 30)
        XCTAssertTrue(store.calendarDeadlines[JournalDates.key(source), default: []].isEmpty)
        XCTAssertEqual(store.calendarDeadlines[JournalDates.key(destination)]?.map(\.id), [item.id])
        TaskDragSession.shared.begin(item.id)
        XCTAssertTrue(TaskDragDrop.receive([TaskDragPayload.provider(item.id)], store: store, destination: nil))
        XCTAssertNil(store.locate(item.id)?.task.dueDate)
        XCTAssertTrue(store.calendarDeadlines[JournalDates.key(destination), default: []].isEmpty)
        store.undo()
        XCTAssertEqual(store.calendarDeadlines[JournalDates.key(destination)]?.map(\.id), [item.id])
    }

    @MainActor
    func testDotHoverDoesNothingLeftDragMovesAndRightClickOpensPalette() async throws {
        let dot = TaskHandleView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        dot.taskID = UUID()
        dot.priorityColor = .systemBlue
        dot.priorityItems = TaskPriority.allCases.map { priority in
            RadialItem(id: priority.rawValue, symbol: "circle.fill", title: priority.title,
                       active: priority == .normal, tint: PriorityMark(priority: priority).color, action: {})
        }
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = dot
        window.orderFront(nil)
        defer { PriorityPaletteController.shared.dismiss(); window.contentView = nil; window.close() }
        func event(_ type: NSEvent.EventType, x: CGFloat = 10) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 10), modifierFlags: [], timestamp: 0,
                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        dot.mouseEntered(with: event(.leftMouseDown))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(PriorityPaletteController.shared.isOpen)
        XCTAssertFalse(RadialMenuController.shared.isOpen)
        dot.rightMouseDown(with: event(.rightMouseDown))
        XCTAssertTrue(PriorityPaletteController.shared.isOpen)
        XCTAssertFalse(RadialMenuController.shared.isOpen)
        if let prefix = ProcessInfo.processInfo.environment["TIMELINE_AXIS_SNAPSHOT"],
           let view = PriorityPaletteController.shared.popover?.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: prefix + "-palette.png"))
            }
        }
        var dragged: UUID?
        dot.startNativeDrag = { id, _, _, _ in dragged = id }
        dot.mouseDown(with: event(.leftMouseDown))
        XCTAssertFalse(PriorityPaletteController.shared.isOpen)
        dot.mouseDragged(with: event(.leftMouseDragged, x: 30))
        XCTAssertEqual(dragged, dot.taskID)
        dot.mouseUp(with: event(.leftMouseUp, x: 30))
    }

    @MainActor
    func testDragPayloadUsesPrivateTypeAndRejectsPlainText() async throws {
        let id = UUID()
        let provider = TaskDragPayload.provider(id)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(TaskDragPayload.type.identifier))
        XCTAssertFalse(provider.hasItemConformingToTypeIdentifier("public.utf8-plain-text"))
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: TaskDragPayload.type.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile)) }
            }
        }
        XCTAssertEqual(TaskDragPayload.decode(data), id)
        XCTAssertNil(TaskDragPayload.decode(Data("not a task".utf8)))
        XCTAssertNil(TaskDragPayload.decode(Data((id.uuidString + "extra").utf8)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        XCTAssertFalse(TaskDragDrop.receive([NSItemProvider(object: id.uuidString as NSString)], store: store, destination: Date()))
    }

    @MainActor
    func testDropCommitsEditsBeforeMovingAndDoesNotResurrectDeletedTasks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let source = try XCTUnwrap(JournalDates.date(for: "2026-10-07"))
        let destination = try XCTUnwrap(JournalDates.date(for: "2026-10-08"))
        store.addTodo("原正文", on: source)
        let task = try XCTUnwrap(store.entry(for: source).todos.first)
        let taskID = task.id
        let observer = NotificationCenter.default.addObserver(forName: .timelineCommitEditing, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                store.renameTodo(taskID, title: "编辑后正文", on: source)
                store.renameCalendarName(taskID, name: "短标题", on: source)
            }
        }
        TaskDragDrop.move(task.id, store: store, destination: destination)
        NotificationCenter.default.removeObserver(observer)
        XCTAssertEqual(store.locate(task.id)?.task.dueDate, destination, "拖到哪天，哪天就是截止日期")
        XCTAssertEqual(store.locate(task.id)?.task.title, "编辑后正文")
        XCTAssertEqual(store.locate(task.id)?.task.calendarName, "短标题")
        XCTAssertEqual(store.locate(task.id)?.task.number, 1, "编号不变")
        store.undo()
        XCTAssertNil(store.locate(task.id)?.task.dueDate)
        store.redo()
        XCTAssertEqual(store.locate(task.id)?.task.dueDate, destination)
        store.deleteTodo(task.id, on: source)
        TaskDragDrop.move(task.id, store: store, destination: source)
        XCTAssertNil(store.locate(task.id))
    }

    @MainActor
    func testDraggingLinkTextDoesNotOpenTheLink() async throws {
        let view = InteractiveTaskText(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        view.textStorage?.setAttributedString(TaskLinkText.styledText("[链接](https://example.com)", completed: false, color: .labelColor, fontSize: 13))
        view.dragTaskID = UUID()
        let region = try XCTUnwrap(view.linkRegions().first)
        let point = view.convert(NSPoint(x: region.rect.midX, y: region.rect.midY), to: nil)
        var opened = 0
        var edited = 0
        view.onOpen = { _ in opened += 1 }
        view.onEdit = { edited += 1 }
        func event(_ type: NSEvent.EventType, at location: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        }
        view.mouseDown(with: try event(.leftMouseDown, at: point))
        XCTAssertEqual(opened, 0)
        view.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: point.x + 20, y: point.y)))
        view.mouseUp(with: try event(.leftMouseUp, at: point))
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(edited, 0)
        view.mouseDown(with: try event(.leftMouseDown, at: point))
        view.mouseUp(with: try event(.leftMouseUp, at: point))
        XCTAssertEqual(opened, 1)
    }
}
