import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class NotesWindowTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    func testSwitchingModesRetainsTheEditorsAndJournalScrollPosition() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let day = Date()
        let task = try XCTUnwrap(store.addParsedTodo("Read", on: day))
        for index in 0..<80 { _ = try store.quickLog("Journal \(index)", taskID: task.id, on: day) }
        let workspace = NotesWorkspaceNavigation()
        workspace.open(.journal, date: day)
        let nav = NotesNavigation()
        nav.open(task: task.id)
        let host = NSHostingView(rootView: UnifiedNotesView(store: store, workspace: workspace, nav: nav, close: {}, reveal: { _ in }, openDay: { _ in }))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func views<T: NSView>(_ root: NSView, type: T.Type) -> [T] {
            ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views($0, type: type) }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(views(host, type: ImagePasteTextView.self).first { !$0.isHiddenOrHasHiddenAncestor })
        let scroll = try XCTUnwrap(views(host, type: NSScrollView.self).filter { !$0.isHiddenOrHasHiddenAncestor }
            .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        // 首次 layout 才触发今天的 scrollTo(bottom)；先让这次初始定位落定，避免覆盖测试滚动。
        var stable = 0
        var previous = scroll.contentView.bounds
        for _ in 0..<40 where stable < 3 {
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            let current = scroll.contentView.bounds
            stable = current == previous ? stable + 1 : 0
            previous = current
        }
        XCTAssertEqual(stable, 3, "初始页面定位必须先完成")
        // 这里验证保留视图的滚动状态，而非未绑定窗口的合成滚轮事件分发。
        // 直接通过原生 clip view 滚动，并等待 SwiftUI 读到新的可见区域。
        let bottom = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: NSPoint(x: bottom.x, y: max(0, bottom.y - 2000)))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let position = scroll.contentView.bounds.origin
        XCTAssertLessThan(position.y, bottom.y - 100, "测试必须确实滚离原位置")
        XCTAssertLessThan(position.y, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height - 100, "已经离开底部")
        for _ in 0..<3 {
            workspace.mode = .notes
            try await Task.sleep(nanoseconds: 30_000_000)
            host.layoutSubtreeIfNeeded()
            workspace.mode = .journal
            try await Task.sleep(nanoseconds: 30_000_000)
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(views(host, type: ImagePasteTextView.self).contains { $0 === editor })
            XCTAssertEqual(scroll.contentView.bounds.origin, position)
        }

    }

    func testGlobalShortcutBringsOffSpaceOrBackgroundWindowForwardInsteadOfClosingIt() {
        for active in [true, false] {
            for key in [true, false] {
                XCTAssertEqual(NotesHotKeyAction.resolve(appWasActive: active, visible: true,
                                                        onActiveSpace: false, isKey: key, miniaturized: false), .bringForward)
            }
        }
        XCTAssertEqual(NotesHotKeyAction.resolve(appWasActive: false, visible: true,
                                                onActiveSpace: true, isKey: true, miniaturized: false), .bringForward)
        XCTAssertEqual(NotesHotKeyAction.resolve(appWasActive: true, visible: true,
                                                onActiveSpace: true, isKey: false, miniaturized: false), .bringForward)
        XCTAssertEqual(NotesHotKeyAction.resolve(appWasActive: true, visible: true,
                                                onActiveSpace: true, isKey: true, miniaturized: false), .close)
        XCTAssertEqual(NotesHotKeyAction.resolve(appWasActive: true, visible: false,
                                                onActiveSpace: false, isKey: false, miniaturized: false), .open)
        XCTAssertEqual(NotesHotKeyAction.resolve(appWasActive: true, visible: true,
                                                onActiveSpace: true, isKey: true, miniaturized: true), .bringForward)
    }

    func testBothModesAndReopenedWindowUseCurrentSpaceAndPreserveNavigation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let date = JournalDates.calendar.startOfDay(for: Date()).addingTimeInterval(-86400)
        let controller = NotesWindowController()
        Self.keepAlive.append(controller)
        defer { controller.close() }
        controller.showJournal(store: store, date: date)
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces))
        controller.bringToFront()
        XCTAssertTrue(controller.window === window)
        XCTAssertEqual(controller.workspace.mode, .journal)
        XCTAssertEqual(controller.journalDate, date)
        window.orderOut(nil)
        XCTAssertFalse(controller.isVisible)
        controller.bringToFront()
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.workspace.mode, .journal)
        XCTAssertEqual(controller.journalDate, date)
        controller.close()
        controller.show(store: store, taskID: nil, reveal: { _ in }, openDay: { _ in })
        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertEqual(controller.workspace.mode, .notes)
    }

    func testJournalReusedWindowRendersTheRequestedDateAfterNotesAndOtherDates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let first = JournalDates.calendar.startOfDay(for: Date())
        let second = JournalDates.calendar.date(byAdding: .day, value: -5, to: first)!
        _ = try store.quickLog("Journal marker FIRST", linkDefault: false, on: first)
        _ = try store.quickLog("Journal marker SECOND", linkDefault: false, on: second)
        let controller = NotesWindowController()
        Self.keepAlive.append(controller)
        defer { controller.close() }
        controller.show(store: store, taskID: nil, reveal: { _ in }, openDay: { _ in })
        let window = try XCTUnwrap(controller.window)

        func renderedSources(_ view: NSView) -> [String] {
            if let text = view as? InteractiveTaskText, let source = text.source { return [source] }
            return view.subviews.flatMap(renderedSources)
        }
        for (date, marker) in [(first, "FIRST"), (second, "SECOND"), (first, "FIRST")] {
            controller.showJournal(store: store, date: date.addingTimeInterval(3600))
            try await Task.sleep(nanoseconds: 80_000_000)
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertTrue(controller.window === window)
            XCTAssertEqual(controller.workspace.mode, .journal)
            XCTAssertEqual(controller.journalDate, date)
            let sources = renderedSources(try XCTUnwrap(window.contentView))
            XCTAssertTrue(sources.contains("Journal marker \(marker)"), "Requested day must reach the actual rendered journal: \(sources)")
        }
        controller.setDate(second)
        try await Task.sleep(nanoseconds: 80_000_000)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(renderedSources(try XCTUnwrap(window.contentView)).contains("Journal marker SECOND"))
    }

    func testNotesIsAnIndependentResizableWindowThatHidingTheMainWindowDoesNotTouch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let main = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.orderFront(nil)
        let controller = NotesWindowController()
        Self.keepAlive += [main, controller]

        controller.show(store: store, taskID: nil, reveal: { _ in }, openDay: { _ in })
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.styleMask.contains(.resizable), "笔记窗口可以调整大小")
        XCTAssertFalse(window.styleMask.contains(.closable), "没有关闭按钮")
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertTrue(window.standardWindowButton(button)?.isHidden ?? true, "红绿灯都隐藏")
        }
        XCTAssertTrue(window.isVisible)
        XCTAssertNil(window.parent, "不是主窗口的子窗口")
        XCTAssertFalse(main.childWindows?.contains(window) == true)
        XCTAssertFalse(WindowFade.family(of: main).contains(window), "主窗口淡出、收起时不带上笔记")

        // 收起主窗口（⌃⌥D 做的事）：笔记照常开着，而且没有变透明。
        WindowFade.animate(main, to: 0, duration: 0.01)
        main.orderOut(nil)
        WindowFade.reset(main)
        XCTAssertTrue(window.isVisible, "主窗口收起后笔记还在")
        XCTAssertEqual(window.alphaValue, 1)
        main.orderFront(nil)
        XCTAssertTrue(window.isVisible)

        controller.show(store: store, taskID: nil, reveal: { _ in }, openDay: { _ in })
        XCTAssertTrue(controller.window === window, "再次打开复用同一个窗口")

        // 反过来：关闭笔记不影响主窗口。
        window.cancelOperation(nil)
        XCTAssertFalse(window.isVisible, "Esc 关闭")
        XCTAssertTrue(main.isVisible, "关闭笔记不影响主窗口")
        controller.show(store: store, taskID: nil, reveal: { _ in }, openDay: { _ in })
        XCTAssertTrue(window.isVisible)
        controller.close()
    }

    /// 和主界面共用一个窗口：笔记页放进同一个窗口，两页互斥；切走再切回来，各页的键盘焦点还在原处。
    func testNotesShareTheMainWindowAndTakeTurnsWithTheMainPage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let host = FakeNotesHost()
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        let main = NSView(frame: .zero)
        main.addSubview(field)
        host.pages.setMain(main)
        let controller = NotesWindowController()
        controller.host = host
        Self.keepAlive += [host, controller]
        XCTAssertNil(controller.window, "还没打开过笔记")
        XCTAssertTrue(host.window.makeFirstResponder(field))

        controller.show(store: store, taskID: nil, reveal: { _ in }, openDay: { _ in })
        XCTAssertTrue(controller.window === host.window, "笔记页在主窗口里，不另开窗口")
        XCTAssertTrue(host.pages.showsNotes)
        XCTAssertTrue(main.isHidden, "主界面藏起来")
        XCTAssertTrue(controller.isVisible)
        XCTAssertFalse((host.window.firstResponder as? NSView)?.isDescendant(of: main) == true, "打字不会落进藏起来的主界面")

        host.pages.show(notes: false)
        XCTAssertFalse(controller.isVisible, "切回主界面后笔记不算开着")
        XCTAssertFalse(controller.isKey)
        let editor = host.window.firstResponder as? NSTextView
        XCTAssertTrue(editor?.delegate === field, "主界面的焦点还在原来的文字框")
        controller.close()
        XCTAssertEqual(host.dismissed, 0, "笔记页不在前面时关笔记不收起窗口")

        controller.openTag("Work", log: nil)
        XCTAssertTrue(host.pages.showsNotes, "已经建好的笔记页直接切过来")
        XCTAssertEqual(controller.workspace.mode, .notes)
        controller.close()
        XCTAssertEqual(host.dismissed, 1, "笔记页在前面时关笔记收起整个窗口")
        host.window.orderOut(nil)
    }

    func testToggleOpensThenClosesAndKeepsSizeAcrossToggles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let controller = NotesWindowController()
        Self.keepAlive += [controller]
        let toggle = { controller.toggle(store: store, taskID: nil, reveal: { _ in }, openDay: { _ in }) }
        toggle()
        XCTAssertTrue(controller.isVisible, "第一次按下打开")
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 900, height: 600))
        toggle()
        XCTAssertFalse(controller.isVisible, "再按一次关闭")
        toggle()
        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(controller.window === window)
        XCTAssertEqual(window.contentLayoutRect.width, 900, accuracy: 1, "重新打开时大小不变")
        controller.close()
    }
}

/// 测试用的主窗口：两页叠在一个隐藏窗口里。
@MainActor
private final class FakeNotesHost: NotesHost {
    let pages = WorkspacePagesView()
    let window: NSWindow
    var dismissed = 0

    init() {
        window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pages
    }

    var hostWindow: NSWindow { window }
    var showsNotes: Bool { pages.showsNotes }
    func installNotes(_ view: NSView) { pages.setNotes(view) }
    func presentNotes() { pages.show(notes: true); window.orderFront(nil) }
    func dismissNotes() { dismissed += 1 }
}
