import AppKit
import XCTest
@testable import Timeline

final class CalendarClickTests: XCTestCase {
    @MainActor
    func testFirstClickSelectsImmediatelyWithoutWaitingForSecondClick() async {
        let view = CalendarClickView(frame: NSRect(x: 0, y: 0, width: 100, height: 120))
        var actions: [String] = []
        view.select = { actions.append("select") }
        view.expand = { actions.append("expand") }
        view.track(.leftMouseDown, at: NSPoint(x: 20, y: 30))
        view.track(.leftMouseUp, at: NSPoint(x: 20, y: 30))
        XCTAssertEqual(actions, ["select"])
        view.track(.leftMouseDown, at: NSPoint(x: 20, y: 30), clickCount: 2)
        view.track(.leftMouseUp, at: NSPoint(x: 20, y: 30), clickCount: 2)
        XCTAssertEqual(actions, ["select", "select", "expand"])
        XCTAssertNil(view.hitTest(NSPoint(x: 20, y: 30)))
    }

    @MainActor
    func testDraggingOrClickingOutsideDoesNotSelectDate() async {
        let view = CalendarClickView(frame: NSRect(x: 0, y: 0, width: 100, height: 120))
        var selections = 0
        view.select = { selections += 1 }
        view.track(.leftMouseDown, at: NSPoint(x: 20, y: 30))
        view.track(.leftMouseDragged, at: NSPoint(x: 40, y: 50))
        view.track(.leftMouseUp, at: NSPoint(x: 20, y: 30))
        view.track(.leftMouseDown, at: NSPoint(x: 150, y: 30))
        view.track(.leftMouseUp, at: NSPoint(x: 20, y: 30))
        view.track(.leftMouseDown, at: NSPoint(x: 20, y: 30))
        view.track(.leftMouseUp, at: NSPoint(x: 150, y: 30))
        XCTAssertEqual(selections, 0)
    }
}
