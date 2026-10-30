import AppKit
import Combine
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class JournalEditingTests: XCTestCase {
    private func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, of: type) }
    }

    private func commandReturn(window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }

    /// 日记里双击（和单击一样）正文：就地换成所见即所得的编辑器，编辑的是这一条。
    func testJournalDoubleClickEditsTheEntryInPlace() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let date = JournalDates.calendar.startOfDay(for: Date())
        _ = try store.quickLog("Journal edit original", linkDefault: false, on: date)
        let log = try XCTUnwrap(store.entry(for: date).logs.first)
        let host = NSHostingView(rootView: UnifiedJournalView(store: store, workspace: NotesWorkspaceNavigation(date: date)))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        let selection = LogKeyboardSelection.shared
        selection.select(nil)
        defer { InlineMarkdownEditor.shared.finish(); selection.select(nil); window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let label = try XCTUnwrap(descendants(host, of: InteractiveTaskText.self).first { $0.source == "Journal edit original" })
        let point = label.convert(NSPoint(x: label.textContainerOrigin.x + 18, y: label.textContainerOrigin.y + 8), to: nil)
        let hit = host.hitTest(host.superview?.convert(point, from: nil) ?? point)
        XCTAssertTrue(hit === label, "正文点击实际命中：\(String(describing: hit)); 正文边界：\(label.bounds); 窗口坐标：\(point)")
        let firstClick = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertNil(selection.handleMouseDown(firstClick))
        XCTAssertEqual(selection.selectedID, log.id)
        XCTAssertFalse(InlineMarkdownEditor.shared.isEditing(log.id))
        let doubleClick = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 2, pressure: 1))
        XCTAssertNotNil(selection.handleMouseDown(doubleClick))
        label.mouseDown(with: doubleClick)
        XCTAssertTrue(InlineMarkdownEditor.shared.isEditing(log.id), "双击正文就地编辑这一条")
        let editor = InlineMarkdownEditor.shared
        for _ in 0..<500 where editor.height == nil {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = try await editor.makeWebView().evaluateJavaScript("window.boardEditor.snapshot()")
        let snapshot = try XCTUnwrap(result as? [String: Any])
        let anchor = try XCTUnwrap(snapshot["anchor"] as? Int), head = try XCTUnwrap(snapshot["head"] as? Int)
        XCTAssertEqual((log.text as NSString).substring(with: NSRange(location: min(anchor, head), length: abs(head - anchor))), "Journal",
                       "A cold double click must select the clicked word in the editing document")
    }

    func testTitleEditingIgnoresBlurAndPlainReturnButAcceptsCommandReturn() async throws {
        var title = "Task title original"
        let host = NSHostingView(rootView: TaskTitleView(title: Binding(get: { title }, set: { title = $0 }), completed: false,
            color: .primary, fontSize: 13, next: {}, requestedEdit: .constant(nil)).frame(width: 400, height: 50))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let label = try XCTUnwrap(descendants(host, of: InteractiveTaskText.self).first)
        label.activate(at: .zero, clickCount: 2)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(descendants(host, of: TaskTextField.self).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? ImagePasteFieldEditorView)
        editor.insertText("Changed task title", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertNewline(nil)
        XCTAssertEqual(title, "Task title original")
        XCTAssertTrue(window.makeFirstResponder(nil))
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(descendants(host, of: TaskTextField.self).contains { $0 === field })
        XCTAssertEqual(title, "Task title original")
        XCTAssertTrue(window.makeFirstResponder(field))
        let resumed = try XCTUnwrap(field.currentEditor() as? ImagePasteFieldEditorView)
        resumed.keyDown(with: try commandReturn(window: window))
        XCTAssertEqual(title, "Changed task title")
    }

    func testTypingIsImmediateWithoutPublishingTheWholeStoreAndFlushPreservesLatestText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let date = Date()
        let buffer = LogDraftBuffer(store: store, date: date)
        var publications = 0
        let subscription = store.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        for index in 1...100 { buffer.update("Immediate draft \(index)") }
        XCTAssertEqual(buffer.text, "Immediate draft 100")
        XCTAssertEqual(publications, 0, "每个字不能发布整个仓库")
        buffer.flush()
        XCTAssertEqual(store.entry(for: date).logDraft, "Immediate draft 100")
        _ = try store.commitLog(on: date, linkDefault: false)
        buffer.synchronize(store.entry(for: date).logDraft)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(buffer.text.isEmpty)
        XCTAssertTrue(store.entry(for: date).logDraft.isEmpty, "提交后延迟写入不能恢复旧草稿")
        XCTAssertEqual(store.entry(for: date).logs.first?.text, "Immediate draft 100")
    }

    func testDraftPauseAndDateSwitchKeepSeparateDraftsWithoutCreatingEntries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let first = JournalDates.calendar.startOfDay(for: Date())
        let second = first.addingTimeInterval(86400)
        let old = LogDraftBuffer(store: store, date: first)
        old.update("First day draft")
        old.flush()
        let next = LogDraftBuffer(store: store, date: second)
        next.update("Second day draft")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.entry(for: first).logDraft, "First day draft")
        XCTAssertEqual(store.entry(for: second).logDraft, "Second day draft")
        XCTAssertTrue(store.entry(for: first).logs.isEmpty)
        XCTAssertTrue(store.entry(for: second).logs.isEmpty)
    }

    func testTodoDraftBufferTypesLocallyAndRetargetsDatesWithoutLosingText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let first = JournalDates.calendar.startOfDay(for: Date())
        let second = first.addingTimeInterval(86400)
        let buffer = LogDraftBuffer(field: .deadline)
        buffer.attach(store: store, date: first)
        var publications = 0
        let subscription = store.objectWillChange.sink { publications += 1 }
        for index in 1...50 { buffer.update("Todo \(index)") }
        XCTAssertEqual(publications, 0, "每个字不能发布整个仓库")
        subscription.cancel()
        buffer.attach(store: store, date: second)
        XCTAssertEqual(store.entry(for: first).deadlineDraft, "Todo 50", "切换日期前写回旧日期")
        XCTAssertEqual(buffer.text, "")
        buffer.update("Second day todo")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.entry(for: second).deadlineDraft, "Second day todo")
        _ = store.commitDraft(on: second)
        XCTAssertEqual(buffer.text, "", "提交后缓冲随仓库清空")
        XCTAssertTrue(store.entry(for: first).logDraft.isEmpty)
    }

    func testProgrammaticDraftWriteIsImmediateAndCancelsPendingTyping() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let date = Date()
        let buffer = LogDraftBuffer(store: store, date: date)
        buffer.update("/he")
        buffer.set("/help ")
        XCTAssertEqual(store.entry(for: date).logDraft, "/help ")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(store.entry(for: date).logDraft, "/help ")
        XCTAssertEqual(buffer.text, "/help ")
    }

    /// 标题只有 ⌘↩ 才保存；退出时没保存的要问：保存、放弃或回去接着改。
    func testUnsavedTitleIsResolvedBeforeTermination() async throws {
        var title = "原标题"
        let host = NSHostingView(rootView: TaskTitleView(title: Binding(get: { title }, set: { title = $0 }), completed: false,
            color: .primary, fontSize: 13, next: {}, requestedEdit: .constant(nil)).frame(width: 400, height: 50))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        let edits = TaskTitleEdits.shared
        let originalPrompt = edits.prompt
        defer { edits.prompt = originalPrompt; window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        var answer = TaskTitleEdits.Choice.cancel
        var asked = [Int]()
        edits.prompt = { asked.append($0); return answer }

        XCTAssertTrue(edits.resolveBeforeTermination(), "没有在改的标题，不问")
        try XCTUnwrap(descendants(host, of: InteractiveTaskText.self).first).activate(at: .zero, clickCount: 2)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(edits.hasUnsaved, "打开了但没改，不算未保存")
        XCTAssertTrue(edits.resolveBeforeTermination())
        XCTAssertTrue(asked.isEmpty)

        let field = try XCTUnwrap(descendants(host, of: TaskTextField.self).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? ImagePasteFieldEditorView)
        editor.insertText("新标题", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        XCTAssertTrue(edits.hasUnsaved)

        XCTAssertFalse(edits.resolveBeforeTermination(), "选择回去接着改：不退出")
        XCTAssertEqual(title, "原标题")
        answer = .discard
        XCTAssertTrue(edits.resolveBeforeTermination())
        XCTAssertEqual(title, "原标题", "放弃：不写回")
        answer = .save
        XCTAssertTrue(edits.resolveBeforeTermination())
        XCTAssertEqual(title, "新标题", "保存并退出")
        XCTAssertEqual(asked, [1, 1, 1])
        XCTAssertFalse(edits.hasUnsaved, "保存后不再算未保存")
    }

    /// 还有没保存的标题：隐藏的主界面不释放，否则改到一半的内容就没了。
    func testHiddenContentIsKeptWhileATitleIsUnsaved() async throws {
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var keeping = true, released = 0
        let releaser = HiddenContentReleaser(window: window, delay: .seconds(60), keep: { keeping }, release: { released += 1 }, rebuild: {})
        releaser.releaseNow()
        XCTAssertEqual(released, 0)
        keeping = false
        releaser.releaseNow()
        XCTAssertEqual(released, 1)
    }

    /// `/filter #N`：跨日期只看这个任务的日志，键盘也只在这些里走；`/filter` 恢复。没有这个编号时报错、草稿留着。
    func testFilterCommandShowsLinkedLogsAcrossDatesAndClears() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let today = JournalDates.calendar.startOfDay(for: Date())
        let yesterday = try XCTUnwrap(JournalDates.calendar.date(byAdding: .day, value: -1, to: today))
        let task = try XCTUnwrap(store.addParsedTodo("读论文", on: today))
        let number = try XCTUnwrap(task.task.number)
        let linked = try XCTUnwrap(try store.quickLogEntry("昨天的进展", taskID: task.task.id, on: yesterday).entry)
        _ = try store.quickLog("今天的进展", taskID: task.task.id, on: today)
        _ = try store.quickLog("无关的日志", linkDefault: false, on: today)

        let host = NSHostingView(rootView: UnifiedJournalView(store: store, workspace: NotesWorkspaceNavigation(date: today)).frame(width: 1000, height: 700))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        let selection = LogKeyboardSelection.shared
        selection.isActive = { true }
        selection.currentMode = { .journal }
        defer {
            selection.isActive = { NotesWindowController.shared.isKey }
            selection.currentMode = { NotesWindowController.shared.workspace.mode }
            selection.select(nil)
            window.contentView = nil
            window.close()
        }
        func bodies() -> Set<String> { Set(descendants(host, of: InteractiveTaskText.self).map(\.string).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) }
        func run(_ command: String) async throws {
            store.setLogDraft(command, on: today)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let input = try XCTUnwrap(descendants(host, of: ImagePasteTextView.self).first)
            XCTAssertTrue(window.makeFirstResponder(input))
            input.keyDown(with: try commandReturn(window: window))
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            window.makeFirstResponder(nil)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(bodies().contains("无关的日志"))

        try await run("/filter #\(number)")
        XCTAssertEqual(store.entry(for: today).logDraft, "", "命令执行后清空草稿")
        XCTAssertTrue(bodies().contains("昨天的进展"), "跨日期")
        XCTAssertTrue(bodies().contains("今天的进展"))
        XCTAssertFalse(bodies().contains("无关的日志"))
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                  characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125))
        XCTAssertTrue(selection.handle(down))
        XCTAssertEqual(selection.selectedID, linked.id, "键盘从筛出来的第一条开始")
        selection.select(nil)

        try await run("/filter #9999")
        XCTAssertEqual(store.entry(for: today).logDraft, "/filter #9999", "编号不存在：草稿留着改")
        XCTAssertFalse(bodies().contains("无关的日志"), "筛选不变")

        try await run("/filter")
        XCTAssertTrue(bodies().contains("无关的日志"), "恢复当天的日志")
        XCTAssertFalse(bodies().contains("昨天的进展"))

        try await run("/summary")
        XCTAssertEqual(store.entry(for: today).logDraft, "/summary", "去掉的命令报错而不是没反应，草稿留着")
        XCTAssertEqual(store.entry(for: today).logs.count, 2)
    }

    /// 拖进来的文件：按顺序读出图片，其他文件跳过。
    func testDroppedFilesKeepOrderAndSkipNonImages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func file(_ name: String, _ content: String) throws -> NSItemProvider {
            let url = directory.appendingPathComponent(name)
            try Data(content.utf8).write(to: url)
            return NSItemProvider(object: url as NSURL)
        }
        let datas = await ImageFileDrop.load([try file("a.png", "第一张"), try file("b.txt", "不是图片"), try file("c.jpg", "第二张")])
        XCTAssertEqual(datas.map { String(decoding: $0, as: UTF8.self) }, ["第一张", "第二张"])
    }

    /// 编辑中的标题所在的行不见了（折叠、切页）：改过的先存下；没改过的不写。
    func testTitleEditIsSavedWhenRowDisappears() async throws {
        final class Model: ObservableObject {
            @Published var shown = true
            @Published var title = "原标题"
            @Published var request: UUID?
        }
        struct Root: View {
            @ObservedObject var model: Model
            let id: UUID
            var body: some View {
                VStack {
                    if model.shown {
                        TaskTitleView(title: $model.title, completed: false, color: .primary, fontSize: 13, next: {}, itemID: id, requestedEdit: $model.request)
                    }
                }.frame(width: 300, height: 80)
            }
        }
        let model = Model()
        let id = UUID()
        let host = NSHostingView(rootView: Root(model: model, id: id))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try XCTUnwrap(descendants(host, of: InteractiveTaskText.self).first).activate(at: .zero, clickCount: 2)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let input = try XCTUnwrap(descendants(host, of: TaskTextField.self).first)
        XCTAssertTrue(window.makeFirstResponder(input))
        let field = try XCTUnwrap(input.currentEditor() as? ImagePasteFieldEditorView)
        field.insertText("改过", replacementRange: NSRange(location: 0, length: (field.string as NSString).length))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(TaskTitleEdits.shared.hasUnsaved)
        model.shown = false
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.title, "改过")
        XCTAssertFalse(TaskTitleEdits.shared.hasUnsaved)
    }

    /// 标题里按普通回车不保存：告诉界面提示一句。
    func testPlainReturnReportsHintWithoutSaving() async throws {
        var hints = 0, submitted = 0, text = "标题"
        let host = NSHostingView(rootView: TaskInput(text: Binding(get: { text }, set: { text = $0 }), focused: .constant(true), submit: { submitted += 1 },
                                                     allowsNewlines: false, commandReturnOnly: true, plainReturn: { hints += 1 }).frame(width: 300, height: 30))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 30), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(descendants(host, of: TaskTextField.self).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        try XCTUnwrap(field.currentEditor() as? ImagePasteFieldEditorView).doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(hints, 1)
        XCTAssertEqual(submitted, 0)
    }

    /// 提示里的标签名、文件名原样显示：`*`、`_` 不当 Markdown。
    func testToastDoesNotParseMarkdown() {
        func width(_ message: String) -> CGFloat {
            let center = ToastCenter()
            center.show(message)
            let host = NSHostingView(rootView: ToastView(center: center))
            return host.fittingSize.width
        }
        XCTAssertGreaterThan(width("*标签*"), width("标签") + 4, "星号还在")
    }

    /// 字号、深浅色变了：键盘进入编辑用新的，不用注册页面时记下的。
    func testKeyboardEditUsesCurrentAppearance() async throws {
        final class Model: ObservableObject { @Published var scheme = ColorScheme.light }
        struct Root: View {
            @ObservedObject var model: Model
            let store: JournalStore
            let date: Date
            var body: some View { UnifiedJournalView(store: store, workspace: NotesWorkspaceNavigation(date: date)).environment(\.colorScheme, model.scheme) }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let date = Date()
        store.setLogDraft("正文", on: date)
        _ = try store.commitLog(on: date, linkDefault: false)
        let id = try XCTUnwrap(store.entry(for: date).logs.first?.id)
        let model = Model()
        let host = NSHostingView(rootView: Root(model: model, store: store, date: date))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { InlineMarkdownEditor.shared.finish(); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        model.scheme = .dark
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        try XCTUnwrap(LogKeyboardSelection.shared.pages[.journal]).edit(id)
        XCTAssertEqual(InlineMarkdownEditor.shared.settings["dark"] as? Bool, true)
    }
}
