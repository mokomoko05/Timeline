import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class PersistentPanelTests: XCTestCase {
    func testQuickTodoAndLogGrowToSixLinesThenScrollAndShrink() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let model = QuickCaptureModel()
        let host = NSHostingView(rootView: QuickCaptureView(store: store, model: model, close: {}, resize: { _ in }))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 342, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        func editor(_ view: NSView) -> ImagePasteTextView? {
            (view as? ImagePasteTextView) ?? view.subviews.lazy.compactMap(editor).first
        }
        let input = try XCTUnwrap(editor(host))
        let scroll = try XCTUnwrap(input.enclosingScrollView)
        let panelHeight = host.fittingSize.height
        let inputHeight = scroll.frame.height
        XCTAssertEqual(inputHeight, 24, accuracy: 1)
        model.text = String(repeating: "A long task that wraps onto several lines. ", count: 20)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let cappedHeight = TaskInput.height(for: model.text, font: try XCTUnwrap(input.font), width: scroll.frame.width, minHeight: 24, maxLines: 6)
        XCTAssertEqual(scroll.frame.height, cappedHeight, accuracy: 1)
        XCTAssertGreaterThan(host.fittingSize.height, panelHeight + 40)
        XCTAssertGreaterThan(input.frame.height, scroll.contentSize.height)
        XCTAssertFalse(input.returnSubmits)
        input.scrollRangeToVisible(NSRange(location: (input.string as NSString).length, length: 0))
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0, "The wrapped content can scroll vertically")
        for choice in [QuickCaptureMode.log, .todo, .log, .todo] {
            window.makeFirstResponder(input)
            func button(in view: NSView) -> CaptureModeButton? {
                if let button = view as? CaptureModeButton, button.choice == choice { return button }
                return view.subviews.lazy.compactMap(button).first
            }
            let target = try XCTUnwrap(button(in: host))
            XCTAssertTrue(target.acceptsFirstMouse(for: nil))
            let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                       eventNumber: 0, clickCount: 1, pressure: 1))
            target.mouseDown(with: click)
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(editor(host) === input, "Switching must retain the active native editor")
            XCTAssertGreaterThan(host.fittingSize.height, panelHeight)
            XCTAssertEqual(scroll.frame.height, cappedHeight, accuracy: 1, "Both modes cap the editor at six lines")
            XCTAssertEqual(model.mode, choice, "A click switches modes while the editor has focus")
            XCTAssertTrue(window.firstResponder === input, "Mode clicks preserve editing focus")
            XCTAssertFalse(input.returnSubmits)
            let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                     charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            XCTAssertFalse(input.shouldInterceptReturn(enter), "Enter inserts a newline in either mode")
            let submit = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            XCTAssertTrue(input.shouldInterceptReturn(submit), "Command + Enter submits in either mode")
        }
        model.text = "Short task"
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(host.fittingSize.height, panelHeight, accuracy: 1, "Task metadata stays in the existing rows")
        XCTAssertTrue(scroll.autohidesScrollers)
        XCTAssertEqual(scroll.scrollerStyle, .overlay)
        XCTAssertTrue(scroll.verticalScroller?.isHidden ?? true, "A single line has no visible scrollbar")
        if let path = ProcessInfo.processInfo.environment["TIMELINE_QUICK_SNAPSHOT"], let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    func testQuickCaptureStaysFloatingAfterFocusLossAndRepeatedSubmissionsUntilManuallyHidden() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let controller = QuickCaptureController(store: store, openMain: {})
        let existing = Set(NSApp.windows.map(\.windowNumber))
        controller.show(.log)
        let panel = try XCTUnwrap(NSApp.windows.first { !existing.contains($0.windowNumber) && $0 is NSPanel })
        defer { panel.close() }
        func findEditor(_ view: NSView) -> ImagePasteTextView? {
            (view as? ImagePasteTextView) ?? view.subviews.lazy.compactMap(findEditor).first
        }
        let editor = try XCTUnwrap(findEditor(try XCTUnwrap(panel.contentView)))
        XCTAssertFalse(editor.returnSubmits)
        func enter(_ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                             isARepeat: false, keyCode: 36)!
        }
        XCTAssertFalse(editor.shouldInterceptReturn(enter([])), "Enter passes through for a newline")
        XCTAssertTrue(editor.shouldInterceptReturn(enter(.command)), "Command + Enter submits")
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(try XCTUnwrap(panel as? NSPanel).hidesOnDeactivate)
        editor.string = "Unfinished draft"
        editor.delegate?.textDidEndEditing?(Notification(name: NSText.didEndEditingNotification, object: editor))
        XCTAssertTrue(store.allLogs().isEmpty, "Losing focus must preserve the draft without submitting")
        XCTAssertEqual(editor.string, "Unfinished draft")
        let inputHeight = try XCTUnwrap(editor.enclosingScrollView).frame.height
        XCTAssertLessThanOrEqual(inputHeight, 26)
        let originalFrame = panel.frame
        editor.string = String(repeating: "A long entry with several wrapped lines. ", count: 20)
        editor.didChangeText()
        panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(try XCTUnwrap(editor.enclosingScrollView).frame.height, inputHeight)
        XCTAssertGreaterThan(panel.frame.height, originalFrame.height)
        XCTAssertEqual(panel.frame.maxY, originalFrame.maxY, accuracy: 1, "Growing input keeps the top edge anchored")
        XCTAssertGreaterThan(editor.frame.height, inputHeight)
        panel.resignKey()
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(panel.isVisible)
        for text in ["First entry", "Second entry"] {
            editor.string = text
            try XCTUnwrap(editor.onSubmitShortcut)()
            try await Task.sleep(for: .milliseconds(800))
            XCTAssertTrue(panel.isVisible, "Submitting must keep the panel open")
            XCTAssertEqual(editor.string, "")
        }
        XCTAssertEqual(Set(store.allLogs().map(\.log.text)), Set(["First entry", "Second entry"]))
        controller.toggle(.log)
        XCTAssertFalse(panel.isVisible, "The shortcut explicitly hides the panel")
    }

    func testQuickCaptureReusesOnePanelAcrossShowsAndKeepsTheDraft() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let controller = QuickCaptureController(store: store, openMain: {})
        let existing = Set(NSApp.windows.map(\.windowNumber))
        controller.show(.log)
        let panel = try XCTUnwrap(NSApp.windows.first { !existing.contains($0.windowNumber) && $0 is NSPanel })
        defer { panel.close() }
        let host = panel.contentView
        panel.close()
        controller.show(.todo)
        let panels = NSApp.windows.filter { !existing.contains($0.windowNumber) && $0 is NSPanel }
        XCTAssertEqual(panels.count, 1, "再次呼出复用同一个面板")
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.contentView === host, "不重建视图")
    }
}
