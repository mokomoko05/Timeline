import XCTest
@testable import TimelineCore

@MainActor
final class LogLinkTests: XCTestCase {
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!
    private var nextDay: Date { JournalDates.calendar.date(byAdding: .day, value: 1, to: day)! }

    private func makeStore() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        store.addTodo("读论文", on: day)
        store.addTodo("写周报", on: day)
        return store
    }

    private func submit(_ text: String, _ store: JournalStore, on date: Date? = nil) throws -> LogCommand {
        store.setLogDraft(text, on: date ?? day)
        return try store.commitLog(on: date ?? day)
    }

    func testParsesLinkUnlinkAndFilterCommands() throws {
        XCTAssertEqual(try LogCommand.parse("/link #1"), .link(1))
        XCTAssertEqual(try LogCommand.parse("/link 12"), .link(12))
        XCTAssertEqual(try LogCommand.parse("/link"), .link(nil))
        XCTAssertEqual(try LogCommand.parse("/unlink"), .link(nil))
        XCTAssertEqual(try LogCommand.parse("/filter #1 #3"), .filter([1, 3]))
        XCTAssertEqual(try LogCommand.parse("/filter 1，2"), .filter([1, 2]))
        XCTAssertEqual(try LogCommand.parse("/filter"), .filter([]))
        XCTAssertThrowsError(try LogCommand.parse("/link abc"))
        XCTAssertThrowsError(try LogCommand.parse("/filter #1 x"))
        XCTAssertTrue(LogCommand.commands.contains("/link") && LogCommand.commands.contains("/filter"))
    }

    func testSplitTaskReference() {
        XCTAssertEqual(LogCommand.splitTaskReference("#2 卡在配置").number, 2)
        XCTAssertEqual(LogCommand.splitTaskReference("#2 卡在配置").rest, "卡在配置")
        XCTAssertEqual(LogCommand.splitTaskReference("#3").rest, "")
        XCTAssertNil(LogCommand.splitTaskReference("# 标题").number)
        XCTAssertNil(LogCommand.splitTaskReference("修了 #2").number, "只识别开头的引用")
        XCTAssertNil(LogCommand.splitTaskReference("#2abc").number)
    }

    func testLinkCommandSetsDraftLinkAndFollowingLogsUseIt() throws {
        let store = makeStore()
        let first = store.entry(for: day).todos[0]
        XCTAssertEqual(try submit("/link #1", store), .link(1))
        XCTAssertEqual(store.entry(for: day).logTaskID, first.id)
        XCTAssertEqual(store.entry(for: day).logDraft, "")
        _ = try submit("读完第三节", store)
        let log = try XCTUnwrap(store.entry(for: day).logs.first)
        XCTAssertEqual(log.taskID, first.id)
        XCTAssertEqual(log.taskNumber, 1)
        XCTAssertNil(store.entry(for: day).logTaskID, "提交后清除关联，避免误关联")
        _ = try submit("/link #2", store)
        _ = try submit("/unlink", store)
        XCTAssertNil(store.entry(for: day).logTaskID)
        XCTAssertThrowsError(try submit("/link #9", store))
    }

    func testInlineReferenceLinksOnlyThatLogAndDoneCompletesTask() throws {
        let store = makeStore()
        let todos = store.entry(for: day).todos
        _ = try submit("/done #2 周报发出去了", store)
        var entry = store.entry(for: day)
        XCTAssertEqual(entry.logs[0].taskID, todos[1].id)
        XCTAssertEqual(entry.logs[0].text, "周报发出去了")
        XCTAssertTrue(entry.todos[1].completed)
        _ = try submit("#1 卡在环境配置", store)
        entry = store.entry(for: day)
        XCTAssertEqual(entry.logs[1].taskID, todos[0].id)
        XCTAssertEqual(entry.logs[1].text, "卡在环境配置")
        _ = try submit("/block #1", store)
        XCTAssertEqual(store.entry(for: day).logs[2].text, "读论文", "只有编号时用任务标题作为内容")
        XCTAssertThrowsError(try submit("/done #7 不存在", store), "命令里引用不存在的任务要报错")
        _ = try submit("#7 只是普通文字", store)
        XCTAssertEqual(store.entry(for: day).logs.last?.text, "#7 只是普通文字")
        XCTAssertNil(store.entry(for: day).logs.last?.taskID)
    }

    func testFilterByTasksCollectsLogsAcrossDaysInOrder() throws {
        let store = makeStore()
        let todos = store.entry(for: day).todos
        _ = try submit("/done #1 第一天进展", store)
        _ = try submit("#2 周报相关", store)
        store.addTodo("无关", on: nextDay)
        _ = try submit("无关记录", store, on: nextDay)
        // 同一任务跨日继续：把任务移到第二天再关联
        store.moveTodo(todos[0].id, to: nextDay)
        store.setLogTask(todos[0].id, on: nextDay)
        _ = try store.commitLogForTest(on: nextDay, text: "第二天继续")
        let first = store.logs(linkedTo: [todos[0].id])
        XCTAssertEqual(first.map(\.log.text), ["第一天进展", "第二天继续"])
        XCTAssertEqual(first.map(\.key), ["2026-10-07", "2026-10-08"])
        XCTAssertEqual(store.logs(linkedTo: [todos[0].id, todos[1].id]).count, 3)
        XCTAssertTrue(store.logs(linkedTo: []).isEmpty)
    }

    func testTaskSummariesListTodayTasksThenLoggedAndDeletedOnes() throws {
        let store = makeStore()
        let todos = store.entry(for: day).todos
        _ = try submit("/done #1 进展", store)
        store.deleteTodo(todos[0].id, on: day)
        let summaries = store.logTaskSummaries(on: day)
        XCTAssertEqual(summaries.first?.title, "写周报")
        XCTAssertEqual(summaries.first?.number, 2, "编号是永久的，删除 #1 后 #2 不会变成 #1")
        let deleted = try XCTUnwrap(summaries.first { $0.id == todos[0].id })
        XCTAssertTrue(deleted.deleted)
        XCTAssertEqual(deleted.count, 1)
        XCTAssertEqual(deleted.title, "读论文")
    }
}

private extension JournalStore {
    func commitLogForTest(on date: Date, text: String) throws -> LogCommand {
        setLogDraft(text, on: date)
        return try commitLog(on: date)
    }
}

extension LogLinkTests {
    func testHistoricalLogCanBeTaggedRetaggedAndUntaggedWithUndo() throws {
        let store = makeStore()
        let todos = store.entry(for: day).todos
        store.setLogDraft("一条没打标签的旧日志", on: day)
        try store.commitLog(on: day)
        let log = try XCTUnwrap(store.entry(for: day).logs.first)
        XCTAssertNil(log.taskID)
        store.setLogTask(todos[1].id, forLog: log.id, on: day)
        var updated = try XCTUnwrap(store.entry(for: day).logs.first)
        XCTAssertEqual(updated.taskID, todos[1].id)
        XCTAssertEqual(updated.taskNumber, 2)
        XCTAssertEqual(updated.taskTitle, "写周报")
        XCTAssertEqual(store.logs(linkedTo: [todos[1].id]).count, 1)
        store.setLogTask(todos[0].id, forLog: log.id, on: day)
        XCTAssertEqual(store.entry(for: day).logs.first?.taskNumber, 1)
        store.setLogTask(nil, forLog: log.id, on: day)
        updated = try XCTUnwrap(store.entry(for: day).logs.first)
        XCTAssertNil(updated.taskID)
        XCTAssertNil(updated.taskTitle)
        store.undo()
        XCTAssertEqual(store.entry(for: day).logs.first?.taskID, todos[0].id)
    }
}
