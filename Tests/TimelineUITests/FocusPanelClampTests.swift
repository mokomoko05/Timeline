import AppKit
import XCTest
@testable import Timeline

final class FocusPanelClampTests: XCTestCase {
    private let visible = NSRect(x: 0, y: 40, width: 1440, height: 835)

    func testInsideFrameStaysPut() {
        let frame = NSRect(x: 200, y: 300, width: 340, height: 158)
        XCTAssertEqual(FocusPanel.clamp(frame, to: visible), frame)
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
            let clamped = FocusPanel.clamp(NSRect(origin: origin, size: size), to: visible)
            XCTAssertEqual(clamped.origin, expected, "\(origin)")
            XCTAssertEqual(clamped.size, size)
        }
    }

    func testOversizedFrameKeepsTopLeftVisible() {
        let clamped = FocusPanel.clamp(NSRect(x: 100, y: 100, width: 2000, height: 1000), to: visible)
        XCTAssertEqual(clamped.minX, visible.minX)
        XCTAssertEqual(clamped.maxY, visible.maxY)
    }
}
