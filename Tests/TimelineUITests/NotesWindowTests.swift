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
        // 用滚轮事件往上滚（像用户那样），SwiftUI 才会把它当成当前位置记住。
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 2000, wheel2: 0, wheel3: 0))
        scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
        let bottom = scroll.contentView.bounds.origin
        for _ in 0..<20 where scroll.contentView.bounds.origin == bottom {
            try await Task.sleep(nanoseconds: 50_000_000)
            host.layoutSubtreeIfNeeded()
        }
        let position = scroll.contentView.bounds.origin
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

    /// 主窗口和笔记互斥：笔记出现前请主窗口收起；主窗口出现时笔记关掉，且不把焦点交还给之前的应用。
    func testNotesAndMainWindowTakeTurns() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let main = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.orderFront(nil)
        let controller = NotesWindowController()
        Self.keepAlive += [main, controller]
        controller.willShow = { main.orderOut(nil) }
        var handedOff = 0
        controller.handoffWindow = { handedOff += 1; return nil }

        controller.show(store: store, taskID: nil, reveal: { _ in }, openDay: { _ in })
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(main.isVisible, "笔记出现时主窗口收起")

        main.orderFront(nil)
        controller.closeForMain()
        XCTAssertFalse(window.isVisible, "主窗口出现时笔记关掉")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(handedOff, 0, "为主窗口让路时不交还焦点")

        controller.openTag("Work", log: nil)
        XCTAssertTrue(window.isVisible, "已经建好的笔记窗口直接打开标签")
        XCTAssertEqual(controller.workspace.mode, .notes)
        XCTAssertFalse(main.isVisible)
        controller.close()
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
