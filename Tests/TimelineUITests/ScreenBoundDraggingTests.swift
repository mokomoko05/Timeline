import AppKit
import XCTest
@testable import Timeline

@MainActor
final class ScreenBoundDraggingTests: XCTestCase {
    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point),
                                        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func testWindowsAndPanelsStayInsideAllScreenEdgesWhileDragging() throws {
        _ = Headless.active
        let area = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let windows: [NSWindow] = [
            QuietWindow(contentRect: NSRect(x: area.midX, y: area.midY, width: 240, height: 160),
                        styleMask: [.borderless], backing: .buffered, defer: false),
            QuietPanel(contentRect: NSRect(x: area.midX, y: area.midY, width: 240, height: 160),
                       styleMask: [.borderless], backing: .buffered, defer: false),
            MainWindow(contentRect: NSRect(x: area.midX, y: area.midY, width: 240, height: 160),
                       styleMask: [.titled], backing: .buffered, defer: false)
        ]
        for window in windows {
            window.isReleasedWhenClosed = false
            defer { window.close() }
            (window as? MainWindow)?.keepsCentered = false
            window.isMovable = true
            window.contentView = DraggableBackground(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
            for target in [NSPoint(x: area.minX - 500, y: area.midY), NSPoint(x: area.maxX + 500, y: area.midY),
                           NSPoint(x: area.midX, y: area.minY - 500), NSPoint(x: area.midX, y: area.maxY + 500)] {
                window.setFrameOrigin(NSPoint(x: area.midX - 120, y: area.midY - 80))
                let start = NSPoint(x: window.frame.midX, y: window.frame.midY)
                window.sendEvent(try mouse(.leftMouseDown, at: start, in: window))
                window.sendEvent(try mouse(.leftMouseDragged, at: target, in: window))
                XCTAssertTrue(area.contains(window.frame), "\(type(of: window)): \(window.frame)")
                XCTAssertNotEqual(window.frame.origin, NSPoint(x: area.midX - 120, y: area.midY - 80))
                window.sendEvent(try mouse(.leftMouseUp, at: target, in: window))
            }
        }
    }

    func testTitlebarDraggingIsConstrainedAndImmovableWindowsStayPut() throws {
        _ = Headless.active
        let area = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let window = QuietWindow(contentRect: NSRect(x: area.midX - 120, y: area.midY, width: 240, height: 160),
                                 styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let dragging = ScreenBoundDragging()
        let resizePoint = NSPoint(x: window.frame.maxX - 1, y: window.frame.midY)
        XCTAssertNotNil(dragging.filter(try mouse(.leftMouseDown, at: resizePoint, in: window), in: window))
        let start = NSPoint(x: window.frame.midX, y: window.frame.maxY - 10)
        XCTAssertNil(dragging.filter(try mouse(.leftMouseDown, at: start, in: window), in: window))
        let target = NSPoint(x: area.maxX + 300, y: area.minY - 300)
        XCTAssertNil(dragging.filter(try mouse(.leftMouseDragged, at: target, in: window), in: window))
        XCTAssertTrue(area.contains(window.frame))
        _ = dragging.filter(try mouse(.leftMouseUp, at: target, in: window), in: window)
        window.isMovable = false
        let before = window.frame
        _ = dragging.filter(try mouse(.leftMouseDown, at: start, in: window), in: window)
        _ = dragging.filter(try mouse(.leftMouseDragged, at: target, in: window), in: window)
        XCTAssertEqual(window.frame, before)
    }

    func testTextSelectionDoesNotStartWindowDragging() throws {
        _ = Headless.active
        let window = QuietWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 160),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        let dragging = ScreenBoundDragging(), before = window.frame
        _ = dragging.filter(try mouse(.leftMouseDown, at: NSPoint(x: 240, y: 240), in: window), in: window)
        XCTAssertNotNil(dragging.filter(try mouse(.leftMouseDragged, at: NSPoint(x: 100, y: 100), in: window), in: window))
        XCTAssertEqual(window.frame, before)
    }
}

private final class DraggableBackground: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {}
}
