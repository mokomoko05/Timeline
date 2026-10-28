import AppKit
import XCTest
@testable import Timeline

final class WindowScreenBoundsClampTests: XCTestCase {
    private let visible = NSRect(x: 0, y: 40, width: 1440, height: 835)

    func testInsideFrameStaysPut() {
        let frame = NSRect(x: 200, y: 300, width: 340, height: 158)
        XCTAssertEqual(WindowScreenBounds.clamp(frame, to: visible), frame)
    }

    func testEveryEdgeIsPulledBackOnScreen() {
        let size = NSSize(width: 340, height: 158)
        let cases: [(NSPoint, NSPoint)] = [
            (NSPoint(x: -80, y: 300), NSPoint(x: 0, y: 300)),
            (NSPoint(x: 1300, y: 300), NSPoint(x: 1100, y: 300)),
            (NSPoint(x: 200, y: -20), NSPoint(x: 200, y: 40)),
            (NSPoint(x: 200, y: 800), NSPoint(x: 200, y: 717)),
            (NSPoint(x: 2000, y: 2000), NSPoint(x: 1100, y: 717)),
        ]
        for (origin, expected) in cases {
            let clamped = WindowScreenBounds.clamp(NSRect(origin: origin, size: size), to: visible)
            XCTAssertEqual(clamped.origin, expected, "\(origin)")
            XCTAssertEqual(clamped.size, size)
        }
    }

    func testOversizedFrameKeepsTopLeftVisible() {
        let clamped = WindowScreenBounds.clamp(NSRect(x: 100, y: 100, width: 2000, height: 1000), to: visible)
        XCTAssertEqual(clamped.minX, visible.minX)
        XCTAssertEqual(clamped.maxY, visible.maxY)
    }
}

final class FocusPanelRestoreTests: XCTestCase {
    private let visible = NSRect(x: 0, y: 40, width: 1440, height: 835)

    /// 小伙伴贴在右下角时记下的位置，再打开完整面板：仍贴右边和底边，不会因为变高而离开底边。
    func testRightDockedPanelKeepsRightAndBottomEdges() {
        let companion = NSRect(x: 1374, y: 46, width: 60, height: 44)
        let frame = FocusPanel.restored(companion, size: NSSize(width: 340, height: 158), in: visible)
        XCTAssertEqual(frame, NSRect(x: 1094, y: 46, width: 340, height: 158))
    }

    func testLeftDockedPanelKeepsLeftEdge() {
        let saved = NSRect(x: 6, y: 300, width: 340, height: 400)
        let frame = FocusPanel.restored(saved, size: NSSize(width: 60, height: 44), in: visible)
        XCTAssertEqual(frame, NSRect(x: 6, y: 300, width: 60, height: 44))
    }
}
