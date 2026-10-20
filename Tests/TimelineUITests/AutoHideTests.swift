import AppKit
import XCTest
@testable import Timeline

@MainActor
final class AutoHideTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    override func setUp() async throws { _ = NSApplication.shared }

    private func makeDefaults() -> UserDefaults {
        let suite = "autohide-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite).plist"))
        }
        return defaults
    }

    private func shown(_ count: Int = 1) -> [NSWindow] {
        (0..<count).map { _ in
            let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.orderFront(nil)
            Self.keepAlive.append(window)
            return window
        }
    }

    func testWorkWindowsHideTheMomentTheAppLosesTheFrontAndKeepTheirState() {
        let defaults = makeDefaults()
        let windows = shown(3)
        windows[1].setFrame(NSRect(x: 40, y: 50, width: 321, height: 222), display: false)
        var extra = 0
        let hide = AutoHideOnResign(defaults: defaults, windows: { windows }, extraHide: { extra += 1 })
        XCTAssertTrue(windows.allSatisfy(\.isVisible))
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertTrue(windows.allSatisfy { !$0.isVisible }, "立刻全部收起，没有延迟")
        XCTAssertEqual(hide.lastHiddenCount, 3)
        XCTAssertEqual(extra, 1, "终端那一组也收起")
        XCTAssertEqual(windows[1].frame.size, NSSize(width: 321, height: 222), "只是 orderOut：大小位置都还在")
    }

    func testWindowsNotInTheListStayVisible() {
        // 快速日志面板、专注计时窗口不在名单里：失焦后仍留在屏幕上。
        let defaults = makeDefaults()
        let work = shown(1)
        let floating = shown(2)
        let hide = AutoHideOnResign(defaults: defaults, windows: { work })
        hide.appResignedActive()
        XCTAssertFalse(work[0].isVisible)
        XCTAssertTrue(floating.allSatisfy(\.isVisible), "悬浮窗口不受影响")
    }

    func testDisabledPreferenceKeepsEverythingAndDefaultIsOn() {
        let defaults = makeDefaults()
        XCTAssertTrue(AutoHideOnResign.isEnabled(defaults), "默认开")
        defaults.set(false, forKey: AutoHideOnResign.prefKey)
        let windows = shown(2)
        let hide = AutoHideOnResign(defaults: defaults, windows: { windows })
        hide.appResignedActive()
        XCTAssertTrue(windows.allSatisfy(\.isVisible), "关掉这个设置就什么都不收")
        defaults.set(true, forKey: AutoHideOnResign.prefKey)
        hide.appResignedActive()
        XCTAssertTrue(windows.allSatisfy { !$0.isVisible })
    }

    func testAlreadyHiddenMissingAndMiniaturizedWindowsAreIgnored() {
        let defaults = makeDefaults()
        let windows = shown(2)
        windows[0].orderOut(nil)
        let hide = AutoHideOnResign(defaults: defaults, windows: { [windows[0], nil, windows[1]] })
        XCTAssertEqual(hide.hideNow(), 1, "只算真正收起的")
        XCTAssertEqual(hide.hideNow(), 0, "再来一次什么都没有")
    }

    func testHidingCommitsEditingSoNothingTypedIsLost() {
        let defaults = makeDefaults()
        let windows = shown(1)
        var committed = 0
        let token = NotificationCenter.default.addObserver(forName: .timelineCommitEditing, object: nil, queue: nil) { _ in committed += 1 }
        addTeardownBlock { NotificationCenter.default.removeObserver(token) }
        let hide = AutoHideOnResign(defaults: defaults, windows: { windows })
        hide.hideNow()
        XCTAssertEqual(committed, 1, "收起前先提交正在编辑的内容")
        hide.hideNow()
        XCTAssertEqual(committed, 1, "没有可见窗口时不打扰")
    }

    func testHidingDoesNotHandFocusBackToThePreviousApp() {
        let defaults = makeDefaults()
        let windows = shown(1)
        PreviousApp.app = NSWorkspace.shared.runningApplications.first
        let hide = AutoHideOnResign(defaults: defaults, windows: { windows })
        hide.hideNow()
        XCTAssertNil(PreviousApp.app, "用户已经在别的应用里，不再把他拉回去；也不留着过期的记录")
    }

    func testTerminalWindowsHideWithoutEndingShells() {
        let controller = ShellWindowController()
        controller.arguments = ["-f", "-i"]
        controller.confirmClose = { _ in false }
        addTeardownBlock { @MainActor in controller.terminateAll(); controller.windows.forEach { $0.close() } }
        controller.show()
        XCTAssertEqual(controller.windows.count, 1)
        let pid = controller.windows[0].terminal.process.shellPid
        controller.hideForAppDeactivation()
        XCTAssertTrue(controller.windows.allSatisfy { !$0.isVisible })
        XCTAssertEqual(controller.windows.count, 1, "窗口还在，只是藏起来")
        XCTAssertEqual(controller.windows[0].terminal.process.shellPid, pid, "shell 仍在运行")
        controller.show()
        XCTAssertTrue(controller.windows[0].isVisible, "再唤起就回来，还是同一个终端")
    }
}
