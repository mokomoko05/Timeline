import AppKit
import XCTest
@testable import Timeline

/// 每个用例结束时查一遍：还有窗口真的画在屏幕上就记下来是谁（`Headless.visibleOrders`），最后由守门测试报错。
final class DrawnWindowObserver: NSObject, XCTestObservation {
    func testCaseDidFinish(_ testCase: XCTestCase) {
        let name = testCase.name
        MainActor.assumeIsolated {
            for window in Headless.drawnWindows() {
                Headless.visibleOrders.append("\(type(of: window)) \"\(window.title)\" [\(name)]")
            }
        }
    }
}

/// 类名以 AAA 开头，保证最先运行：装上逐个用例的检查，最后由 `ZZNoVisibleWindowsTests` 汇总。
@MainActor
final class AAAWindowWatchTests: XCTestCase {
    private static let observer = DrawnWindowObserver()

    func testStartWatchingWindowsBeforeAnyUITest() {
        XCTAssertTrue(Headless.active)
        XCTestObservationCenter.shared.addTestObserver(Self.observer)
        // 普通 NSWindow（不是 QuietWindow）也画不出来：淡入、复位透明度都只改逻辑值。
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertEqual(Headless.actualAlpha(of: window), 0)
        window.alphaValue = 0.6
        XCTAssertEqual(window.alphaValue, 0.6, accuracy: 0.001)
        XCTAssertEqual(Headless.actualAlpha(of: window), 0)
        window.orderOut(nil)
    }
}
