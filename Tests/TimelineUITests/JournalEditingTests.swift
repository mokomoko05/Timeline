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
        let host = NSHostingView(rootView: UnifiedJournalView(store: store, date: .constant(date), navigationRequest: 0))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { InlineMarkdownEditor.shared.finish(); window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let label = try XCTUnwrap(descendants(host, of: InteractiveTaskText.self).first { $0.source == "Journal edit original" })
        let point = label.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), to: nil)
        let hit = host.hitTest(host.superview?.convert(point, from: nil) ?? point)
        XCTAssertTrue(hit === label, "正文点击实际命中：\(String(describing: hit)); 正文边界：\(label.bounds); 窗口坐标：\(point)")
        let doubleClick = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 2, pressure: 1))
        label.mouseDown(with: doubleClick)
        XCTAssertTrue(InlineMarkdownEditor.shared.isEditing(log.id), "双击正文就地编辑这一条")
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
}
