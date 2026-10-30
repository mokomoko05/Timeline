import AppKit
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class LogKeyboardSelectionTests: XCTestCase {
    private static var keepAlive: [NotesWindowController] = []

    private func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    /// 日记页：↑↓ 在当天的日志间选择，⌫ 删除后选中原位置的下一条，Esc 取消选中；Shift 等修饰键不接管。
    func testArrowKeysSelectAndDeleteRemovesTheSelectedLog() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let day = JournalDates.calendar.startOfDay(for: Date())
        let logs = try (0..<3).map { index in
            try XCTUnwrap(try store.quickLogEntry("第 \(index) 条", on: day, now: day.addingTimeInterval(Double(index + 1) * 60)).entry)
        }
        let controller = NotesWindowController(nav: NotesNavigation(defaults: InMemoryDefaults()))
        Self.keepAlive.append(controller)
        controller.showJournal(store: store, date: day)
        defer { controller.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        controller.window?.makeFirstResponder(nil)

        let selection = LogKeyboardSelection.shared
        selection.isActive = { true }
        selection.currentMode = { controller.workspace.mode }
        defer {
            selection.isActive = { NotesWindowController.shared.isKey }
            selection.currentMode = { NotesWindowController.shared.workspace.mode }
            selection.select(nil)
        }

        XCTAssertTrue(selection.handle(key(125)))
        XCTAssertEqual(selection.selectedID, logs[0].id, "没有选中时 ↓ 选第一条")
        XCTAssertTrue(selection.handle(key(125)))
        XCTAssertEqual(selection.selectedID, logs[1].id)
        XCTAssertTrue(selection.handle(key(126)))
        XCTAssertEqual(selection.selectedID, logs[0].id)
        XCTAssertTrue(selection.handle(key(125)))

        XCTAssertTrue(selection.handle(key(51)))
        XCTAssertEqual(store.entry(for: day).logs.map(\.id), [logs[0].id, logs[2].id])
        XCTAssertEqual(selection.selectedID, logs[2].id, "删除后选中原来的下一条")
        store.undo()
        XCTAssertEqual(store.entry(for: day).logs.count, 3, "可以撤销")

        // ⏎ 就地编辑时仍保持选中：编辑完 Esc 退出后，↑↓ 从这一条接着走。
        let editing = try XCTUnwrap(selection.selectedID)
        XCTAssertTrue(selection.handle(key(36)))
        XCTAssertEqual(selection.selectedID, editing)
        XCTAssertTrue(InlineMarkdownEditor.shared.isEditing(editing))
        InlineMarkdownEditor.shared.finish()
        XCTAssertTrue(selection.handle(key(126)))
        XCTAssertEqual(selection.selectedID, logs[1].id, "从编辑过的那一条往上走")

        XCTAssertTrue(selection.handle(key(53)))
        XCTAssertNil(selection.selectedID)
        XCTAssertFalse(selection.handle(key(53)), "没有选中时 Esc 照常交给窗口（收起）")
        XCTAssertFalse(selection.handle(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                                                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)!))
    }
}
