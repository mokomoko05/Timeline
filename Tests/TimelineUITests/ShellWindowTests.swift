import AppKit
import XCTest
import SwiftTerm
@testable import Timeline

@MainActor
final class ShellWindowTests: XCTestCase {
    private func text(of window: TerminalWindow) -> String {
        String(decoding: window.terminal.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    private func wait(_ seconds: TimeInterval, until condition: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !condition() { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    private func controller(_ arguments: [String]) -> ShellWindowController {
        let controller = ShellWindowController()
        controller.arguments = arguments
        controller.confirmClose = { _ in false }
        addTeardownBlock { @MainActor in controller.terminateAll(); controller.windows.forEach { $0.close() } }
        return controller
    }

    func testRealZshRunsInAPseudoTerminal() async throws {
        let controller = controller(["-c", "echo timeline-$((20+22))-ok; sleep 5"])
        controller.show()
        let window = try XCTUnwrap(controller.windows.first)
        await wait(5) { text(of: window).contains("timeline-42-ok") }
        XCTAssertTrue(text(of: window).contains("timeline-42-ok"))
        XCTAssertTrue(window.isVisible)
    }

    func testSeveralWindowsAndTabsRunIndependentShells() async throws {
        let controller = controller(["-f", "-i"])
        let first = controller.newWindow()
        let second = controller.newWindow()
        XCTAssertEqual(controller.windows.count, 2)
        XCTAssertNotEqual(first.terminal.process.shellPid, second.terminal.process.shellPid, "每个窗口是独立的 shell")
        let tab = controller.newTab()
        XCTAssertEqual(controller.windows.count, 3)
        XCTAssertEqual(tab.tabbedWindows?.count ?? 1, controller.keyTerminal === tab ? (tab.tabbedWindows?.count ?? 1) : 1)
        XCTAssertTrue((tab.tabbedWindows ?? []).count >= 2, "新标签页和锚点窗口在同一组标签里")
        XCTAssertNotEqual(tab.terminal.process.shellPid, second.terminal.process.shellPid)
    }

    func testNewTabAndWindowInheritTheCurrentDirectory() async throws {
        let controller = controller(["-f", "-i"])
        let first = controller.newWindow()
        first.terminal.send(txt: "cd /tmp\n")
        await wait(5) { ShellProcessInfo.currentDirectory(of: first.terminal.process.shellPid)?.hasSuffix("/tmp") == true }
        XCTAssertEqual(controller.currentDirectory(of: first)?.hasSuffix("/tmp"), true)
        let tab = controller.newTab()
        await wait(5) { ShellProcessInfo.currentDirectory(of: tab.terminal.process.shellPid)?.hasSuffix("/tmp") == true }
        XCTAssertEqual(controller.currentDirectory(of: tab)?.hasSuffix("/tmp"), true, "新标签页从当前目录开始")
    }

    func testClosingAskForConfirmationOnlyWhenAProgramIsRunning() async throws {
        let controller = controller(["-f", "-i"])
        let window = controller.newWindow()
        await wait(5) { !text(of: window).isEmpty }
        XCTAssertFalse(controller.isBusy(window), "停在提示符时不算在运行程序")
        XCTAssertTrue(controller.windowShouldClose(window), "空闲时直接关闭，不打扰")
        window.terminal.send(txt: "sleep 30\n")
        await wait(5) { controller.isBusy(window) }
        XCTAssertTrue(controller.isBusy(window), "前台有程序（比如 agent）时视为忙")
        XCTAssertEqual(controller.busyCount, 1)
        controller.confirmClose = { _ in false }
        XCTAssertFalse(controller.windowShouldClose(window), "选择取消就不关闭")
        controller.confirmClose = { _ in true }
        XCTAssertTrue(controller.windowShouldClose(window))
    }

    func testToolbarLivesInTheContentAreaSoTabGroupsCannotDuplicateIt() async throws {
        let controller = controller(["-c", "sleep 5"])
        let window = controller.newWindow()
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty, "单个窗口没有标题栏附件，工具条在内容区里")
        let tab = controller.newTab()
        // 合并成标签页后，系统会自己加一个标签栏附件；我们的工具条不能出现在附件里（否则会被各页共享而叠出多条）。
        for member in [window, tab] {
            let toolbar = try XCTUnwrap(member.toolbarView)
            XCTAssertTrue(toolbar.superview === member.contentView, "工具条在窗口自己的内容区里，每页各有一条")
            XCTAssertFalse(member.titlebarAccessoryViewControllers.contains { $0.view === toolbar })
        }
        XCTAssertTrue(window.toolbarView !== tab.toolbarView)
        XCTAssertGreaterThanOrEqual(tab.tabbedWindows?.count ?? 1, 2)
    }

    private func frameInWindow(_ pane: PaneTerminalView) -> NSRect {
        pane.superview!.convert(pane.superview!.bounds, to: nil)
    }

    func testDefaultLayoutIsThreePanesLeftStackedRightFullHeight() async throws {
        let controller = controller(["-f", "-i"])
        controller.layoutOverride = nil
        let window = controller.newWindow()
        XCTAssertEqual(window.panes.count, 3, "一个窗口三个窗格")
        XCTAssertEqual(Set(window.panes.map { $0.process.shellPid }).count, 3, "每个窗格是独立的 shell")
        window.contentView?.layoutSubtreeIfNeeded()
        let (topLeft, bottomLeft, right) = (frameInWindow(window.panes[0]), frameInWindow(window.panes[1]), frameInWindow(window.panes[2]))
        XCTAssertEqual(topLeft.minX, bottomLeft.minX, accuracy: 1, "左边两格同一列")
        XCTAssertGreaterThan(topLeft.minY, bottomLeft.minY, "第一格在上，第二格在下")
        XCTAssertGreaterThan(right.minX, topLeft.maxX - 1, "第三格在右边")
        XCTAssertEqual(right.height, topLeft.height + bottomLeft.height, accuracy: 6, "右边一栏占满整个高度")
        XCTAssertEqual(topLeft.height, bottomLeft.height, accuracy: 6, "左边上下大致各一半")
        XCTAssertLessThan(topLeft.width, right.width, "右栏比左栏宽")
    }

    func testSingleLayoutAndNewTabsFollowTheLayoutSetting() async throws {
        let controller = controller(["-f", "-i"])
        controller.layoutOverride = .single
        XCTAssertEqual(controller.newWindow().panes.count, 1)
        controller.layoutOverride = .threePanes
        XCTAssertEqual(controller.newTab().panes.count, 3, "新标签页也是三窗格")
    }

    func testFocusMovesBetweenPanesAndExitedPaneIsRemovedWhileOthersFillIn() async throws {
        let controller = controller(["-f", "-i"])
        controller.layoutOverride = .threePanes
        let window = controller.newWindow()
        XCTAssertTrue(window.terminal === window.panes[0])
        controller.selectPane(1)
        XCTAssertTrue(window.terminal === window.panes[1], "⌘] 切到下一个窗格")
        controller.selectPane(-1)
        controller.selectPane(-1)
        XCTAssertTrue(window.terminal === window.panes[2], "到头后循环")
        let leaving = window.panes[0]
        leaving.send(txt: "exit\n")
        await wait(5) { window.panes.count == 2 }
        XCTAssertEqual(window.panes.count, 2, "只拿掉输入 exit 的那个窗格")
        XCTAssertNil(leaving.superview?.superview, "已从界面上移除")
        XCTAssertTrue(window.isVisible, "还有窗格时窗口保留")
        XCTAssertNotNil(window.terminal)
        // 其余窗格都结束后，窗口才关闭。
        window.panes.forEach { $0.send(txt: "exit\n") }
        await wait(5) { controller.windows.isEmpty }
        XCTAssertTrue(controller.windows.isEmpty)
    }

    func testBusyAnywhereInTheWindowCountsAndClosingIsProtected() async throws {
        let controller = controller(["-f", "-i"])
        controller.layoutOverride = .threePanes
        let window = controller.newWindow()
        await wait(5) { !text(of: window).isEmpty }
        XCTAssertFalse(controller.isBusy(window))
        window.panes[2].send(txt: "sleep 30\n")
        await wait(5) { controller.isBusy(window) }
        XCTAssertTrue(controller.isBusy(window), "任一窗格有程序在运行（比如右边在和 agent 对话）就要确认")
        controller.confirmClose = { _ in false }
        XCTAssertFalse(controller.windowShouldClose(window))
    }

    func testSplitRightAndDownBuildTheRequestedGridAndNewPaneInheritsDirectory() async throws {
        let controller = controller(["-f", "-i"])
        controller.layoutOverride = .single
        let window = controller.newWindow()
        let first = window.panes[0]
        first.send(txt: "cd /tmp\n")
        await wait(5) { ShellProcessInfo.currentDirectory(of: first.process.shellPid)?.hasSuffix("/tmp") == true }
        let right = try XCTUnwrap(controller.splitPane(sideBySide: true))
        XCTAssertEqual(window.panes.count, 2)
        XCTAssertTrue(window.terminal === right, "新窗格获得焦点")
        window.contentView?.layoutSubtreeIfNeeded()
        let (a, b) = (frameInWindow(first), frameInWindow(right))
        XCTAssertGreaterThan(b.minX, a.maxX - 1, "向右分栏：新窗格在右边")
        XCTAssertEqual(a.width, b.width, accuracy: 8, "各占一半")
        XCTAssertEqual(a.height, b.height, accuracy: 1)
        await wait(5) { ShellProcessInfo.currentDirectory(of: right.process.shellPid)?.hasSuffix("/tmp") == true }
        XCTAssertEqual(ShellProcessInfo.currentDirectory(of: right.process.shellPid)?.hasSuffix("/tmp"), true, "新窗格从当前窗格所在目录开始")
        // 再把右边向下分：右栏上下两格，左边仍是整栏。
        let rightBottom = try XCTUnwrap(controller.splitPane(sideBySide: false))
        window.contentView?.layoutSubtreeIfNeeded()
        let (left, rt, rb) = (frameInWindow(first), frameInWindow(right), frameInWindow(rightBottom))
        XCTAssertEqual(window.panes.count, 3)
        XCTAssertGreaterThan(rt.minY, rb.minY, "右上在右下上面")
        XCTAssertEqual(rt.minX, rb.minX, accuracy: 1)
        XCTAssertEqual(left.height, rt.height + rb.height, accuracy: 8, "左边仍占满整个高度")
        // 在左边向下分，得到左上下、右上下的四格。
        window.makeFirstResponder(first)
        let leftBottom = try XCTUnwrap(controller.splitPane(sideBySide: false))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.panes.count, 4)
        XCTAssertEqual(frameInWindow(first).minX, frameInWindow(leftBottom).minX, accuracy: 1)
        XCTAssertGreaterThan(frameInWindow(first).minY, frameInWindow(leftBottom).minY)
    }

    func testSameDirectionSplitsShareOneRowAndTooSmallPanesRefuseToSplit() async throws {
        let controller = controller(["-f", "-i"])
        controller.layoutOverride = .single
        let window = controller.newWindow()
        // 窗口大小会被自动保存，固定成足够宽，不受之前运行的影响。
        window.setContentSize(NSSize(width: 1000, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        _ = controller.splitPane(sideBySide: true)
        _ = controller.splitPane(sideBySide: true)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.panes.count, 3)
        let xs = window.panes.map { frameInWindow($0).minX }
        XCTAssertEqual(xs, xs.sorted(), "连续向右分栏，窗格依次排成一行")
        // 把窗口压窄后，最右边的窗格太窄，不再继续分。
        window.setContentSize(NSSize(width: 460, height: 400))
        window.contentView?.layoutSubtreeIfNeeded()
        let before = window.panes.count
        _ = controller.splitPane(sideBySide: true)
        XCTAssertEqual(window.panes.count, before, "窗格太窄时拒绝再分")
    }

    func testClosingAPaneCollapsesTheLayoutAndLastPaneClosesTheWindow() async throws {
        let controller = controller(["-f", "-i"])
        controller.layoutOverride = .threePanes
        let window = controller.newWindow()
        controller.closePane()   // 关掉左上
        XCTAssertEqual(window.panes.count, 2)
        window.contentView?.layoutSubtreeIfNeeded()
        let (leftBottom, right) = (frameInWindow(window.panes[0]), frameInWindow(window.panes[1]))
        XCTAssertGreaterThan(right.minX, leftBottom.maxX - 1)
        XCTAssertEqual(leftBottom.height, right.height, accuracy: 8, "剩下的左栏补满整个高度，不留空")
        controller.closePane()
        controller.closePane()
        XCTAssertTrue(controller.windows.isEmpty || window.panes.isEmpty, "关掉最后一个窗格就关闭窗口")
    }

    func testClosingABusyPaneAsksFirst() async throws {
        let controller = controller(["-f", "-i"])
        controller.layoutOverride = .threePanes
        let window = controller.newWindow()
        await wait(5) { !text(of: window).isEmpty }
        window.terminal.send(txt: "sleep 30\n")
        await wait(5) { controller.isBusy(window) }
        var asked = 0
        controller.confirmClose = { _ in asked += 1; return false }
        controller.closePane()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(window.panes.count, 3, "选择取消就不关")
    }

    func testHidingKeepsEverySessionAliveAndShowBringsThemBack() async throws {
        let controller = controller(["-c", "sleep 8"])
        let a = controller.newWindow()
        let b = controller.newWindow()
        controller.hide()
        await wait(3) { !a.isVisible && !b.isVisible }
        XCTAssertFalse(a.isVisible)
        XCTAssertFalse(b.isVisible)
        XCTAssertEqual(controller.windows.count, 2, "收起后 shell 仍在运行，没有新开")
        let before = Set(controller.windows.map { ObjectIdentifier($0) })
        controller.show()
        XCTAssertTrue(a.isVisible || b.isVisible)
        XCTAssertEqual(Set(controller.windows.map { ObjectIdentifier($0) }), before, "再次打开的是同一批终端")
    }

    func testHidingTerminalsHandsFocusToTheMainWindowAndNeverHidesTheApp() async throws {
        let controller = controller(["-c", "sleep 8"])
        let main = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.orderFront(nil)
        addTeardownBlock { @MainActor in main.close() }
        controller.handoffWindow = { main.isVisible ? main : nil }
        let shell = controller.newWindow()
        XCTAssertTrue(controller.visibleWindow === shell)

        controller.hide()
        await wait(3) { !shell.isVisible }
        XCTAssertFalse(shell.isVisible, "终端收起")
        XCTAssertTrue(main.isVisible, "主窗口不受影响，仍然开着")
        XCTAssertEqual(main.alphaValue, 1)
        XCTAssertNil(controller.visibleWindow, "没有可见终端时没有可交接的窗口")
    }

    func testPreviousAppIsSharedAndOnlyConsumedWhenNothingElseIsOpen() throws {
        let other = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in other.close(); PreviousApp.app = nil }
        PreviousApp.app = NSRunningApplication.current
        PreviousApp.restore(handoff: other)
        XCTAssertTrue(other.isVisible, "有别的 Timeline 窗口时交给它")
        XCTAssertNotNil(PreviousApp.app, "交接不消耗「刚才的应用」，等最后一组窗口收起时才回去")
    }

    func testTypingExitClosesThatTerminalAndNextShowStartsAFreshOne() async throws {
        let controller = controller(["-c", "exit 0"])
        controller.show()
        await wait(5) { controller.windows.isEmpty }
        XCTAssertTrue(controller.windows.isEmpty, "shell 结束后关闭窗口")
        controller.arguments = ["-c", "sleep 3"]
        controller.show()
        XCTAssertEqual(controller.windows.count, 1)
    }

    func testClosedPanesAreReapedInsteadOfLeftAsZombiesAndKeepLongScrollback() async throws {
        let controller = controller(["-f", "-i"])
        controller.layoutOverride = .threePanes
        let window = controller.newWindow()
        XCTAssertEqual(window.panes.first?.getTerminal().options.scrollback, PaneTerminalView.scrollbackLines)
        let pids = window.panes.compactMap { $0.process?.shellPid }.filter { $0 > 0 }
        XCTAssertEqual(pids.count, 3)
        controller.closePane()
        controller.closePane()
        controller.closePane()
        func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }
        // 被回收后 pid 不再存在；僵尸进程在回收前对 kill(pid, 0) 仍返回 0。
        await wait(2) { !pids.contains(where: alive) }
        XCTAssertFalse(pids.contains(where: alive), "关闭的窗格必须回收子进程，不能留下僵尸")
    }
}
