import AppKit
import XCTest
@testable import Timeline

/// 守门测试：跑完前面所有 UI 测试后，没有任何窗口真的被画在屏幕上（否则用户会看到闪动）。
/// 类名以 ZZ 开头，保证最后运行。
@MainActor
final class ZZNoVisibleWindowsTests: XCTestCase {
    func testNoWindowCreatedByTheTestsIsActuallyDrawn() {
        let drawn = NSApplication.shared.windows.filter { window in
            guard window.isVisible else { return false }
            let alpha = (window as? QuietWindow)?.actualAlpha ?? window.alphaValue
            return alpha > 0
        }
        XCTAssertTrue(drawn.isEmpty, "这些窗口会真的出现在屏幕上：\(drawn.map { "\(type(of: $0)) \"\($0.title)\"" })")
    }

    /// 测试里的窗口只记录逻辑透明度，淡入淡出的代码读到的和平时一样。
    func testQuietWindowKeepsTheLogicalAlphaButNeverDrawsAnything() {
        let window = QuietWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        XCTAssertEqual(window.alphaValue, 1)
        window.alphaValue = 0.4
        XCTAssertEqual(window.alphaValue, 0.4, accuracy: 0.001)
        XCTAssertEqual(window.actualAlpha, 0)
        XCTAssertTrue(window.ignoresMouseEvents)
    }
}
