import AppKit
import XCTest
@testable import Timeline

@MainActor
final class WindowScreenBoundsTests: XCTestCase {
    private let large = NSRect(x: 0, y: 40, width: 1400, height: 900)
    private let small = NSRect(x: 0, y: 40, width: 800, height: 600)

    private func windows() -> [NSWindow] {
        _ = Headless.active
        return [BoundsWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 200),
                             styleMask: [.borderless], backing: .buffered, defer: false),
                BoundsPanel(contentRect: NSRect(x: 200, y: 200, width: 300, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)]
    }

    private func screens(_ areas: [NSRect], for window: NSWindow) {
        (window as? BoundsWindow)?.areas = areas
        (window as? BoundsPanel)?.areas = areas
    }

    func testEveryPlacementAPIClampsPartialOverflowAndSizeChanges() {
        for window in windows() {
            window.isReleasedWhenClosed = false
            defer { window.close() }
            screens([small], for: window)
            window.setFrame(NSRect(x: 750, y: 600, width: 300, height: 200), display: false)
            XCTAssertEqual(window.frame, NSRect(x: 500, y: 440, width: 300, height: 200))
            window.setFrameOrigin(NSPoint(x: -100, y: -100))
            XCTAssertEqual(window.frame.origin, NSPoint(x: 0, y: 40))
            window.setFrameTopLeftPoint(NSPoint(x: 1000, y: 1000))
            XCTAssertTrue(small.contains(window.frame))
            window.setFrame(NSRect(x: 500, y: 440, width: 500, height: 400), display: false, animate: false)
            XCTAssertEqual(window.frame, NSRect(x: 300, y: 240, width: 500, height: 400))
            window.setContentSize(NSSize(width: 600, height: 500))
            XCTAssertTrue(small.contains(window.frame), "Content-driven resizing must use the same constraint")
            XCTAssertEqual(window.constrainFrameRect(NSRect(x: 790, y: 630, width: 100, height: 100), to: nil),
                           NSRect(x: 700, y: 540, width: 100, height: 100))
        }
    }

    func testSavedFrameRestoresEntirelyInsideSmallerScreen() {
        for window in windows() {
            window.isReleasedWhenClosed = false
            defer { window.close() }
            screens([large], for: window)
            window.setFrame(NSRect(x: 1000, y: 700, width: 300, height: 200), display: false)
            let name = "TimelineScreenBoundsTests.\(UUID().uuidString)"
            window.saveFrame(usingName: name)
            defer { NSWindow.removeFrame(usingName: name) }
            screens([small], for: window)
            XCTAssertTrue(window.setFrameUsingName(name, force: true))
            XCTAssertTrue(small.contains(window.frame), "Restoring a partly offscreen saved frame must keep the whole window visible")
            XCTAssertEqual(window.frame.size, NSSize(width: 300, height: 200))
        }
    }

    func testScreenChangeRepositionsVisibleWindowsAndShowingRepositionsHiddenWindows() {
        for window in windows() {
            window.isReleasedWhenClosed = false
            defer { window.close() }
            for show in [{ window.orderFront(nil) }, { window.orderFrontRegardless() }, { window.makeKeyAndOrderFront(nil) }] {
                window.orderOut(nil)
                screens([large], for: window)
                window.setFrame(NSRect(x: 1000, y: 700, width: 300, height: 200), display: false)
                screens([small], for: window)
                NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
                XCTAssertEqual(window.frame.minX, 1000, "Hidden windows need not move until shown")
                show()
                XCTAssertTrue(small.contains(window.frame), "Every show path must recheck the screen")
                screens([large], for: window)
                window.setFrameOrigin(NSPoint(x: 1000, y: 700))
                screens([small], for: window)
                NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
                XCTAssertTrue(small.contains(window.frame), "Visible windows must follow screen changes immediately")
                XCTAssertEqual(Headless.actualAlpha(of: window), 0)
            }
        }
    }

    func testContinuousScreensAllowSpanningIncludingNegativeCoordinates() {
        let left = NSRect(x: -1200, y: 40, width: 1200, height: 800)
        let right = NSRect(x: 0, y: 40, width: 1400, height: 900)
        for window in windows() {
            window.isReleasedWhenClosed = false
            defer { window.close() }
            screens([left, right], for: window)
            window.setFrame(NSRect(x: -250, y: 300, width: 400, height: 300), display: false)
            XCTAssertEqual(window.frame.minX, -250, "A fully visible spanning window must not jump to either screen")
            window.setFrame(NSRect(x: -150, y: 300, width: 400, height: 300), display: false)
            XCTAssertEqual(window.frame.minX, -150)
        }
        XCTAssertEqual(WindowScreenBounds.constrain(NSRect(x: 4000, y: 4000, width: 300, height: 200),
                                                     to: [left, right], fallback: right).origin,
                       NSPoint(x: 1100, y: 740))
    }

    func testLiveResizeClipsMovingEdgesWithoutPushingOppositeEdges() {
        for window in windows() {
            window.isReleasedWhenClosed = false
            defer { window.close() }
            screens([small], for: window)
            let initial = NSRect(x: 200, y: 200, width: 300, height: 200)
            let proposals = [NSRect(x: -100, y: 200, width: 600, height: 200),
                             NSRect(x: 200, y: -100, width: 300, height: 500),
                             NSRect(x: -100, y: -100, width: 600, height: 500),
                             NSRect(x: 200, y: 200, width: 900, height: 200),
                             NSRect(x: 200, y: 200, width: 300, height: 900)]
            for (index, proposed) in proposals.enumerated() {
                (window as? BoundsWindow)?.resizing = false
                (window as? BoundsPanel)?.resizing = false
                window.setFrame(initial, display: false)
                (window as? BoundsWindow)?.resizing = true
                (window as? BoundsPanel)?.resizing = true
                let expected = proposed.intersection(small)
                XCTAssertEqual(window.constrainFrameRect(proposed, to: nil), expected)
                for _ in 0..<5 {
                    if index.isMultiple(of: 2) { window.setFrame(proposed, display: false) }
                    else { window.setFrame(proposed, display: false, animate: false) }
                    XCTAssertEqual(window.frame, expected, "Repeated live-resize proposals must not move the fixed opposite edge")
                }
            }
        }
    }

    func testDraggingAcrossAdjacentScreensFollowsPointerContinuouslyInBothDirections() throws {
        let left = NSRect(x: -800, y: 40, width: 800, height: 600)
        for window in windows() {
            window.isReleasedWhenClosed = false
            defer { window.close() }
            screens([left, small], for: window)
            window.setFrame(NSRect(x: -500, y: 200, width: 300, height: 200), display: false)
            window.contentView = BoundsDragBackground(frame: NSRect(origin: .zero, size: window.frame.size))
            let initial = window.frame
            let start = NSPoint(x: initial.midX, y: initial.midY)
            var pointer = start
            let dragging = ScreenBoundDragging(mouseLocation: { pointer })
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: pointer), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            _ = dragging.filter(try event(.leftMouseDown), in: window)
            let deltas = Array(stride(from: 10, through: 800, by: 10)) + Array(stride(from: 790, through: 0, by: -10))
            for delta in deltas {
                pointer.x = start.x + CGFloat(delta)
                _ = dragging.filter(try event(.leftMouseDragged), in: window)
                XCTAssertEqual(window.frame.origin.x, initial.minX + CGFloat(delta), accuracy: 0.1)
                XCTAssertEqual(window.frame.origin.y, initial.minY)
            }
            _ = dragging.filter(try event(.leftMouseUp), in: window)
            XCTAssertEqual(window.frame, initial)
        }
    }

    func testContinuousAreasDoNotBridgeGapsOrExposeScreenNotches() {
        let left = NSRect(x: -800, y: 40, width: 800, height: 600)
        let above = NSRect(x: 0, y: 640, width: 800, height: 600)
        let spanning = NSRect(x: 200, y: 550, width: 300, height: 200)
        XCTAssertEqual(WindowScreenBounds.constrain(spanning, to: [small, above], fallback: small), spanning)
        let separated = NSRect(x: 100, y: 40, width: 800, height: 600)
        let gapFrame = NSRect(x: -100, y: 200, width: 300, height: 200)
        let constrained = WindowScreenBounds.constrain(gapFrame, to: [left, separated], fallback: left)
        XCTAssertTrue(left.contains(constrained) || separated.contains(constrained))
        let tall = NSRect(x: -800, y: 40, width: 800, height: 900)
        let notch = NSRect(x: -100, y: 600, width: 300, height: 200)
        let result = WindowScreenBounds.constrain(notch, to: [tall, small], fallback: small)
        let covered = [tall, small].map { result.intersection($0) }.filter { !$0.isNull }
            .reduce(CGFloat.zero) { $0 + $1.width * $1.height }
        XCTAssertEqual(covered, result.width * result.height, "A bounding-box union must not expose a missing corner")
    }

    func testTitlebarDoubleClickRespectsSystemPreferenceAndWindowCapabilities() {
        let defaults = InMemoryDefaults()
        let dragging = ScreenBoundDragging(defaults: defaults)
        let window = TitlebarActionWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
                                         styleMask: [.titled, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for (value, zooms, minimizes) in [("None", 0, 0), ("Minimize", 0, 1), ("Zoom", 1, 1), ("Maximize", 2, 1), ("Fill", 3, 1), ("FutureValue", 4, 1)] {
            defaults.set(value, forKey: "AppleActionOnDoubleClick")
            dragging.doubleClickTitlebar(in: window)
            XCTAssertEqual(window.zooms, zooms)
            XCTAssertEqual(window.minimizes, minimizes)
        }
        window.styleMask.remove([.resizable, .miniaturizable])
        for value in ["Zoom", "Minimize"] {
            defaults.set(value, forKey: "AppleActionOnDoubleClick")
            dragging.doubleClickTitlebar(in: window)
        }
        XCTAssertEqual(window.zooms, 4)
        XCTAssertEqual(window.minimizes, 1)
        window.styleMask.insert(.miniaturizable)
        defaults.removeObject(forKey: "AppleActionOnDoubleClick")
        defaults.set(true, forKey: "AppleMiniaturizeOnDoubleClick")
        dragging.doubleClickTitlebar(in: window)
        XCTAssertEqual(window.minimizes, 2)
        defaults.removeObject(forKey: "AppleMiniaturizeOnDoubleClick")
        window.styleMask.insert(.resizable)
        dragging.doubleClickTitlebar(in: window)
        XCTAssertEqual(window.zooms, 5, "An unset system preference defaults to zoom")
    }
}

private final class BoundsWindow: QuietWindow {
    var areas: [NSRect]?
    var resizing = false
    override var inLiveResize: Bool { resizing || super.inLiveResize }
    override var screenVisibleFrames: [NSRect] { areas ?? super.screenVisibleFrames }
}

private final class BoundsPanel: QuietPanel {
    var areas: [NSRect]?
    var resizing = false
    override var inLiveResize: Bool { resizing || super.inLiveResize }
    override var screenVisibleFrames: [NSRect] { areas ?? super.screenVisibleFrames }
}

private final class BoundsDragBackground: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

private final class TitlebarActionWindow: QuietWindow {
    var zooms = 0, minimizes = 0
    override func performZoom(_ sender: Any?) { zooms += 1 }
    override func performMiniaturize(_ sender: Any?) { minimizes += 1 }
}
