import AppKit
import XCTest
@testable import Timeline

/// 主窗口钉在屏幕中央：拖不动，任何改位置 / 尺寸的调用都回到中央，拉边缘时对称缩放。
@MainActor
final class MainWindowCenteringTests: XCTestCase {
    private let area = NSRect(x: 0, y: 40, width: 1440, height: 835)
    private let noMax = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

    func testFrameIsCenteredInVisibleArea() {
        let frame = MainWindow.centeredFrame(size: NSSize(width: 1000, height: 600), in: area, minSize: .zero, maxSize: noMax)
        XCTAssertEqual(frame, NSRect(x: 220, y: 158, width: 1000, height: 600))
    }

    func testSizeIsClampedToMinimumAndScreen() {
        let small = MainWindow.centeredFrame(size: NSSize(width: 100, height: 100), in: area, minSize: NSSize(width: 640, height: 560), maxSize: noMax)
        XCTAssertEqual(small.size, NSSize(width: 640, height: 560))
        let huge = MainWindow.centeredFrame(size: NSSize(width: 5000, height: 5000), in: area, minSize: .zero, maxSize: noMax)
        XCTAssertEqual(huge, area)
    }

    /// 拉右边向右 30：宽度加 60；拉左边向左 30 同样加 60；拉上边、下边同理；没拉的方向沿用系统的尺寸。
    func testDraggingAnEdgeResizesSymmetrically() {
        let start = NSSize(width: 1000, height: 600)
        XCTAssertEqual(MainWindow.symmetricSize(start: start, edges: (1, 0), mouseDelta: NSPoint(x: 30, y: 5), proposed: NSSize(width: 1030, height: 600)),
                       NSSize(width: 1060, height: 600))
        XCTAssertEqual(MainWindow.symmetricSize(start: start, edges: (-1, 0), mouseDelta: NSPoint(x: -30, y: 0), proposed: NSSize(width: 1030, height: 600)),
                       NSSize(width: 1060, height: 600))
        XCTAssertEqual(MainWindow.symmetricSize(start: start, edges: (0, -1), mouseDelta: NSPoint(x: 0, y: 20), proposed: NSSize(width: 1000, height: 580)),
                       NSSize(width: 1000, height: 560))
        XCTAssertEqual(MainWindow.symmetricSize(start: start, edges: (1, 1), mouseDelta: NSPoint(x: -10, y: 10), proposed: NSSize(width: 990, height: 610)),
                       NSSize(width: 980, height: 620))
    }

    func testWindowCannotBeMovedOffCenter() throws {
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.minSize = NSSize(width: 640, height: 560)
        XCTAssertFalse(window.isMovable)
        XCTAssertFalse(window.isMovableByWindowBackground)
        let visible = try XCTUnwrap(window.screen ?? NSScreen.main).visibleFrame
        func assertCentered(_ line: UInt = #line) {
            XCTAssertEqual(window.frame.midX, visible.midX, accuracy: 1, line: line)
            XCTAssertEqual(window.frame.midY, visible.midY, accuracy: 1, line: line)
        }
        window.center()
        assertCentered()
        window.setFrameOrigin(NSPoint(x: visible.minX + 5, y: visible.minY + 5))
        assertCentered()
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 5, y: visible.maxY - 5))
        assertCentered()
        window.setFrame(NSRect(x: visible.minX, y: visible.minY, width: 700, height: 580), display: false)
        assertCentered()
        XCTAssertEqual(window.frame.size, NSSize(width: 700, height: 580))
    }

    /// 关掉「固定在屏幕中央」后是普通窗口：能拖、位置照设；再打开又回到中央。
    func testCenteringCanBeTurnedOff() throws {
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        let visible = try XCTUnwrap(window.screen ?? NSScreen.main).visibleFrame
        window.keepsCentered = false
        XCTAssertTrue(window.isMovable)
        let origin = NSPoint(x: visible.minX + 10, y: visible.minY + 10)
        window.setFrameOrigin(origin)
        XCTAssertEqual(window.frame.origin, origin)
        window.keepsCentered = true
        XCTAssertFalse(window.isMovable)
        XCTAssertEqual(window.frame.midX, visible.midX, accuracy: 1)
        XCTAssertEqual(window.frame.midY, visible.midY, accuracy: 1)
    }
}
