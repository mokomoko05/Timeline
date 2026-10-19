import AppKit
import XCTest
import DayleafCore
@testable import Dayleaf

@MainActor
final class PersistentPanelTests: XCTestCase {
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
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(try XCTUnwrap(panel as? NSPanel).hidesOnDeactivate)
        editor.string = "Unfinished draft"
        editor.delegate?.textDidEndEditing?(Notification(name: NSText.didEndEditingNotification, object: editor))
        XCTAssertTrue(store.allLogs().isEmpty, "Losing focus must preserve the draft without submitting")
        XCTAssertEqual(editor.string, "Unfinished draft")
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
