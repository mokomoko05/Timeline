import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

final class LogInputTests: XCTestCase {
    @MainActor
    func testTaskReferenceFollowsIdentityAcrossReorderMoveAndDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let day = try XCTUnwrap(JournalDates.date(for: "2026-10-07"))
        let tomorrow = try XCTUnwrap(JournalDates.date(for: "2026-10-08"))
        store.addTodo("另一项", on: day)
        store.addTodo("阅读论文", on: day)
        let tasks = store.entry(for: day).todos
        store.setLogTask(tasks[1].id, on: day)
        store.setLogDraft("整理完方法部分", on: day)
        try store.commitLog(on: day)
        let log = try XCTUnwrap(store.entry(for: day).logs.first)
        XCTAssertEqual(log.taskNumber, 2)
        XCTAssertEqual(LogTaskLabel.saved(log, store: store, logDate: day), "#2 阅读论文")
        store.placeTodo(tasks[1].id, on: day, relativeTo: tasks[0].id)
        XCTAssertEqual(LogTaskLabel.saved(log, store: store, logDate: day), "#2 阅读论文", "编号是永久的，调整顺序不变")
        store.setDeadline(tasks[1].id, to: tomorrow)
        XCTAssertEqual(LogTaskLabel.saved(log, store: store, logDate: day), "#2 阅读论文", "改截止日期也不变")
        XCTAssertEqual(log.taskID, tasks[1].id)
        store.deleteTodo(tasks[1].id, on: day)
        XCTAssertEqual(LogTaskLabel.saved(log, store: store, logDate: day), "#2 阅读论文（已删除）")
        let reloaded = JournalStore(directory: directory)
        XCTAssertEqual(reloaded.entry(for: day).logs.first?.taskNumber, 2)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(log)) as? [String: Any])
        legacy.removeValue(forKey: "taskNumber")
        let oldLog = try JSONDecoder().decode(DailyLogEntry.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(oldLog.taskNumber)
        XCTAssertEqual(LogTaskLabel.saved(oldLog, store: store, logDate: day), "阅读论文（已删除）")
    }

    @MainActor
    func testCompactLogTextUsesZeroExtraLineSpacingAndRetainsLinks() async throws {
        let text = TaskLinkText.styledText("阅读 [论文](https://example.com)", completed: false,
                                           color: .white, fontSize: 12, monospaced: true, compactLines: true)
        let paragraph = try XCTUnwrap(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.lineSpacing, 0)
        let linkRange = (text.string as NSString).range(of: "论文")
        XCTAssertEqual(text.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL, URL(string: "https://example.com"))
    }

    @MainActor
    func testTerminalHistoryAndTabAreHandledOnlyWhenProvided() async {
        // 历史上下翻、Tab 补全只在日志命令输入框（多行、growing）里接的，走 GrowingTaskInput。
        var events: [String] = []
        let input = GrowingTaskInput(text: .constant(""), focused: .constant(true), submit: {}, monospaced: true,
                                     historyUp: { events.append("up") }, historyDown: { events.append("down") },
                                     complete: { events.append("tab") }, minHeight: 24)
        let coordinator = input.makeCoordinator()
        let editor = ImagePasteTextView()
        XCTAssertTrue(coordinator.textView(editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
        XCTAssertTrue(coordinator.textView(editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertTrue(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(events, ["up", "down", "tab"])
        let plain = GrowingTaskInput(text: .constant(""), focused: .constant(true), submit: {}, minHeight: 24)
        XCTAssertFalse(plain.makeCoordinator().textView(editor, doCommandBy: #selector(NSResponder.moveUp(_:))), "没提供就不处理，交回系统")
        XCTAssertFalse(plain.makeCoordinator().textView(editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
    }

    @MainActor
    func testLogTextUsesMonospacedFontAndRetainsClickablePDF() async {
        let text = TaskLinkText.styledText("阅读 [eurosys](file:///tmp/paper.pdf)", completed: false,
                                           color: .labelColor, fontSize: 12, monospaced: true)
        let attributes = text.attributes(at: 3, effectiveRange: nil)
        XCTAssertEqual(attributes[.link] as? URL, URL(string: "file:///tmp/paper.pdf"))
        XCTAssertEqual(attributes[.font] as? NSFont, NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
    }
}

@MainActor
final class NoteTextBufferTests: XCTestCase {
    func testTypingStaysLocalUntilFlushAndExternalClearSynchronizes() async throws {
        let nav = NotesNavigation()
        let buffer = NoteTextBuffer()
        buffer.attach(nav: nav, key: "task:a")
        var publications = 0
        let subscription = nav.objectWillChange.sink { publications += 1 }
        for index in 1...30 { buffer.update("想法 \(index)") }
        XCTAssertEqual(publications, 0, "按键不刷新整个笔记窗口")
        subscription.cancel()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(nav.draft("task:a").text, "想法 30", "停顿后写回")
        buffer.update("切换前没写回的字")
        buffer.attach(nav: nav, key: "task:b")
        XCTAssertEqual(nav.draft("task:a").text, "切换前没写回的字", "切换任务前写回")
        XCTAssertEqual(buffer.text, "")
        buffer.update("b 的草稿")
        buffer.flush()
        nav.clearDraft("task:b")
        XCTAssertEqual(buffer.text, "", "提交后清空同步到输入框")
    }
}

final class DroppedGroupTests: XCTestCase {
    private func task(_ title: String, completed: Bool = false, dropped: Bool = false, position: Double) -> ScheduledTask {
        var todo = Todo(title: title)
        todo.completed = completed
        todo.dropped = dropped
        todo.listPosition = position
        return ScheduledTask(date: Date(), task: todo)
    }

    func testDroppedTasksStayInOneTrailingGroupWhateverTheirSortPosition() {
        let a = task("a", position: 1), b = task("b", position: 3)
        let droppedEarly = task("dropped early", completed: true, dropped: true, position: 0)
        let droppedMiddle = task("dropped middle", completed: true, dropped: true, position: 2)
        let done = task("done", completed: true, position: 4)
        let before = TaskTimelineItem.items(for: [droppedEarly, a, droppedMiddle, b, done])
        XCTAssertEqual(before.map { $0.tasks.map(\.task.title) }, [["a"], ["b"], ["done"], ["dropped early", "dropped middle"]])
        // 拖动重排未完成的事项后，已放弃那一组的位置和身份都不变。
        let reordered = TaskTimelineItem.items(for: [droppedEarly, b, droppedMiddle, a, done])
        XCTAssertEqual(reordered.last?.id, before.last?.id)
        XCTAssertEqual(reordered.map { $0.tasks.map(\.task.title) }, [["b"], ["a"], ["done"], ["dropped early", "dropped middle"]])
        XCTAssertTrue(TaskTimelineItem.items(for: [a, b]).allSatisfy { !$0.droppedGroup })
    }
}

