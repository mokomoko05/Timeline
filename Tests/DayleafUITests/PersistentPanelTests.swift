import AppKit
import SwiftUI
import XCTest
import DayleafCore
@testable import Dayleaf

@MainActor
final class PersistentPanelTests: XCTestCase {
    func testQuickTodoWrapsAndScrollsInsideOneLineWithoutGrowingThePanel() async throws {
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
        XCTAssertEqual(scroll.frame.height, inputHeight, accuracy: 1)
        XCTAssertEqual(host.fittingSize.height, panelHeight, accuracy: 1)
        XCTAssertGreaterThan(input.frame.height, scroll.contentSize.height)
        XCTAssertTrue(input.returnSubmits)
        input.scrollRangeToVisible(NSRange(location: (input.string as NSString).length, length: 0))
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0, "The wrapped content can scroll vertically")
        for choice in [QuickCaptureMode.log, .todo, .log, .todo] {
            window.makeFirstResponder(input)
            model.mode = choice
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(editor(host) === input, "Switching must retain the active native editor")
            XCTAssertEqual(host.fittingSize.height, panelHeight, accuracy: 1, "Both modes use the same panel height")
            XCTAssertEqual(scroll.frame.height, inputHeight, accuracy: 1)
            XCTAssertEqual(input.returnSubmits, choice == .todo)
        }
        model.text = "Tomorrow read the paper #reading"
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(host.fittingSize.height, panelHeight, accuracy: 1, "Task metadata stays in the existing rows")
        if let path = ProcessInfo.processInfo.environment["DAYLEAF_QUICK_SNAPSHOT"], let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
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
        editor.string = String(repeating: "A long entry with several wrapped lines. ", count: 20)
        editor.didChangeText()
        panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try XCTUnwrap(editor.enclosingScrollView).frame.height, inputHeight, accuracy: 1)
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
}
