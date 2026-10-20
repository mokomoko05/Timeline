import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

final class TaskDragDropTests: XCTestCase {
    @MainActor
    func testDotWithoutReorderDoesNothingOnDragAndRightClickOpensPalette() async throws {
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
        let originalID = dot.taskID
        dot.mouseDown(with: event(.leftMouseDown))
        XCTAssertFalse(PriorityPaletteController.shared.isOpen)
        dot.mouseDragged(with: event(.leftMouseDragged, x: 30))
        XCTAssertEqual(dot.taskID, originalID)
        XCTAssertFalse(dot.isReordering)
        dot.mouseUp(with: event(.leftMouseUp, x: 30))

        // A one-task group rejects reordering and must not fall back to a date drag.
        var begins = 0
        var updates = 0
        var ends = 0
        dot.reorder = TaskReorderHooks(begin: { begins += 1; return false },
            update: { _ in updates += 1 }, end: { ends += 1 }, cancel: {})
        dot.mouseDown(with: event(.leftMouseDown))
        dot.mouseDragged(with: event(.leftMouseDragged, x: 500))
        XCTAssertFalse(dot.isReordering)
        XCTAssertFalse(dot.isPressed)
        dot.mouseUp(with: event(.leftMouseUp, x: 500))
        XCTAssertEqual(begins, 1)
        XCTAssertEqual(updates, 0)
        XCTAssertEqual(ends, 0)
        XCTAssertEqual(dot.taskID, originalID)
    }

    @MainActor
    func testDraggingLinkTextDoesNotOpenTheLink() async throws {
        let view = InteractiveTaskText(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        view.textStorage?.setAttributedString(TaskLinkText.styledText("[链接](https://example.com)", completed: false, color: .labelColor, fontSize: 13))
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
