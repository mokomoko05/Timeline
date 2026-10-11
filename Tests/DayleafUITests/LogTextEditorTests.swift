import AppKit
import SwiftUI
import XCTest
@testable import Dayleaf

/// 复盘里编辑单条日志的输入框：Enter 换行，⌥Enter 或失焦（点击别处）保存，Esc 取消。
@MainActor
final class LogTextEditorTests: XCTestCase {
    private func keyEvent(modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    }

    func testPlainEnterIsNotInterceptedOptionEnterSavesBasedOnTriggeringEvent() {
        var committed = 0
        var text = ""
        let view = LogTextEditor(text: Binding(get: { text }, set: { text = $0 }), commit: { committed += 1 }, cancel: {})
        let coordinator = view.makeCoordinator()
        let editor = KeyTrackingTextView()
        editor.delegate = coordinator
        editor.string = "第一行"

        editor.lastKeyDownEvent = keyEvent(modifiers: [])
        XCTAssertFalse(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))), "普通 Enter 不拦截，交给系统换行")
        XCTAssertEqual(committed, 0)

        editor.lastKeyDownEvent = keyEvent(modifiers: .option)
        XCTAssertTrue(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))), "⌥Enter 保存")
        XCTAssertEqual(committed, 1)
    }

    func testBlurSaves() {
        var committed = 0
        var text = ""
        let view = LogTextEditor(text: Binding(get: { text }, set: { text = $0 }), commit: { committed += 1 }, cancel: {})
        let coordinator = view.makeCoordinator()
        let editor = KeyTrackingTextView()
        editor.delegate = coordinator
        editor.string = "改好的内容"

        coordinator.textDidEndEditing(Notification(name: NSText.didEndEditingNotification, object: editor))
        XCTAssertEqual(committed, 1, "失焦（点击别处）当成保存")
        XCTAssertEqual(text, "改好的内容")
    }

    func testEscapeCancelsWithoutSaving() {
        var committed = 0
        var cancelled = 0
        let view = LogTextEditor(text: .constant(""), commit: { committed += 1 }, cancel: { cancelled += 1 })
        let coordinator = view.makeCoordinator()
        let editor = KeyTrackingTextView()
        editor.delegate = coordinator

        XCTAssertTrue(coordinator.textView(editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(committed, 0)
    }
}
