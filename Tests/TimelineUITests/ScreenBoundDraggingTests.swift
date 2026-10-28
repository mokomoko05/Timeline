import AppKit
import SwiftUI
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

    func testFullSizeTitlebarDoesNotSwallowSwiftUICloseButton() throws {
        _ = Headless.active
        let window = QuietPanel(contentRect: NSRect(x: 200, y: 200, width: 410, height: 560),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        let host = NSHostingView(rootView: VStack {
            HStack { Spacer(); Button("X") {}.buttonStyle(.plain).frame(width: 30, height: 24) }
            Spacer()
        }.padding(6).frame(width: 410, height: 560))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let point = NSPoint(x: window.frame.maxX - 21, y: window.frame.maxY - 18)
        let event = try mouse(.leftMouseDown, at: point, in: window)
        let dragging = ScreenBoundDragging()
        XCTAssertNotNil(dragging.filter(event, in: window), "SwiftUI 标题栏按钮必须收到原始按下事件")
        XCTAssertNotNil(dragging.filter(try mouse(.leftMouseUp, at: point, in: window), in: window))
    }

    func testQueuedDragEventsKeepTheirOriginalScreenPosition() throws {
        _ = Headless.active
        let window = QuietWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 160),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let start = NSPoint(x: window.frame.midX, y: window.frame.maxY - 10)
        let first = try mouse(.leftMouseDragged, at: NSPoint(x: start.x + 20, y: start.y), in: window)
        let second = try mouse(.leftMouseDragged, at: NSPoint(x: start.x + 40, y: start.y), in: window)
        let locations = [ObjectIdentifier(first): NSPoint(x: start.x + 20, y: start.y),
                         ObjectIdentifier(second): NSPoint(x: start.x + 40, y: start.y)]
        let dragging = ScreenBoundDragging(eventScreenLocation: { locations[ObjectIdentifier($0)] ?? start })
        let origin = window.frame.origin
        _ = dragging.filter(try mouse(.leftMouseDown, at: start, in: window), in: window)
        _ = dragging.filter(first, in: window)
        XCTAssertEqual(window.frame.origin.x, origin.x + 20, accuracy: 0.1)
        _ = dragging.filter(second, in: window)
        XCTAssertEqual(window.frame.origin.x, origin.x + 40, accuracy: 0.1,
                       "已经排队的事件不能按移动后的窗口原点再次换算")
    }

    func testContentDragDisablesNativeMovementAndRestoresItAfterForwarding() throws {
        _ = Headless.active
        let window = QuietWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 160),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = DraggableBackground(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        window.isMovableByWindowBackground = true
        let dragging = ScreenBoundDragging()
        let start = NSPoint(x: 250, y: 250)
        var forwarded = 0
        dragging.send(try mouse(.leftMouseDown, at: start, in: window), in: window) { event in
            XCTAssertEqual(event.type, .leftMouseDown)
            XCTAssertFalse(window.isMovable, "转发内容点击时不能同时启动系统窗口拖动")
            forwarded += 1
        }
        XCTAssertTrue(window.isMovable)
        for delta in [20.0, 40, 60, 40, 20, 0, -20, 0] {
            dragging.send(try mouse(.leftMouseDragged, at: NSPoint(x: start.x + delta, y: start.y), in: window), in: window) { _ in
                XCTFail("拖动不能交给第二个处理者")
            }
            XCTAssertEqual(window.frame.origin.x, 200 + delta, accuracy: 0.1)
        }
        dragging.send(try mouse(.leftMouseUp, at: start, in: window), in: window) { event in
            XCTAssertEqual(event.type, .leftMouseUp)
            XCTAssertLessThan(event.locationInWindow.x, 0)
            forwarded += 1
        }
        dragging.send(try mouse(.leftMouseDragged, at: start, in: window), in: window) { _ in forwarded += 1 }
        XCTAssertEqual(forwarded, 3)
        XCTAssertTrue(window.isMovable)
    }

    func testNativeCloseButtonEventsArePassedThrough() throws {
        _ = Headless.active
        let window = QuietWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 160),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let button = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let point = window.convertPoint(toScreen: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
        let dragging = ScreenBoundDragging()
        let before = window.frame
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            XCTAssertNotNil(dragging.filter(try mouse(type, at: point, in: window), in: window))
        }
        XCTAssertEqual(window.frame, before)
    }

    func testForwardedEventsCanChangeWindowMovability() throws {
        _ = Headless.active
        let window = QuietWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 160),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "x",
            charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        ScreenBoundDragging().send(event, in: window) { _ in window.isMovable = false }
        XCTAssertFalse(window.isMovable)
    }
}

private final class DraggableBackground: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {}
}
