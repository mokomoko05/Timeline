import XCTest
@testable import TimelineCore

final class DailyLogTests: XCTestCase {
    private func date(_ day: Int, hour: Int = 12) -> Date {
        JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testCommandsAcceptPlainTextAndKeepBodyIntact() throws {
        XCTAssertEqual(try LogCommand.parse("  随手记录  "), .entry(.note, "随手记录"))
        XCTAssertEqual(try LogCommand.parse("/DONE\t阅读 [论文](file:///tmp/paper.pdf)"), .entry(.done, "阅读 [论文](file:///tmp/paper.pdf)"))
        XCTAssertEqual(try LogCommand.parse("/block 编译失败\n需要检查环境"), .entry(.block, "编译失败\n需要检查环境"))
        XCTAssertEqual(try LogCommand.parse("/plan 补实验"), .entry(.plan, "补实验"))
        XCTAssertEqual(try LogCommand.parse("/note /literal"), .entry(.note, "/literal"))
        XCTAssertEqual(try LogCommand.parse("/Users/me/paper.pdf"), .entry(.note, "/Users/me/paper.pdf"))
        XCTAssertEqual(try LogCommand.parse("/help"), .help)
        XCTAssertThrowsError(try LogCommand.parse("/summary"), "复盘命令已经去掉，按未知命令提示")
        XCTAssertThrowsError(try LogCommand.parse("/unknown text"))
        XCTAssertThrowsError(try LogCommand.parse(" \n "))
        let log = DailyLogEntry(createdAt: date(7), kind: .note, text: "/literal")
        XCTAssertEqual(try LogCommand.parse(log.command), .entry(.note, "/literal"))
    }

    @MainActor
    func testOldSummaryRemainsIntactWhenAddingLogsAndReloading() async throws {
        let directory = try directory()
        let old = "{\"version\":4,\"days\":{\"2026-10-07\":{\"todos\":[],\"summary\":\"原有总结\\n第二行\"}}}"
        try Data(old.utf8).write(to: directory.appendingPathComponent("journal.json"))
        let store = JournalStore(directory: directory)
        let day = date(7)
        XCTAssertFalse(store.isReadOnly)
        XCTAssertTrue(store.entry(for: day).logs.isEmpty)
        store.setLogDraft("/block 等待实验结果", on: day)
        try store.commitLog(on: day, now: date(7, hour: 15))
        store.setLogDraft("未提交的下一条", on: day)
        store.save()
        let reloaded = JournalStore(directory: directory)
        XCTAssertEqual(reloaded.entry(for: day).summary, "原有总结\n第二行")
        XCTAssertEqual(reloaded.entry(for: day).logs.first?.kind, .block)
        XCTAssertEqual(reloaded.entry(for: day).logs.first?.createdAt, date(7, hour: 15))
        XCTAssertEqual(reloaded.entry(for: day).logDraft, "未提交的下一条")
        XCTAssertTrue(reloaded.entry(for: date(8)).logs.isEmpty)
    }

    @MainActor
    func testDoneLogCompletesLinkedTaskAndRecurrenceInOneUndoStep() async throws {
        let store = JournalStore(directory: try directory())
        let scheduled = date(6)
        let logged = date(7)
        store.addTodo("论文阅读", on: scheduled)
        let task = try XCTUnwrap(store.entry(for: scheduled).todos.first)
        store.updateTodo(task.id, scheduledDate: scheduled, dueDate: nil, dueHasTime: false, reminderMinutes: nil, repeatRule: .daily)
        store.setLogTask(task.id, on: logged)
        store.setLogDraft("/done", on: logged)
        try store.commitLog(on: logged, now: logged)
        XCTAssertTrue(store.locate(task.id)!.task.completed)
        XCTAssertEqual(store.tasks().count, 2)
        let record = try XCTUnwrap(store.entry(for: logged).logs.first)
        XCTAssertEqual(record.text, "论文阅读")
        XCTAssertEqual(record.taskID, task.id)
        XCTAssertEqual(record.taskTitle, "论文阅读")
        store.setSummary("另外写的总结", on: logged)
        store.undo()
        XCTAssertFalse(store.locate(task.id)!.task.completed)
        XCTAssertEqual(store.tasks().count, 1)
        XCTAssertTrue(store.entry(for: logged).logs.isEmpty)
        XCTAssertEqual(store.entry(for: logged).logDraft, "/done")
        XCTAssertEqual(store.entry(for: logged).summary, "另外写的总结")
        store.redo()
        XCTAssertEqual(store.entry(for: logged).logs.first?.id, record.id)
        XCTAssertTrue(store.locate(task.id)!.task.completed)
        store.setLogTask(task.id, on: logged)
        store.setLogDraft("/done 再次确认", on: logged)
        try store.commitLog(on: logged, now: logged)
        XCTAssertTrue(store.locate(task.id)!.task.completed)
        XCTAssertEqual(store.tasks().count, 2)
        XCTAssertEqual(store.entry(for: logged).logs.count, 2)
    }

    @MainActor
    func testInvalidInputKeepsDraftAndNeverChangesTaskOrLogs() async throws {
        let store = JournalStore(directory: try directory())
        let day = date(7)
        store.setLogDraft("/unknown hello", on: day)
        store.save()
        let before = store.days
        XCTAssertThrowsError(try store.commitLog(on: day))
        XCTAssertEqual(store.days, before)
        store.setLogDraft("/done", on: day)
        XCTAssertThrowsError(try store.commitLog(on: day))
        XCTAssertEqual(store.entry(for: day).logDraft, "/done")
        store.setLogTask(UUID(), on: day)
        store.setLogDraft("/done missing", on: day)
        XCTAssertThrowsError(try store.commitLog(on: day))
        XCTAssertTrue(store.entry(for: day).logs.isEmpty)
    }

    @MainActor
    func testHelpAndRemovedSummaryCommandDoNotModifySummaryOrCreateLogs() async throws {
        let store = JournalStore(directory: try directory())
        let day = date(7)
        store.setSummary("保留", on: day)
        store.setLogDraft("/help", on: day)
        XCTAssertEqual(try store.commitLog(on: day), .help)
        store.setLogDraft("/summary", on: day)
        XCTAssertThrowsError(try store.commitLog(on: day))
        XCTAssertEqual(store.entry(for: day).summary, "保留")
        XCTAssertTrue(store.entry(for: day).logs.isEmpty)
    }

    @MainActor
    func testEditingDeletingAndUndoPreserveTimestampAndOtherDrafts() async throws {
        let store = JournalStore(directory: try directory())
        let day = date(7)
        store.setLogDraft("原记录", on: day)
        try store.commitLog(on: day, now: date(7, hour: 10))
        let record = try XCTUnwrap(store.entry(for: day).logs.first)
        store.updateLog(record.id, text: "修改记录", on: day)
        XCTAssertEqual(store.entry(for: day).logs.first?.createdAt, record.createdAt)
        store.updateLog(record.id, text: "", on: day)
        XCTAssertTrue(store.entry(for: day).logs.isEmpty)
        store.setLogDraft("删除后新写的草稿", on: day)
        store.undo()
        XCTAssertEqual(store.entry(for: day).logs.first?.text, "修改记录")
        XCTAssertEqual(store.entry(for: day).logDraft, "删除后新写的草稿")
        store.redo()
        XCTAssertTrue(store.entry(for: day).logs.isEmpty)
        XCTAssertEqual(store.entry(for: day).logDraft, "删除后新写的草稿")
    }

    @MainActor
    func testDeletedTaskKeepsLogReferenceSnapshot() async throws {
        let store = JournalStore(directory: try directory())
        let day = date(7)
        store.addTodo("[论文](https://example.com)", on: day)
        let task = try XCTUnwrap(store.entry(for: day).todos.first)
        store.setLogTask(task.id, on: day)
        store.setLogDraft("/block 尚未读完", on: day)
        try store.commitLog(on: day)
        XCTAssertFalse(store.locate(task.id)!.task.completed)
        store.deleteTodo(task.id, on: day)
        XCTAssertEqual(store.entry(for: day).logs.first?.taskTitle, "论文")
        XCTAssertEqual(store.entry(for: day).logs.first?.taskID, task.id)
        XCTAssertTrue(store.entry(for: day).hasContent)
    }

    @MainActor
    func testLogOnlyDayBackupPreviewAndRestore() async throws {
        let store = JournalStore(directory: try directory())
        let day = date(7)
        store.setLogDraft("只写日志", on: day)
        try store.commitLog(on: day)
        let snapshot = store.directory.appendingPathComponent("export.json")
        try store.export(to: snapshot)
        let preview = try store.inspectBackup(snapshot)
        XCTAssertEqual(preview.dayCount, 1)
        XCTAssertEqual(preview.logCount, 1)
        XCTAssertEqual(preview.summaryCount, 0)
        let record = try XCTUnwrap(store.entry(for: day).logs.first)
        store.deleteLog(record.id, on: day)
        XCTAssertTrue(store.days.isEmpty)
        try store.restore(from: snapshot)
        XCTAssertEqual(store.entry(for: day).logs, [record])
    }

    @MainActor func testAutosaveAndFinishEditingLogUndoAsOneStep() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let day = Date()
        store.setLogDraft("原文", on: day)
        _ = try store.commitLog(on: day, linkDefault: false)
        let id = try XCTUnwrap(store.entry(for: day).logs.first?.id)
        store.autosaveLog(id, text: "第一次", on: day)
        store.autosaveLog(id, text: "  ", on: day)
        XCTAssertEqual(store.entry(for: day).logs.first?.text, "第一次", "删空时不写")
        store.finishEditingLog(id, from: "原文", text: "第一次", on: day)
        store.undo()
        XCTAssertEqual(store.entry(for: day).logs.first?.text, "原文")
        store.redo()
        XCTAssertEqual(store.entry(for: day).logs.first?.text, "第一次")
        store.finishEditingLog(id, from: "第一次", text: "", on: day)
        XCTAssertTrue(store.entry(for: day).logs.isEmpty, "结束时是空的才删")
    }

    func testKeepingBothKeepsEveryVersion() {
        let merged = SyncMerge.keepingBoth(mine: "本机", theirs: "远端")
        XCTAssertTrue(merged.hasPrefix("本机\n\n") && merged.hasSuffix("\n\n远端") && merged.contains("同步冲突"), merged)
        XCTAssertEqual(SyncMerge.keepingBoth(mine: "本机和远端", theirs: "远端"), "本机和远端")
        XCTAssertEqual(SyncMerge.keepingBoth(mine: "本机", theirs: "本机和远端"), "本机和远端")
    }

    @MainActor func testFinishEditingSummaryCreatesAndUndoes() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let day = Date()
        store.setSummary("写到一半", on: day)
        store.finishEditingSummary(from: "", text: " 总结 \n", on: day)
        XCTAssertEqual(store.entry(for: day).summary, "总结")
        XCTAssertEqual(JournalStore(directory: directory).entry(for: day).summary, "总结")
        store.undo()
        XCTAssertEqual(store.entry(for: day).summary, "")
    }
}
