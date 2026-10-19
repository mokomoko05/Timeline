import XCTest
@testable import DayleafCore

@MainActor
final class NotesTests: XCTestCase {
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!
    private var tomorrow: Date { JournalDates.calendar.date(byAdding: .day, value: 1, to: day)! }

    private func makeStore() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory)
    }

    func testCachedNotebookSummariesRefreshForChangesUndoAndReload() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addParsedTodo("Read #paper", on: day))
        XCTAssertTrue(store.noteTopics().isEmpty)
        XCTAssertEqual(store.allTags().first?.noteCount, 0)
        XCTAssertTrue(store.timelineSegments().isEmpty)
        _ = try store.quickLog("Finding", taskID: task.id, on: day)
        XCTAssertEqual(store.noteTopics().first?.count, 1)
        XCTAssertEqual(store.allTags().first?.noteCount, 1)
        store.setLogDraft("unsent", on: day)
        XCTAssertEqual(store.noteTopics().first?.count, 1)
        store.setTags(task.id, ["reading"])
        XCTAssertEqual(store.noteTopics().first?.tags, ["reading"])
        XCTAssertEqual(store.allTags().first?.name, "reading")
        store.undo()
        XCTAssertEqual(store.noteTopics().first?.tags, ["paper"])
        XCTAssertEqual(store.allTags().first?.name, "paper")
        store.createTag("empty")
        XCTAssertTrue(store.allTags().contains { $0.name == "empty" })
        let start = try XCTUnwrap(store.addFocusLog("▶ 开始专注", taskID: task.id, event: .start))
        XCTAssertEqual(store.timelineSegments()[start]?.focusAfter, true)
        store.undo()
        XCTAssertNil(store.timelineSegments()[start])
        store.save()
        let reloaded = JournalStore(directory: store.directory, readOnlySnapshot: true)
        XCTAssertEqual(reloaded.noteTopics().first?.count, 1)
        XCTAssertEqual(Set(reloaded.allTags().map(\.name)), ["paper", "empty"])
    }

    func testNotesGatherLogsForOneTaskAcrossDaysWithStableNumber() throws {
        let store = makeStore()
        store.addTodo("读 EuroSys 论文", on: day)
        store.addTodo("写周报", on: day)
        let paper = try XCTUnwrap(store.locate(number: 1))
        _ = try store.quickLog("第一天：读完摘要", taskID: paper.id, on: day)
        _ = try store.quickLog("无关的随手记", on: day)
        store.setDeadline(paper.id, to: tomorrow)
        _ = try store.quickLog("/block 第二天：公式看不懂", taskID: paper.id, on: tomorrow)
        let notes = store.notes(for: paper.id)
        XCTAssertEqual(notes.map(\.log.text), ["第一天：读完摘要", "第二天：公式看不懂"])
        XCTAssertEqual(notes.map(\.key), ["2026-10-07", "2026-10-08"])
        XCTAssertEqual(notes.last?.log.kind, .block)
        XCTAssertEqual(notes.first?.log.taskNumber, 1, "笔记记录的是任务的永久编号")
        let topics = store.noteTopics()
        XCTAssertEqual(topics.count, 1)
        XCTAssertEqual(topics[0].count, 2)
        XCTAssertEqual(topics[0].number, 1)
    }

    func testFocusLogsAreHiddenFromNotesButStayInTheLogAndFilter() throws {
        let store = makeStore()
        store.addTodo("读论文 [链接](https://example.com)", on: day)
        let task = try XCTUnwrap(store.locate(number: 1))
        _ = try store.quickLog("一条真正的笔记", taskID: task.id, on: day)
        let now = JournalDates.calendar.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
        XCTAssertNotNil(store.addFocusLog("▶ 开始专注", taskID: task.id, now: now))
        store.addFocusLog("■ 结束专注 · 用时 25 分 0 秒 · 手动结束", taskID: task.id, now: now.addingTimeInterval(1500))
        XCTAssertEqual(store.notes(for: task.id).map(\.log.text), ["一条真正的笔记"], "专注记录不进入笔记")
        XCTAssertEqual(store.noteTopics().first?.count, 1)
        let key = JournalDates.key(now)
        let logs = try XCTUnwrap(store.days[key]?.logs)
        XCTAssertEqual(logs.filter(\.focus).count, 2, "终端日志里仍然有开始和结束")
        XCTAssertTrue(logs.filter(\.focus).allSatisfy { $0.taskID == task.id && $0.taskNumber == 1 })
        XCTAssertEqual(store.logs(linkedTo: [task.id]).filter(\.log.focus).count, 2, "按任务筛选日志时能看到专注记录")
    }

    func testFocusFlagSurvivesReloadAndOldLogsDefaultToNotFocus() throws {
        let store = makeStore()
        store.addTodo("任务", on: day)
        let id = try XCTUnwrap(store.locate(number: 1)).id
        store.addFocusLog("▶ 开始专注", taskID: id, now: Date())
        store.save()
        let reloaded = JournalStore(directory: store.directory)
        XCTAssertTrue(reloaded.days.values.flatMap(\.logs).allSatisfy(\.focus))
        let old = try JSONDecoder().decode(DailyLogEntry.self, from: Data(#"{"id":"4CC72FA1-6824-43AF-82D8-345E9C48588F","createdAt":0,"kind":"note","text":"旧"}"#.utf8))
        XCTAssertFalse(old.focus)
    }

    func testTopicsAreOrderedByMostRecentNoteAndKeepDeletedTasks() throws {
        let store = makeStore()
        store.addTodo("甲", on: day)
        store.addTodo("乙", on: day)
        let a = try XCTUnwrap(store.locate(number: 1)), b = try XCTUnwrap(store.locate(number: 2))
        _ = try store.quickLog("甲的笔记", taskID: a.id, on: day, now: day)
        _ = try store.quickLog("乙的笔记", taskID: b.id, on: day, now: day.addingTimeInterval(60))
        XCTAssertEqual(store.noteTopics().map(\.title), ["乙", "甲"])
        store.deleteTodo(a.id, on: day)
        let deleted = try XCTUnwrap(store.noteTopics().first { $0.id == a.id })
        XCTAssertTrue(deleted.deleted)
        XCTAssertEqual(deleted.title, "甲")
        XCTAssertEqual(deleted.number, 1)
    }
}

@MainActor
final class FocusTimeTests: XCTestCase {
    private func makeStore() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory)
    }

    func testFocusSecondsAccumulatePersistAndUndoTogetherWithTheLog() throws {
        let store = makeStore()
        store.addTodo("读论文", on: Date())
        let id = try XCTUnwrap(store.locate(number: 1)).id
        store.addFocusLog("■ 一", taskID: id, seconds: 600)
        store.addFocusLog("■ 二", taskID: id, seconds: 900)
        XCTAssertEqual(store.locate(id)?.task.focusSeconds, 1500)
        XCTAssertEqual(store.noteTopics().count, 0, "专注记录不产生笔记主题")
        store.save()
        XCTAssertEqual(JournalStore(directory: store.directory).locate(id)?.task.focusSeconds, 1500)
        store.undo()
        XCTAssertEqual(store.locate(id)?.task.focusSeconds, 600, "撤销专注记录时累计时长一并还原")
        let outsideNotes = store.notes(for: id)
        XCTAssertTrue(outsideNotes.isEmpty)
    }

    func testTopicShowsFocusTimeAndZeroSecondsDoNotChangeTheTask() throws {
        let store = makeStore()
        store.addTodo("任务", on: Date())
        let id = try XCTUnwrap(store.locate(number: 1)).id
        _ = try store.quickLog("一条笔记", taskID: id, on: Date())
        store.addFocusLog("▶ 开始专注", taskID: id)
        XCTAssertEqual(store.locate(id)?.task.focusSeconds, 0)
        store.addFocusLog("■ 结束", taskID: id, seconds: 1234)
        XCTAssertEqual(store.noteTopics().first?.focusSeconds, 1234)
        let old = try JSONDecoder().decode(Todo.self, from: Data(#"{"id":"4CC72FA1-6824-43AF-82D8-345E9C48588F","title":"旧","completed":false}"#.utf8))
        XCTAssertEqual(old.focusSeconds, 0)
    }
}
