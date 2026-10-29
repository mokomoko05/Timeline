import AppKit
import XCTest
import SwiftUI
@testable import Timeline

@MainActor
final class WorkspaceTerminalTests: XCTestCase {
    func testTerminalSharesFrameAndKeepsProcessesAndFocusAcrossPagesAndClose() throws {
        let window = MainWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.keepsCentered = false
        let pages = WorkspacePagesView()
        let main = WorkspaceResponderView()
        pages.setMain(main)
        window.contentView = pages
        let shell = ShellWindowController()
        shell.arguments = ["-f", "-i"]
        shell.layoutOverride = .threePanes
        shell.workspaceWindow = window
        shell.installWorkspaceContent = { pages.setTerminal($0) }
        shell.presentWorkspace = { pages.show(.terminal); window.makeKeyAndOrderFront(nil) }
        shell.finishWorkspace = { pages.show(.main) }
        defer { shell.terminateAll(); window.close() }
        let originalFrame = window.frame
        shell.show()
        XCTAssertTrue(shell.windows.first === window)
        XCTAssertEqual(window.frame, originalFrame)
        XCTAssertEqual(window.panes.count, 3)
        let pids = window.panes.map { $0.process.shellPid }
        shell.selectPane(1)
        let focused = window.focusedPane
        pages.show(.main)
        XCTAssertFalse(shell.isTerminal(window))
        XCTAssertTrue(pages.terminal?.isHidden == true)
        _ = window.makeFirstResponder(main)
        window.setFrame(NSRect(x: 250, y: 230, width: 800, height: 570), display: false)
        let resizedFrame = window.frame
        pages.show(.terminal)
        XCTAssertTrue(window.firstResponder === focused)
        XCTAssertEqual(window.frame, resizedFrame)
        window.close()
        shell.show()
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.panes.map { $0.process.shellPid }, pids, "关闭共用窗口只收起，不结束 shell")
        XCTAssertEqual(window.frame, resizedFrame)
        pages.show(.main)
        XCTAssertTrue(window.firstResponder === main)
        XCTAssertFalse(shell.isTerminal(window))
    }

    func testTerminalToolbarRemainsBelowTitlebarAndReceivesClicksAfterPageSwitchAndResize() throws {
        let window = MainWindow(contentRect: NSRect(x: 200, y: 200, width: 1280, height: 820),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.keepsCentered = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = true
        }
        let pages = WorkspacePagesView()
        window.contentView = pages
        pages.setMain(NSView())
        let shell = ShellWindowController()
        shell.arguments = ["-f", "-i"]
        shell.layoutOverride = .threePanes
        shell.workspaceWindow = window
        shell.installWorkspaceContent = { pages.setTerminal($0) }
        shell.presentWorkspace = { pages.show(.terminal); window.orderFront(nil) }
        defer { shell.terminateAll(); window.close() }
        shell.show()
        let toolbar = try XCTUnwrap(window.toolbarView)
        let root = try XCTUnwrap(window.contentView?.superview)
        let originalFrame = window.frame
        for size in [NSSize(width: 1280, height: 820), NSSize(width: 640, height: 560), NSSize(width: 1000, height: 700)] {
            pages.show(.main)
            window.setFrame(NSRect(origin: originalFrame.origin, size: size), display: false)
            pages.show(.terminal)
            window.contentView?.layoutSubtreeIfNeeded()
            let toolbarRect = toolbar.convert(toolbar.bounds, to: nil)
            XCTAssertLessThanOrEqual(toolbarRect.maxY, window.contentLayoutRect.maxY + 0.5,
                                     "终端工具栏不能进入覆盖内容的原生标题栏")
            XCTAssertEqual(toolbarRect.height, 28, accuracy: 0.5)
            let center = root.convert(NSPoint(x: 30, y: toolbarRect.midY), from: nil)
            let hit = try XCTUnwrap(root.hitTest(center))
            XCTAssertTrue(hit === toolbar || hit.isDescendant(of: toolbar), "新标签页按钮位置必须收到点击")
        }
    }

    func testExitingLastEmbeddedPaneReturnsToMainAndNextShowCreatesFreshShell() async throws {
        let window = MainWindow(contentRect: NSRect(x: 200, y: 200, width: 800, height: 600),
                                styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let pages = WorkspacePagesView()
        pages.setMain(NSView())
        window.contentView = pages
        let shell = ShellWindowController()
        shell.arguments = ["-c", "exit 0"]
        shell.layoutOverride = .single
        shell.workspaceWindow = window
        shell.installWorkspaceContent = { pages.setTerminal($0) }
        shell.presentWorkspace = { pages.show(.terminal); window.orderFront(nil) }
        shell.finishWorkspace = { pages.show(.main) }
        defer { shell.terminateAll(); window.close() }
        shell.show()
        let deadline = Date().addingTimeInterval(3)
        while !shell.windows.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(shell.windows.isEmpty)
        XCTAssertEqual(pages.page, .main)
        XCTAssertTrue(window.isVisible)
        shell.arguments = ["-f", "-i"]
        shell.show()
        XCTAssertTrue(shell.windows.first === window)
        XCTAssertFalse(window.ended)
        XCTAssertEqual(window.panes.count, 1)
    }

    func testSavedPageChangesWithShortcutsAndKeepsTerminalWhenWindowCloses() {
        let defaults = InMemoryDefaults()
        let window = MainWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 650),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let pages = WorkspacePagesView(defaults: defaults)
        window.contentView = pages
        pages.setMain(NSHostingView(rootView: Text("Main").frame(maxWidth: .infinity, maxHeight: .infinity)))
        pages.setNotes(NSView())
        pages.setTerminal(NSView())
        XCTAssertEqual(pages.savedPage, .main)
        window.orderFront(nil)
        let frame = window.frame
        for page: WorkspacePage in [.terminal, .main, .notes, .terminal] {
            pages.show(page)
            XCTAssertEqual(pages.savedPage, page)
            XCTAssertEqual(window.frame, frame)
        }
        window.close()
        XCTAssertEqual(WorkspacePagesView(defaults: defaults).savedPage, .terminal)
        window.orderFront(nil)
        XCTAssertEqual(pages.page, .terminal)
        XCTAssertEqual(window.frame, frame)
    }

    func testShellCaretUpdatesCannotRestorePointerButPageSwitchDoes() throws {
        let window = MainWindow(contentRect: NSRect(x: 200, y: 200, width: 800, height: 600),
                                styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { TerminalPointerHiding.shared.restore(); window.close() }
        let pages = WorkspacePagesView()
        pages.setMain(NSView())
        let terminal = PaneTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        pages.setTerminal(terminal)
        window.panes = [terminal]
        window.contentView = pages
        pages.show(.terminal)
        XCTAssertTrue(window.makeFirstResponder(terminal))
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x",
            isARepeat: false, keyCode: 7))
        window.sendEvent(key)
        XCTAssertTrue(TerminalPointerHiding.shared.hidden)
        for _ in 0..<20 {
            terminal.feed(text: "\u{1b}[?25lrefresh\u{1b}[?25h")
            terminal.resetCursorRects()
        }
        XCTAssertTrue(TerminalPointerHiding.shared.hidden, "shell 重画插入点不能解除指针隐藏")
        pages.show(.main)
        XCTAssertFalse(TerminalPointerHiding.shared.hidden)
    }

    func testTypingHidesPointerOnceAndFocusLossOrPageChangeBalancesIt() {
        let window = QuietWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var changes: [Bool] = []
        let pointer = TerminalPointerHiding(setHidden: { changes.append($0) })
        for _ in 0..<100 { pointer.hide(in: window) }
        XCTAssertEqual(changes, [true])
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertEqual(changes, [true, false])
        pointer.restore()
        XCTAssertEqual(changes.count, 2)
        pointer.hide(in: window)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertEqual(changes, [true, false, true, false])
    }
}

private final class WorkspaceResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
