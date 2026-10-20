import AppKit
import XCTest
import TimelineCore
@testable import Timeline

final class TaskDragDropTests: XCTestCase {
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
