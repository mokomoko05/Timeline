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

    func testLargestOverlapChoosesScreenIncludingNegativeCoordinates() {
        let left = NSRect(x: -1200, y: 40, width: 1200, height: 800)
        let right = NSRect(x: 0, y: 40, width: 1400, height: 900)
        for window in windows() {
            window.isReleasedWhenClosed = false
            defer { window.close() }
            screens([left, right], for: window)
            window.setFrame(NSRect(x: -250, y: 300, width: 400, height: 300), display: false)
            XCTAssertEqual(window.frame.minX, -400, "The larger portion is on the left screen")
            window.setFrame(NSRect(x: -150, y: 300, width: 400, height: 300), display: false)
            XCTAssertEqual(window.frame.minX, 0)
        }
        XCTAssertEqual(WindowScreenBounds.constrain(NSRect(x: 4000, y: 4000, width: 300, height: 200),
                                                     to: [left, right], fallback: right).origin,
                       NSPoint(x: 1100, y: 740))
    }

    func testTitlebarDoubleClickRespectsSystemPreferenceAndWindowCapabilities() {
        let defaults = InMemoryDefaults()
        let dragging = ScreenBoundDragging(defaults: defaults)
        let window = TitlebarActionWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
                                         styleMask: [.titled, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for (value, zooms, minimizes) in [("None", 0, 0), ("Minimize", 0, 1), ("Zoom", 1, 1), ("Maximize", 2, 1)] {
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
        XCTAssertEqual(window.zooms, 2)
        XCTAssertEqual(window.minimizes, 1)
        window.styleMask.insert(.miniaturizable)
        defaults.removeObject(forKey: "AppleActionOnDoubleClick")
        defaults.set(true, forKey: "AppleMiniaturizeOnDoubleClick")
        dragging.doubleClickTitlebar(in: window)
        XCTAssertEqual(window.minimizes, 2)
    }
}

private final class BoundsWindow: QuietWindow {
    var areas: [NSRect]?
    override var screenVisibleFrames: [NSRect] { areas ?? super.screenVisibleFrames }
}

private final class BoundsPanel: QuietPanel {
    var areas: [NSRect]?
    override var screenVisibleFrames: [NSRect] { areas ?? super.screenVisibleFrames }
}

private final class TitlebarActionWindow: QuietWindow {
    var zooms = 0, minimizes = 0
    override func performZoom(_ sender: Any?) { zooms += 1 }
    override func performMiniaturize(_ sender: Any?) { minimizes += 1 }
}
