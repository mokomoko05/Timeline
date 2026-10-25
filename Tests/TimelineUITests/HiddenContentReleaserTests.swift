import AppKit
import XCTest
@testable import Timeline

/// 隐藏太久的窗口释放界面，显示前重建；短暂隐藏不释放；光标停在有字的输入框里不释放。
@MainActor
final class HiddenContentReleaserTests: XCTestCase {
    private static var keepAlive: [NSWindow] = []
    override func setUp() async throws { HiddenContentReleaser.delayOverride = nil }

    private func makeWindow() -> QuietWindow {
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        Self.keepAlive.append(window)
        return window
    }

    func testReleasesAfterBeingHiddenLongEnoughAndRebuildsBeforeShowing() async throws {
        let window = makeWindow()
        var released = 0, rebuilt = 0
        let releaser = HiddenContentReleaser(window: window, delay: .milliseconds(80), release: { released += 1 }, rebuild: { rebuilt += 1 })
        window.orderFront(nil)
        window.orderOut(nil)
        releaser.windowHidden()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(released, 1)
        XCTAssertTrue(releaser.released)
        releaser.restoreIfNeeded()
        window.orderFront(nil)
        XCTAssertEqual(rebuilt, 1)
        releaser.restoreIfNeeded()
        XCTAssertEqual(rebuilt, 1, "没释放过就不重建")
        window.orderOut(nil)
    }

    func testShortHideDoesNotRelease() async throws {
        let window = makeWindow()
        var released = 0
        let releaser = HiddenContentReleaser(window: window, delay: .milliseconds(80), release: { released += 1 }, rebuild: {})
        window.orderFront(nil)
        window.orderOut(nil)
        releaser.windowHidden()
        try await Task.sleep(for: .milliseconds(20))
        releaser.restoreIfNeeded()
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(released, 0, "很快又显示：不释放")
        window.orderOut(nil)
    }

    func testTypedTextInTheFocusedFieldKeepsTheContent() async throws {
        let window = makeWindow()
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        window.contentView?.addSubview(field)
        field.string = "unsaved"
        window.makeFirstResponder(field)
        var released = 0
        let releaser = HiddenContentReleaser(window: window, delay: .milliseconds(80), release: { released += 1 }, rebuild: {})
        window.orderFront(nil)
        window.orderOut(nil)
        releaser.windowHidden()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(released, 0, "还有没提交的字：不释放")
    }
}
