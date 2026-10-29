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
            window.contentView = DraggableBackground(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
            var pointer = NSPoint.zero
            let dragging = ScreenBoundDragging(mouseLocation: { pointer })
            for target in [NSPoint(x: area.minX - 500, y: area.midY), NSPoint(x: area.maxX + 500, y: area.midY),
                           NSPoint(x: area.midX, y: area.minY - 500), NSPoint(x: area.midX, y: area.maxY + 500)] {
                window.setFrameOrigin(NSPoint(x: area.midX - 120, y: area.midY - 80))
                let start = NSPoint(x: window.frame.midX, y: window.frame.midY)
                pointer = start
                dragging.send(try mouse(.leftMouseDown, at: start, in: window), in: window) { window.sendEvent($0) }
                pointer = target
                dragging.send(try mouse(.leftMouseDragged, at: target, in: window), in: window) { window.sendEvent($0) }
                XCTAssertTrue(area.contains(window.frame), "\(type(of: window)): \(window.frame)")
                XCTAssertNotEqual(window.frame.origin, NSPoint(x: area.midX - 120, y: area.midY - 80))
                dragging.send(try mouse(.leftMouseUp, at: target, in: window), in: window) { window.sendEvent($0) }
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
        var pointer = NSPoint.zero
        let dragging = ScreenBoundDragging(mouseLocation: { pointer })
        let resizePoint = NSPoint(x: window.frame.maxX - 1, y: window.frame.midY)
        XCTAssertNotNil(dragging.filter(try mouse(.leftMouseDown, at: resizePoint, in: window), in: window))
        let start = NSPoint(x: window.frame.midX, y: window.frame.maxY - 10)
        pointer = start
        XCTAssertNil(dragging.filter(try mouse(.leftMouseDown, at: start, in: window), in: window))
        let target = NSPoint(x: area.maxX + 300, y: area.minY - 300)
        pointer = target
        XCTAssertNil(dragging.filter(try mouse(.leftMouseDragged, at: target, in: window), in: window))
        XCTAssertTrue(area.contains(window.frame))
        _ = dragging.filter(try mouse(.leftMouseUp, at: target, in: window), in: window)
        window.allowsScreenBoundDragging = false
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

    func testQueuedAppKitDragLocationsFollowLivePointerWithoutAddingWindowMovement() throws {
        _ = Headless.active
        let window = QuietPanel(contentRect: NSRect(x: 200, y: 200, width: 410, height: 560),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let start = NSPoint(x: window.frame.midX, y: window.frame.maxY - 10)
        let down = try mouse(.leftMouseDown, at: start, in: window)
        let targets = [20.0, 40, 60, 80].map { NSPoint(x: start.x + $0, y: start.y) }
        let events = try targets.map { try mouse(.leftMouseDragged, at: $0, in: window) }
        var pointer = start
        let dragging = ScreenBoundDragging(mouseLocation: { pointer })
        let origin = window.frame.origin
        _ = dragging.filter(down, in: window)
        for (event, target) in zip(events, targets) {
            pointer = target
            _ = dragging.filter(event, in: window)
            XCTAssertEqual(window.frame.origin.x, origin.x + target.x - start.x, accuracy: 0.1)
        }
    }

    func testHoldingAgainstEveryEdgeStaysStillAndOldEventsCannotPullItBack() throws {
        _ = Headless.active
        let area = try XCTUnwrap(NSScreen.main?.visibleFrame)
        for style: NSWindow.StyleMask in [.borderless, [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel]] {
            let window = DragRecordingPanel(contentRect: NSRect(x: area.midX - 180, y: area.midY - 140, width: 360, height: 280),
                                            styleMask: style, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = DraggableBackground(frame: NSRect(origin: .zero, size: window.frame.size))
            defer { window.close() }
            let initial = window.frame
            for target in [NSPoint(x: area.minX, y: area.midY), NSPoint(x: area.maxX - 1, y: area.midY),
                           NSPoint(x: area.midX, y: area.minY), NSPoint(x: area.midX, y: area.maxY - 1)] {
                window.setFrameOrigin(initial.origin)
                let start = NSPoint(x: initial.midX, y: initial.maxY - 10)
                var pointer = start
                let dragging = ScreenBoundDragging(mouseLocation: { pointer })
                let down = try mouse(.leftMouseDown, at: start, in: window)
                // 提前排队：事件仍带着旧窗口坐标，处理时指针已经到达屏幕边缘。
                let stale = try mouse(.leftMouseDragged, at: NSPoint(x: start.x + 5, y: start.y), in: window)
                _ = dragging.filter(down, in: window)
                pointer = target
                _ = dragging.filter(stale, in: window)
                let edgeFrame = window.frame
                XCTAssertTrue(area.contains(edgeFrame))
                XCTAssertNotEqual(edgeFrame.origin, initial.origin)
                window.moves = 0
                for _ in 0..<100 {
                    _ = dragging.filter(stale, in: window)
                    XCTAssertEqual(window.frame, edgeFrame, "顶住边缘时，过时事件不能把窗口拉回去")
                }
                XCTAssertEqual(window.moves, 0, "目标没有变化时不重复提交窗口移动")
                pointer = NSPoint(x: target.x + (target.x < area.midX ? 10 : -10),
                                  y: target.y + (target.y < area.midY ? 10 : -10))
                _ = dragging.filter(stale, in: window)
                XCTAssertNotEqual(window.frame.origin, edgeFrame.origin, "到边缘后反向移动立即跟手，不累计越界距离")
                XCTAssertTrue(area.contains(window.frame))
                _ = dragging.filter(try mouse(.leftMouseUp, at: start, in: window), in: window)
            }
        }
    }

    func testContentDragKeepsNativeMovementDisabledWhileManualMovementRemainsEnabled() throws {
        _ = Headless.active
        let window = QuietWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 160),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = DraggableBackground(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        window.isMovableByWindowBackground = true
        var pointer = NSPoint.zero
        let dragging = ScreenBoundDragging(mouseLocation: { pointer })
        let start = NSPoint(x: 250, y: 250)
        pointer = start
        var forwarded = 0
        dragging.send(try mouse(.leftMouseDown, at: start, in: window), in: window) { event in
            XCTAssertEqual(event.type, .leftMouseDown)
            XCTAssertFalse(window.isMovable, "转发内容点击时不能同时启动系统窗口拖动")
            forwarded += 1
        }
        XCTAssertFalse(window.isMovable)
        XCTAssertTrue(window.allowsScreenBoundDragging)
        for delta in [20.0, 40, 60, 40, 20, 0, -20, 0] {
            pointer = NSPoint(x: start.x + delta, y: start.y)
            dragging.send(try mouse(.leftMouseDragged, at: NSPoint(x: start.x + delta, y: start.y), in: window), in: window) { _ in
                XCTFail("拖动不能交给第二个处理者")
            }
            XCTAssertEqual(window.frame.origin.x, 200 + delta, accuracy: 0.1)
        }
        pointer = start
        dragging.send(try mouse(.leftMouseUp, at: start, in: window), in: window) { event in
            XCTAssertEqual(event.type, .leftMouseUp)
            XCTAssertLessThan(event.locationInWindow.x, 0)
            forwarded += 1
        }
        dragging.send(try mouse(.leftMouseDragged, at: start, in: window), in: window) { _ in forwarded += 1 }
        XCTAssertEqual(forwarded, 3)
        XCTAssertFalse(window.isMovable)
        XCTAssertTrue(window.allowsScreenBoundDragging)
    }

    func testNativeTitlebarDragIsTakenOverInsteadOfHandedToWindowServer() throws {
        _ = Headless.active
        let area = try XCTUnwrap(NSScreen.main?.visibleFrame)
        // 终端：标题栏点在主题框架上；透明全尺寸标题栏：点在不接住点击、也不声明可拖的内容上。
        // 两种都必须直接接管；即使命中内容，透明标题栏也不能漏给系统移动。
        let cases: [(NSWindow.StyleMask, NSView)] = [
            ([.titled, .closable, .miniaturizable, .resizable], NSHostingView(rootView: Color.clear)),
            ([.titled, .closable, .resizable, .fullSizeContentView], PassThroughView())
        ]
        for (style, content) in cases {
            let window = NativeDragWindow(contentRect: NSRect(x: area.midX - 200, y: area.midY - 150, width: 400, height: 300),
                                          styleMask: style, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.contentView = content
            window.orderFront(nil)
            defer { window.close() }
            let initial = window.frame
            for target in [NSPoint(x: area.minX - 500, y: area.midY), NSPoint(x: area.maxX + 500, y: area.midY),
                           NSPoint(x: area.midX, y: area.minY - 500), NSPoint(x: area.midX, y: area.maxY + 500)] {
                window.setFrameOrigin(initial.origin)
                let start = NSPoint(x: initial.midX, y: initial.maxY - 12)
                window.pointer = start
                window.sendEvent(try mouse(.leftMouseDown, at: start, in: window))
                XCTAssertEqual(window.nativeDrags, 0, "普通和透明标题栏均直接接管，不启动 AppKit 拖动")
                XCTAssertEqual(window.handedToSystem, 0, "\(style): 原生拖动不能交给窗口服务器")
                window.pointer = target
                window.sendEvent(try mouse(.leftMouseDragged, at: target, in: window))
                XCTAssertTrue(area.contains(window.frame), "\(style): \(window.frame)")
                XCTAssertNotEqual(window.frame.origin, initial.origin)
                window.sendEvent(try mouse(.leftMouseUp, at: target, in: window))
                window.nativeDrags = 0
            }
        }
    }

    func testProductionWindowsDisableServerMovementAndStopBeforeEveryEdgeDuringFastDrags() throws {
        let area = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let cases: [(NSWindow.StyleMask, NSView)] = [
            (.borderless, DraggableBackground()),
            ([.titled, .closable, .resizable], NSHostingView(rootView: Color.clear)),
            ([.titled, .closable, .resizable, .fullSizeContentView], PassThroughView())
        ]
        for (style, content) in cases {
            for panel in [false, true] {
                let frame = NSRect(x: area.midX - 180, y: area.midY - 140, width: 360, height: 280)
                let window: NSWindow = panel
                    ? PointerDrivenPanel(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
                    : PointerDrivenWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                    window.standardWindowButton(type)?.isHidden = true
                }
                window.contentView = content
                window.orderFront(nil)
                defer { window.close() }
                let controlled = try XCTUnwrap(window as? PointerDriven)
                XCTAssertFalse(window.isMovable, "窗口服务器不得独立移动窗口，否则会先越界再被拉回")
                XCTAssertTrue((window as? ScreenBoundMovable)?.allowsScreenBoundDragging == true)
                let initial = window.frame
                for direction in [NSPoint(x: -1, y: 0), NSPoint(x: 1, y: 0), NSPoint(x: 0, y: -1), NSPoint(x: 0, y: 1)] {
                    window.setFrame(initial, display: false)
                    let start = NSPoint(x: initial.midX, y: initial.maxY - 12)
                    controlled.pointer = start
                    window.sendEvent(try mouse(.leftMouseDown, at: start, in: window))
                    controlled.requests = []
                    let target = NSPoint(x: start.x + direction.x * 10_000, y: start.y + direction.y * 10_000)
                    controlled.pointer = target
                    // 事件仍是旧坐标；实际指针已经快速移动到边界外。
                    let stale = try mouse(.leftMouseDragged, at: start, in: window)
                    window.sendEvent(stale)
                    let stopped = window.frame
                    XCTAssertNotEqual(stopped.origin, initial.origin, "\(style) 必须仍可手动拖动")
                    XCTAssertTrue(area.contains(stopped))
                    XCTAssertTrue(controlled.requests.allSatisfy(area.contains), "不能向系统提交越界帧")
                    controlled.requests = []
                    for _ in 0..<100 { window.sendEvent(stale) }
                    XCTAssertEqual(window.frame, stopped)
                    XCTAssertTrue(controlled.requests.isEmpty, "顶住边缘时不重复移动或回拉")
                    controlled.pointer = NSPoint(x: target.x - direction.x * 5, y: target.y - direction.y * 5)
                    window.sendEvent(stale)
                    XCTAssertEqual(window.frame.minX, stopped.minX - direction.x * 5, accuracy: 0.1)
                    XCTAssertEqual(window.frame.minY, stopped.minY - direction.y * 5, accuracy: 0.1)
                    window.sendEvent(try mouse(.leftMouseUp, at: controlled.pointer, in: window))
                    XCTAssertFalse(window.isMovable, "松手后也不能重新启用系统移动")
                }
            }
        }
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

private final class PassThroughView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// 与两个窗口基类相同的接线，只是指针位置由测试提供。
private final class NativeDragWindow: NSWindow {
    var pointer = NSPoint.zero
    var nativeDrags = 0, handedToSystem = 0
    private lazy var dragging = ScreenBoundDragging(mouseLocation: { [unowned self] in pointer })

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        ignoresMouseEvents = true
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        WindowScreenBounds.constrain(frameRect, to: NSScreen.screens.map(\.visibleFrame), fallback: NSScreen.main?.visibleFrame)
    }

    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrame(constrainFrameRect(NSRect(origin: point, size: frame.size), to: nil), display: false)
    }

    override func sendEvent(_ event: NSEvent) {
        dragging.send(event, in: self) { super.sendEvent($0) }
    }

    override func performDrag(with event: NSEvent) {
        nativeDrags += 1
        dragging.performDrag(with: event, in: self) { _ in handedToSystem += 1 }
    }
}

private final class DragRecordingPanel: QuietPanel {
    var moves = 0
    override func setFrameOrigin(_ point: NSPoint) {
        moves += 1
        super.setFrameOrigin(point)
    }
}

@MainActor
private protocol PointerDriven: AnyObject {
    var pointer: NSPoint { get set }
    var requests: [NSRect] { get set }
}

private final class PointerDrivenWindow: QuietWindow, PointerDriven {
    var pointer = NSPoint.zero
    var requests: [NSRect] = []
    override var dragMouseLocation: NSPoint { pointer }
    override func setFrameOrigin(_ point: NSPoint) {
        requests.append(NSRect(origin: point, size: frame.size))
        super.setFrameOrigin(point)
    }
}

private final class PointerDrivenPanel: QuietPanel, PointerDriven {
    var pointer = NSPoint.zero
    var requests: [NSRect] = []
    override var dragMouseLocation: NSPoint { pointer }
    override func setFrameOrigin(_ point: NSPoint) {
        requests.append(NSRect(origin: point, size: frame.size))
        super.setFrameOrigin(point)
    }
}
