import XCTest
@testable import TimelineCore

@MainActor
final class DropTests: XCTestCase {
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!
    private var directory: URL!

    private func makeStore() -> JournalStore {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { [directory] in if let directory { try? FileManager.default.removeItem(at: directory) } }
        return JournalStore(directory: directory)
    }

    func testDropClosesWithoutCountingAsDoneAndRestoresOnSecondCall() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addParsedTodo("调研方案 B", on: day)).task
        let id = task.id
        let date = store.locate(id)!.date
        XCTAssertTrue(store.dropTodo(id, on: date))
        var now = store.locate(id)!.task
        XCTAssertTrue(now.isDropped)
        XCTAssertTrue(now.completed, "放弃的也是「已关闭」，所有未完成筛选自然排除它")
        XCTAssertFalse(now.isDone, "但不算完成")
        XCTAssertEqual(store.entry(for: date).completedCount, 0, "不计入完成数")

        // 点圆圈（toggle）和再次放弃都是恢复。
        store.toggleTodo(id, on: date)
        now = store.locate(id)!.task
        XCTAssertFalse(now.completed)
        XCTAssertFalse(now.dropped, "恢复后不留放弃标记")

        XCTAssertTrue(store.dropTodo(id, on: date))
        XCTAssertTrue(store.dropTodo(id, on: date), "已放弃的再放弃一次就是恢复")
        XCTAssertFalse(store.locate(id)!.task.completed)
    }

    func testFinishedTaskCannotBeDroppedAndDoneThenUndoneNeverLeavesDropped() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.addParsedTodo("写周报", on: day)).task.id
        let date = store.locate(id)!.date
        store.toggleTodo(id, on: date)
        XCTAssertTrue(store.locate(id)!.task.isDone)
        XCTAssertFalse(store.dropTodo(id, on: date), "已完成的不能放弃")
        store.toggleTodo(id, on: date)
        XCTAssertFalse(store.locate(id)!.task.dropped)
    }

    func testDroppedKeepsNotesNumberAndLeavesOpenListsAndPin() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.addParsedTodo("方案 B #调研", on: day)).task.id
        _ = store.addParsedTodo("方案 A #调研", on: day)
        _ = try store.quickLog("试了一下，不行", taskID: id, on: day, now: day.addingTimeInterval(1))
        store.pinTask(id)
        store.dropTodo(id, on: store.locate(id)!.date)

        XCTAssertNotNil(store.locate(id), "没有删除：还在")
        XCTAssertEqual(store.locate(id)?.task.number, 1)
        XCTAssertEqual(store.notes(for: id).count, 1, "笔记还关联着它")
        let topic = try XCTUnwrap(store.noteTopics().first { $0.id == id })
        XCTAssertTrue(topic.dropped)
        XCTAssertFalse(topic.deleted)
        XCTAssertNil(store.pinnedTask, "放弃后固定自动取消")
        XCTAssertFalse(store.linkCandidates().contains { $0.id == id }, "不再出现在 @ 候选里")
        XCTAssertTrue(store.linkCandidates(includeCompleted: true).contains { $0.id == id })
        let chapter = try XCTUnwrap(store.chapters(forTag: "调研").first { $0.taskID == id })
        XCTAssertTrue(chapter.dropped)
        XCTAssertEqual(store.allTags().first { $0.name == "调研" }?.openCount, 1, "标签的未完成数不含放弃的")
        XCTAssertEqual(store.unfinishedCount(before: day.addingTimeInterval(86400 * 30)), 0, "放弃的也永远不会逾期")
    }

    func testDroppedPersistsAcrossReloadAndOldDataDecodesAsNotDropped() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.addParsedTodo("不做了", on: day)).task.id
        store.dropTodo(id, on: store.locate(id)!.date)
        store.save()
        let reloaded = JournalStore(directory: directory)
        XCTAssertTrue(reloaded.locate(id)!.task.isDropped, "重启后仍是已放弃")

        let legacy = #"{"id":"\#(UUID().uuidString)","title":"旧数据","completed":true}"#
        let old = try JSONDecoder().decode(Todo.self, from: Data(legacy.utf8))
        XCTAssertTrue(old.isDone, "没有 dropped 字段的旧数据就是普通完成")
        let inconsistent = #"{"id":"\#(UUID().uuidString)","title":"x","completed":false,"dropped":true}"#
        XCTAssertFalse(try JSONDecoder().decode(Todo.self, from: Data(inconsistent.utf8)).dropped, "未完成的不可能是放弃的")
    }

    func testDroppingARepeatingTaskSkipsThisOccurrenceAndSchedulesTheNext() throws {
        let store = makeStore()
        let added = try XCTUnwrap(store.addParsedTodo("读论文 每天", on: day))
        XCTAssertEqual(added.task.repeatRule, .daily)
        let date = added.date
        store.dropTodo(added.id, on: date, now: day)
        XCTAssertNotNil(store.locate(added.id)?.task.nextOccurrenceID, "放弃这一次，下一次照常生成")
        let next = store.tasks().filter { $0.task.title == added.task.title && !$0.task.completed }
        XCTAssertEqual(next.count, 1)
        XCTAssertFalse(next[0].task.dropped)
    }

    func testReviewDoesNotListDroppedAsDone() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.addParsedTodo("做完的", on: day)).task.id
        let b = try XCTUnwrap(store.addParsedTodo("放弃的", on: day)).task.id
        store.toggleTodo(a, on: store.locate(a)!.date)
        store.dropTodo(b, on: store.locate(b)!.date)
        let entry = store.entry(for: store.locate(a)!.date)
        let text = DailyReview.render(entry)
        XCTAssertTrue(text.contains("做完的"))
        XCTAssertFalse(text.contains("放弃的"), "复盘的「完成」里不出现放弃的")
    }
}

@MainActor
final class TaskSummaryTests: XCTestCase {
    func testSummaryCountsOverdueTodayOpenAndTodayProgressOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let calendar = JournalDates.calendar
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 14))!
        func add(_ title: String, due: Int?) -> UUID {
            let id = store.addParsedTodo(title, on: now)!.id
            if let due { store.setDeadline(id, to: calendar.date(byAdding: .day, value: due, to: calendar.startOfDay(for: now))!) }
            return id
        }
        _ = add("昨天没做", due: -1)
        _ = add("前天没做", due: -2)
        let doneToday = add("今天做完了", due: 0)
        _ = add("今天还没做", due: 0)
        let droppedToday = add("今天放弃的", due: 0)
        _ = add("明天", due: 1)
        _ = add("没有日期", due: nil)
        let doneEarlier = add("以前做完的", due: -3)
        store.toggleTodo(doneToday, on: store.locate(doneToday)!.date, now: now)
        store.toggleTodo(doneEarlier, on: store.locate(doneEarlier)!.date, now: now)
        store.dropTodo(droppedToday, on: store.locate(droppedToday)!.date, now: now)

        let summary = store.taskSummary(now: now)
        XCTAssertEqual(summary.overdue, 2)
        XCTAssertEqual(summary.dueToday, 1, "今天截止且没做的（放弃的、做完的不算）")
        XCTAssertEqual(summary.open, 5, "2 逾期 + 今天 1 + 明天 + 没日期")
        XCTAssertEqual(summary.totalToday, 2, "今天的进度只统计今天截止的，放弃的不算")
        XCTAssertEqual(summary.doneToday, 1)
        XCTAssertEqual(summary.todayFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(TaskSummary(overdue: 0, dueToday: 0, open: 0, doneToday: 0, totalToday: 0).todayFraction, 0)
    }
}
