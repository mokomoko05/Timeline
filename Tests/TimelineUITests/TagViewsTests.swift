import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class TagViewsTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!

    private func makeStore() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory)
    }

    /// 把视图放进不可见的窗口里排版，返回它的实际大小。
    private func layout<V: View>(_ view: V, width: CGFloat, height: CGFloat = 800) -> NSSize {
        let host = NSHostingView(rootView: view.frame(width: width))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        Self.keepAlive += [window, host]
        return host.fittingSize
    }

    func testFlowLayoutWrapsChipsOntoNewRows() {
        let chips = ["项目A", "项目B", "项目C", "项目D", "项目E", "项目F"]
        let wide = layout(FlowLayout { ForEach(chips, id: \.self) { TagChip(name: $0) } }, width: 600)
        let narrow = layout(FlowLayout { ForEach(chips, id: \.self) { TagChip(name: $0) } }, width: 120)
        XCTAssertGreaterThan(wide.height, 10)
        XCTAssertGreaterThan(narrow.height, wide.height * 2, "窄了就折成多行")
    }

    func testBatchTagViewRendersForSelectedLogs() throws {
        let store = makeStore()
        _ = try store.quickLog("甲", on: day, now: day.addingTimeInterval(1))
        _ = try store.quickLog("乙", on: day, now: day.addingTimeInterval(2))
        let ids = Set(store.allLogs().map(\.log.id))
        store.updateLogTags(add: ["灵感"], forLogs: [try XCTUnwrap(ids.first)])
        let size = layout(LogBatchTagView(store: store, logIDs: ids), width: 380)
        XCTAssertGreaterThan(size.height, 100, "部分日志带有的标签也会列出来")
    }

    func testLinkPickerTagBarAndNotebookPageRender() throws {
        let store = makeStore()
        for title in ["读摘要 #论文", "看公式", "写周报"] { _ = store.addParsedTodo(title, on: day) }
        store.createTag("读书笔记")
        let picker = layout(LinkPickerView(store: store, current: nil, pick: { _ in }), width: 380)
        XCTAssertGreaterThan(picker.height, 150, "有候选时显示列表")
        for index in 0..<40 { _ = store.addParsedTodo("待办 \(index)", on: day) }
        let many = layout(LinkPickerView(store: store, current: nil, pick: { _ in }), width: 380)
        XCTAssertLessThan(many.height, 460, "待办很多时列表高度有上限，不会撑满屏幕")
        XCTAssertGreaterThan(store.linkCandidates().count, 40)
        // 关联条永远只有一行：选了很多标签、很长的待办名，高度也不变。
        var chosen: [String] = []
        let empty = layout(LogChipsBar(store: store, link: .constant(nil), unlinked: .constant(false),
                                       tags: Binding(get: { chosen }, set: { chosen = $0 }), hint: "提示"), width: 460)
        chosen = ["读书笔记", "论文", "很长很长的标签名称一二三四五六七", "另一个", "再一个", "还有一个"]
        store.pinTask(store.locate(number: 1)!.id)
        let full = layout(LogChipsBar(store: store, link: .constant(nil), unlinked: .constant(false),
                                      tags: Binding(get: { chosen }, set: { chosen = $0 })), width: 460)
        XCTAssertEqual(empty.height, LogChipsBar.height, accuracy: 1)
        XCTAssertEqual(full.height, LogChipsBar.height, accuracy: 1, "选再多也不会让窗口变高")
        for tag in ["读书笔记", "论文"] {
            let notes = NotesView(store: store, initialTag: tag, reveal: { _ in }, openDay: { _ in })
            XCTAssertGreaterThan(layout(notes, width: 900).height, 100, "空标签和有内容的标签都能打开")
        }
    }

    func testPickerAndNotesViewRenderWithTags() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.addParsedTodo("读摘要 #论文", on: day))
        _ = store.addParsedTodo("看公式 #论文/方法 #阅读", on: day)
        _ = try store.quickLog("摘要读完了", taskID: a.id, on: day)

        let picker = layout(TagPickerView(store: store, task: a.task), width: 360)
        XCTAssertGreaterThan(picker.height, 100, "标签选择页有内容")

        for (selection, tag) in [(nil, "论文"), (a.id, nil)] as [(UUID?, String?)] {
            let notes = NotesView(store: store, initialSelection: selection, initialTag: tag, reveal: { _ in }, openDay: { _ in })
            let size = layout(notes, width: 900)
            XCTAssertGreaterThan(size.height, 100)
        }
    }

    func testQuickPanelStaysOpenWhenMetadataPopoverTakesKeyboardFocus() async throws {
        _ = NSApplication.shared
        let store = makeStore()
        store.createTag("论文")
        let controller = QuickCaptureController(store: store, openMain: {})
        let existing = Set(NSApp.windows.map(\.windowNumber))
        controller.show(.log)
        let panel = try XCTUnwrap(NSApp.windows.first { !existing.contains($0.windowNumber) && $0 is NSPanel })
        panel.alphaValue = 0
        let originalSize = panel.frame.size
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: TagSelectionPopover(store: store, tags: .constant([])))
        defer { popover.close(); panel.close() }
        let content = try XCTUnwrap(panel.contentView)
        popover.show(relativeTo: NSRect(x: 20, y: 20, width: 24, height: 22), of: content, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.alphaValue = 0
        try await Task.sleep(nanoseconds: 100_000_000)
        let popup = try XCTUnwrap(popover.contentViewController?.view.window)
        popup.makeKey()
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(panel.isVisible, "选择器接收搜索输入时宿主仍在")
        XCTAssertEqual(panel.frame.size, originalSize, "浮窗不改变快速面板大小")
    }

    func testTagPopoverEnterSavesDraftAndEscapeDiscardsIt() async throws {
        _ = NSApplication.shared
        let store = makeStore()
        let state = TagPopoverTestState()
        let host = NSHostingView(rootView: TagPopoverTestHost(store: store, state: state))
        let anchor = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.contentView = host
        anchor.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        defer { anchor.contentView = nil; anchor.close() }
        for (confirms, focusesInput) in [(true, true), (true, false), (false, true)] {
            state.presented = true
            try await Task.sleep(for: .milliseconds(200))
            func input(in view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.isEditable { return field }
                return view.subviews.lazy.compactMap(input).first
            }
            let popup = try XCTUnwrap(NSApp.windows.first { $0 !== anchor && $0.isVisible && $0.contentView.flatMap(input) != nil })
            let content = try XCTUnwrap(popup.contentView)
            let field = try XCTUnwrap(input(in: content))
            popup.makeKey()
            if focusesInput {
                popup.makeFirstResponder(field)
                let editor = try XCTUnwrap(popup.firstResponder as? NSTextView)
                editor.insertText(confirms ? "NewTag" : "Discarded", replacementRange: editor.selectedRange())
            } else {
                popup.makeFirstResponder(content)
            }
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: popup.windowNumber, context: nil,
                                                   characters: confirms ? "\r" : "\u{1b}", charactersIgnoringModifiers: confirms ? "\r" : "\u{1b}",
                                                   isARepeat: false, keyCode: confirms ? 36 : 53))
            popup.sendEvent(key)
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertFalse(state.presented, "Enter and Escape close the tag popover")
            XCTAssertEqual(state.tags, ["Existing", "NewTag"], confirms ? "Enter saves a new tag in one step" : "Escape discards unsaved input")
        }
    }

}

@MainActor
private final class TagPopoverTestState: ObservableObject {
    @Published var presented = false
    @Published var tags = ["Existing"]
}

private struct TagPopoverTestHost: View {
    let store: JournalStore
    @ObservedObject var state: TagPopoverTestState
    var body: some View {
        Text("Tags").padding()
            .popover(isPresented: $state.presented) { TagSelectionPopover(store: store, tags: $state.tags) }
    }
}

@MainActor
final class DayLogWindowTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    private func makeStore() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory)
    }

    private func controller(_ name: String) -> DayLogWindowController {
        let controller = DayLogWindowController(frameName: name)
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
            UserDefaults.standard.synchronize()
        }
        Self.keepAlive.append(controller)
        return controller
    }

    func testViewListsTheDaysLogsInTimeOrder() throws {
        let store = makeStore()
        let day = JournalDates.calendar.startOfDay(for: Date())
        _ = try store.quickLog("晚", on: day, now: day.addingTimeInterval(3 * 3600))
        _ = try store.quickLog("早", on: day, now: day.addingTimeInterval(3600))
        _ = try store.quickLog("中", on: day, now: day.addingTimeInterval(2 * 3600))
        XCTAssertEqual(store.entry(for: day).logs.map(\.text), ["晚", "早", "中"], "存储顺序是追加顺序")
        XCTAssertEqual(store.entry(for: day).logsInTimeOrder.map(\.text), ["早", "中", "晚"], "显示按时间顺序")
    }

    func testIsAnIndependentResizableWindowThatTogglesAndIgnoresTheMainWindow() throws {
        let store = makeStore()
        let main = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.orderFront(nil)
        let log = controller("DayLogTest-\(UUID().uuidString)")
        Self.keepAlive.append(main)

        log.toggle(store: store, date: Date())
        let window = try XCTUnwrap(log.window)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.styleMask.contains(.resizable), "可以拖边缘调整大小")
        XCTAssertFalse(window.styleMask.contains(.closable), "和笔记一样没有红绿灯")
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertTrue(window.standardWindowButton(button)?.isHidden ?? true, "红绿灯都隐藏")
        }
        XCTAssertNil(window.parent, "独立窗口，不是主窗口的 sheet 或子窗口")
        XCTAssertNil(main.attachedSheet)
        XCTAssertEqual(window.minSize, DayLogWindowController.minSize)

        main.orderOut(nil)
        XCTAssertTrue(window.isVisible, "收起主窗口不影响日志窗口")
        log.toggle(store: store, date: Date())
        XCTAssertFalse(window.isVisible, "再次切换关闭")
        log.show(store: store, date: Date())
        XCTAssertTrue(log.window === window, "复用同一个窗口")
        window.cancelOperation(nil)
        XCTAssertFalse(window.isVisible, "Esc 关闭")
    }

    func testSizeIsRememberedAcrossCloseAndAcrossControllers() throws {
        let store = makeStore()
        let name = "DayLogTest-\(UUID().uuidString)"
        let first = controller(name)
        first.show(store: store, date: Date())
        let window = try XCTUnwrap(first.window)
        window.setContentSize(NSSize(width: 1234, height: 765))
        window.setFrameOrigin(NSPoint(x: 140, y: 160))
        let size = window.frame.size
        first.close()
        first.show(store: store, date: Date())
        XCTAssertEqual(first.window?.frame.size, size, "关闭再打开，大小不变")
        first.close()

        // 模拟重新启动应用：新的控制器从偏好里恢复。
        window.saveFrame(usingName: name)
        let second = controller(name)
        second.show(store: store, date: Date())
        XCTAssertEqual(try XCTUnwrap(second.window).frame.size.width, size.width, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(second.window).frame.size.height, size.height, accuracy: 1)
        second.close()
    }
}
