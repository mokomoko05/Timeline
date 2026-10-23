import AppKit
import Combine
import SwiftUI
import UserNotifications
import WebKit
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class PerformanceAuditTests: XCTestCase {
    func testTemporaryTextMeasurersAndTheirTextKitStacksAreReleased() {
        _ = NSApplication.shared
        weak var measurer: TextMeasurer?
        weak var input: InputHeightMeasurer?
        weak var storage: NSTextStorage?
        weak var manager: NSLayoutManager?
        weak var container: NSTextContainer?
        for _ in 0..<100 {
            autoreleasepool {
                let temporary = TextMeasurer()
                measurer = temporary
                // Observe the independently owned TextKit stack without extending its lifetime.
                for child in Mirror(reflecting: temporary).children {
                    if let value = child.value as? NSTextStorage { storage = value }
                    if let value = child.value as? NSLayoutManager { manager = value }
                    if let value = child.value as? NSTextContainer { container = value }
                }
                temporary.update(NSAttributedString(string: "测量文字\nSecond line", attributes: [.font: NSFont.systemFont(ofSize: 13)]), maxLines: 3)
                XCTAssertGreaterThan(temporary.height(forWidth: 120), 0)
                let sizing = InputHeightMeasurer()
                input = sizing
                _ = sizing.height(for: "Input", font: .systemFont(ofSize: 13), width: 100, minHeight: 20, maxLines: 3)
            }
            XCTAssertNil(measurer)
            XCTAssertNil(input)
            XCTAssertNil(storage)
            XCTAssertNil(manager)
            XCTAssertNil(container)
        }
    }

    private func store() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory)
    }

    private func defaults() -> UserDefaults {
        let suite = "performance-audit-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testCreateNotebookTagThroughPopoverWithPersistentNavigation() async throws {
        _ = NSApplication.shared
        let store = store()
        let nav = NotesNavigation(defaults: defaults())
        let host = NSHostingView(rootView: NotesView(store: store, nav: nav, reveal: { _ in }, openDay: { _ in }))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        for name in ["会议", "论文/设计", "空白标签"] {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: CreateNotebookTagView(store: store, cancel: { popover.close() }, created: { tag in
                nav.open(tag: tag)
                popover.close()
            }))
            popover.show(relativeTo: NSRect(x: 210, y: 90, width: 24, height: 22), of: host, preferredEdge: .maxY)
            popover.contentViewController?.view.window?.alphaValue = 0
            defer { popover.close(); popover.contentViewController = nil }
            try await Task.sleep(for: .milliseconds(150))
            func input(_ root: NSView) -> NSTextField? {
                if let field = root as? NSTextField, field.isEditable, field.placeholderString == "标签名称" { return field }
                return root.subviews.lazy.compactMap(input).first
            }
            let field = try XCTUnwrap(NSApp.windows.filter(\.isVisible).compactMap { $0.contentView.flatMap(input) }.first)
            let popup = try XCTUnwrap(field.window)
            popup.makeFirstResponder(field)
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.selectAll(nil)
            editor.insertText(name, replacementRange: editor.selectedRange())
            let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: popup.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            popup.sendEvent(enter)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(nav.tagSelection, name)
            XCTAssertTrue(store.allTags().contains { $0.name == name })
        }
    }

    func testFloatingWindowControllersDoNotRetainThemselvesThroughRootBuilders() async throws {
        _ = NSApplication.shared
        let store = store()
        weak var focus: FocusPanelController?
        weak var board: BoardWindowController?
        weak var viewer: ImageViewerController?
        autoreleasepool {
            let controller = FocusPanelController(session: FocusSession(), defaults: defaults())
            focus = controller
            controller.toggleWorkspace()
            controller.toggleWorkspace()
        }
        autoreleasepool {
            let controller = BoardWindowController(defaults: defaults())
            board = controller
            controller.show(store: store)
            controller.hide()
            controller.panel?.close()
        }
        autoreleasepool {
            let controller = ImageViewerController()
            viewer = controller
            controller.show(store: store, names: ["missing.png"], index: 0)
            controller.close()
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(focus)
        XCTAssertNil(board)
        XCTAssertNil(viewer)
    }

    func testLoginCommandTimeoutDoesNotBlockMainActor() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        let start = Date()
        let command = Task.detached { try LoginItem.runProcess(process, timeout: 0.1) }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "Main actor must be available while the command runs")
        do {
            _ = try await command.value
            XCTFail("A stalled command must time out")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("超时"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testBuildingNotesWithSharedNavigationDoesNotPublishDuringLayout() {
        let store = store()
        let nav = NotesNavigation(defaults: defaults())
        var publications = 0
        let subscription = nav.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        for _ in 0..<20 {
            _ = NotesView(store: store, nav: nav, reveal: { _ in }, openDay: { _ in })
            nav.validate(in: store)
        }
        XCTAssertEqual(publications, 0, "Constructing a child must not invalidate the observing parent")
        nav.open(tag: "会议")
        let changed = publications
        nav.open(tag: "会议")
        XCTAssertEqual(publications, changed, "Selecting the current tag must not restart layout")
    }

    func testUnrelatedPreferencesDoNotShowOrMoveFocusPanel() async throws {
        _ = NSApplication.shared
        let defaults = defaults()
        let session = FocusSession()
        let controller = FocusPanelController(session: session, defaults: defaults)
        let before = Set(NSApp.windows.map(\.windowNumber))
        controller.toggleWorkspace()
        let panel = try XCTUnwrap(NSApp.windows.first { !before.contains($0.windowNumber) && $0 is NSPanel })
        defer { panel.close() }
        try await Task.sleep(for: .milliseconds(150))
        let frame = panel.frame
        // If any unrelated notification calls showPanel again, the panel becomes visible.
        panel.orderOut(nil)
        let nav = NotesNavigation(defaults: defaults)
        for index in 0..<20 {
            nav.open(tag: "测试/\(index)")
            nav.query = "搜索 \(index)"
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.frame, frame)
        defaults.set(true, forKey: Prefs.focusPanelHidden)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        try await Task.sleep(for: .milliseconds(50))
        defaults.set(false, forKey: Prefs.focusPanelHidden)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(panel.isVisible, "The actual visibility preference must still work")
    }

    func testReminderPlansIgnoreDraftsAndLogsButTrackTaskChanges() async throws {
        let store = store()
        let day = Date().addingTimeInterval(86400 * 10)
        let task = try XCTUnwrap(store.addParsedTodo("提醒测试", on: day))
        var updates: [[ReminderPlan]] = []
        let subscription = ReminderScheduler.planChanges(in: store).sink { updates.append($0) }
        defer { subscription.cancel() }
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(updates.count, 1)
        _ = try store.quickLog("日志不改变提醒", on: day)
        store.setLogDraft("输入中的草稿", on: day)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(updates.count, 1)
        store.updateTodo(task.id, scheduledDate: day, dueDate: day, dueHasTime: true, reminderMinutes: 10, repeatRule: task.task.repeatRule)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates.last?.count, 1)
        _ = try store.quickLog("有提醒的情况下仍不重排", on: day)
        store.setLogDraft("继续输入", on: day)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(updates.count, 2)
        store.renameTodo(task.id, title: "修改提醒内容", on: day)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(updates.count, 3)
        let plan = try XCTUnwrap(updates.last?.first)
        let content = UNMutableNotificationContent()
        content.body = plan.title
        content.categoryIdentifier = ReminderScheduler.category
        content.userInfo = ["day": plan.dayKey, "task": plan.taskID.uuidString]
        let components = JournalDates.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: plan.fireDate)
        let request = UNNotificationRequest(identifier: plan.id, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        XCTAssertTrue(ReminderScheduler.matches(request, plan: plan))
        content.body = "过期的内容"
        let stale = UNNotificationRequest(identifier: plan.id, content: content, trigger: request.trigger)
        XCTAssertFalse(ReminderScheduler.matches(stale, plan: plan))
    }

    func testBoardCacheEvictionAndOwnerReleaseFreeSessionsAndWebViews() async throws {
        let store = store()
        var nav: BoardNavigation? = BoardNavigation(defaults: defaults())
        weak var firstSession: BoardLiveEditorSession?
        weak var firstWebView: WKWebView?
        for index in 0..<8 {
            let board = try XCTUnwrap(store.ensureBoard(for: .tag("缓存/\(index)")))
            autoreleasepool {
                let session = nav!.editorSession(for: board, store: store)
                let view = session.makeWebView()
                if index == 0 { firstSession = session; firstWebView = view }
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(firstSession, "Evicted sessions must leave the cache")
        XCTAssertNil(firstWebView, "The script handler must not retain its WebView")
        weak var lastSession: BoardLiveEditorSession?
        autoreleasepool {
            lastSession = nav!.editorSession(for: store.boards.last!, store: store)
        }
        nav = nil
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(lastSession)
    }
}
