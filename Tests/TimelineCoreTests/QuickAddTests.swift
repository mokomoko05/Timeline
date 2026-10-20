import XCTest
@testable import TimelineCore

final class QuickAddTests: XCTestCase {
    // 2026-10-07 是周三。
    private let now = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 10))!

    private func date(_ month: Int, _ day: Int) -> Date {
        JournalDates.calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    func testTomorrowWithTime() {
        let parsed = QuickAdd.parse("明天 15:00 开会", now: now)
        XCTAssertEqual(parsed.title, "开会")
        XCTAssertEqual(parsed.day, date(10, 8))
        XCTAssertEqual(parsed.hour, 15)
        XCTAssertEqual(parsed.minute, 0)
    }

    func testWeekdayAfternoonAndReminder() {
        let parsed = QuickAdd.parse("周五 下午3点半 评审 提前30分钟", now: now)
        XCTAssertEqual(parsed.title, "评审")
        XCTAssertEqual(parsed.day, date(10, 9))
        XCTAssertEqual(parsed.hour, 15)
        XCTAssertEqual(parsed.minute, 30)
        XCTAssertEqual(parsed.reminderMinutes, 30)
    }

    func testNextWeekAndPastWeekdayRollForward() {
        XCTAssertEqual(QuickAdd.parse("下周一 交报告", now: now).day, date(10, 12))
        XCTAssertEqual(QuickAdd.parse("周一 交报告", now: now).day, date(10, 12))
        XCTAssertEqual(QuickAdd.parse("本周一 复盘", now: now).day, date(10, 5))
    }

    func testRepeatRules() {
        let weekly = QuickAdd.parse("每周一 站会", now: now)
        XCTAssertEqual(weekly.repeatRule, .weekly)
        XCTAssertEqual(weekly.day, date(10, 12))
        XCTAssertEqual(weekly.title, "站会")
        XCTAssertEqual(QuickAdd.parse("每天 背单词", now: now).repeatRule, .daily)
        XCTAssertEqual(QuickAdd.parse("每个工作日 打卡", now: now).repeatRule, .weekdays)
        let monthly = QuickAdd.parse("每月15号 交房租", now: now)
        XCTAssertEqual(monthly.repeatRule, .monthly)
        XCTAssertEqual(monthly.day, date(10, 15))
    }

    func testMonthDayAndRelativeDays() {
        XCTAssertEqual(QuickAdd.parse("10月20日 买票", now: now).day, date(10, 20))
        XCTAssertEqual(QuickAdd.parse("3天后 取快递", now: now).day, date(10, 10))
        XCTAssertEqual(QuickAdd.parse("2026-11-02 签证", now: now).day, date(11, 2))
    }

    func testLeavesOrdinaryTextAndLinksAlone() {
        for text in ["完成 1/2 章", "读论文 [arxiv](https://a.b/2026-10-08)", "买牛奶", "https://example.com/12:30"] {
            let parsed = QuickAdd.parse(text, now: now)
            XCTAssertEqual(parsed.title, text)
            XCTAssertFalse(parsed.hasSchedule, text)
        }
    }

    func testDateOnlyTextKeepsOriginalTitle() {
        let parsed = QuickAdd.parse("明天", now: now)
        XCTAssertEqual(parsed.title, "明天")
        XCTAssertFalse(parsed.hasSchedule)
    }

    func testResolveSetsDueOnlyWhenScheduled() {
        let plain = QuickAdd.parse("买牛奶", now: now).resolve(defaultDay: date(10, 7))
        XCTAssertNil(plain.todo.dueDate)
        let timed = QuickAdd.parse("明天 9点 站会 提前15分钟", now: now).resolve(defaultDay: date(10, 7))
        XCTAssertEqual(timed.day, date(10, 8))
        XCTAssertTrue(timed.todo.dueHasTime)
        XCTAssertEqual(timed.todo.reminderMinutes, 15)
        XCTAssertEqual(JournalDates.calendar.component(.hour, from: timed.todo.dueDate!), 9)
    }

    @MainActor
    func testCommitDraftCreatesIndependentTaskWithParsedDateAsDeadline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        store.setDeadlineDraft("明天 开会\n买牛奶", on: date(10, 7))
        let added = store.commitDraft(on: date(10, 7), now: now)
        XCTAssertEqual(added.map(\.task.title), ["开会", "买牛奶"])
        XCTAssertEqual(added.map(\.task.number), [1, 2], "任务有永久编号")
        XCTAssertEqual(added[0].task.dueDate, date(10, 8), "识别出的日期是截止日期")
        XCTAssertNil(added[1].task.dueDate, "没写日期的任务先不分配日期")
        XCTAssertEqual(store.entry(for: date(10, 7)).deadlineDraft, "")
        XCTAssertEqual(store.sortedTasks().map(\.task.title), ["开会", "买牛奶"], "有截止日期的在前，没有的在最后")
        store.undo()
        XCTAssertTrue(store.tasks().isEmpty)
    }

    @MainActor
    func testRolloverMovesOverdueDeadlinesToTodayAsOneUndo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        store.addTodo("昨天截止未完成", on: date(10, 1))
        store.addTodo("昨天截止已完成", on: date(10, 1))
        store.addTodo("明天截止", on: date(10, 1))
        let todos = store.entry(for: date(10, 1)).todos
        store.setDeadline(todos[0].id, to: date(10, 6))
        store.setDeadline(todos[1].id, to: date(10, 6))
        store.setDeadline(todos[2].id, to: date(10, 8))
        store.toggleTodo(todos[1].id, on: date(10, 1))
        XCTAssertEqual(store.unfinishedCount(before: date(10, 7)), 1)
        XCTAssertEqual(store.rolloverUnfinished(to: date(10, 7)), 1)
        XCTAssertEqual(store.locate(todos[0].id)?.task.dueDate, date(10, 7))
        XCTAssertEqual(store.locate(todos[1].id)?.task.dueDate, date(10, 6), "已完成的不动")
        XCTAssertEqual(store.locate(todos[2].id)?.task.dueDate, date(10, 8))
        XCTAssertEqual(store.lastAction?.name, "移到今天")
        store.undo()
        XCTAssertEqual(store.locate(todos[0].id)?.task.dueDate, date(10, 6))
    }

    @MainActor
    func testDestructiveActionsReportNamedEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        store.addTodo("a", on: now)
        let id = store.entry(for: now).todos[0].id
        store.deleteTodo(id, on: now)
        XCTAssertEqual(store.lastAction?.name, "删除任务")
        let first = store.lastAction?.id
        store.undo()
        XCTAssertEqual(store.lastAction?.id, first, "撤销本身不应再产生提示")
        _ = try store.quickLog("/block 卡住了", on: now)
        XCTAssertEqual(store.entry(for: now).logs.first?.kind, .block)
    }

    func testMonthGridHonoursWeekStart() {
        let monday = JournalDates.monthGrid(date(10, 1), weekStart: 2)
        let sunday = JournalDates.monthGrid(date(10, 1), weekStart: 1)
        XCTAssertEqual(JournalDates.calendar.component(.weekday, from: monday[0]), 2)
        XCTAssertEqual(JournalDates.calendar.component(.weekday, from: sunday[0]), 1)
        XCTAssertEqual(monday.count % 7, 0)
        XCTAssertEqual(sunday.count % 7, 0)
    }
}

final class DeadlineModelTests: XCTestCase {
    private func date(_ month: Int, _ day: Int) -> Date {
        JournalDates.calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    @MainActor
    private func store(_ file: String? = nil) throws -> (JournalStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        if let file {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(file.utf8).write(to: directory.appendingPathComponent("journal.json"))
        }
        return (JournalStore(directory: directory), directory)
    }

    @MainActor
    func testNumbersAreCreationOrderAndNeverReused() throws {
        let (store, directory) = try store()
        store.addTodo("甲", on: date(10, 7))
        store.addTodo("乙", on: date(10, 7))
        let ids = store.entry(for: date(10, 7)).todos.map(\.id)
        store.deleteTodo(ids[1], on: date(10, 7))
        store.addTodo("丙", on: date(10, 8))
        XCTAssertEqual(store.sortedTasks().map(\.task.number), [1, 3], "删除 #2 后新任务是 #3，不复用")
        store.setDeadline(ids[0], to: date(10, 20))
        XCTAssertEqual(store.locate(ids[0])?.task.number, 1, "改截止日期不改编号")
        XCTAssertEqual(store.locate(number: 3)?.task.title, "丙")
        store.save()
        let reloaded = JournalStore(directory: directory)
        reloaded.addTodo("丁", on: date(10, 9))
        XCTAssertEqual(reloaded.sortedTasks().compactMap(\.task.number).max(), 4)
    }

    @MainActor
    func testSortedByDeadlineThenUndatedLast() throws {
        let (store, _) = try store()
        for title in ["无日期", "后天", "昨天", "明天上午"] { store.addTodo(title, on: date(10, 7)) }
        let todos = store.entry(for: date(10, 7)).todos
        store.setDeadline(todos[1].id, to: date(10, 9))
        store.setDeadline(todos[2].id, to: date(10, 6))
        store.setDeadline(todos[3].id, to: date(10, 8))
        XCTAssertEqual(store.sortedTasks().map(\.task.title), ["昨天", "明天上午", "后天", "无日期"])
        store.setDeadline(todos[1].id, to: nil)
        XCTAssertEqual(Set(store.sortedTasks().suffix(2).map(\.task.title)), ["后天", "无日期"])
        XCTAssertNil(store.locate(todos[1].id)?.task.dueDate)
    }

    @MainActor
    func testSettingDeadlineKeepsTimeOfDayWhenAsked() throws {
        let (store, _) = try store()
        store.addTodo("开会", on: date(10, 7))
        let id = store.entry(for: date(10, 7)).todos[0].id
        let at3pm = JournalDates.calendar.date(bySettingHour: 15, minute: 30, second: 0, of: date(10, 8))!
        store.updateTodo(id, scheduledDate: date(10, 7), dueDate: at3pm, dueHasTime: true, reminderMinutes: 15, repeatRule: .none)
        store.setDeadline(id, to: date(10, 12))
        let moved = try XCTUnwrap(store.locate(id)?.task)
        XCTAssertEqual(JournalDates.calendar.component(.day, from: moved.dueDate!), 12)
        XCTAssertEqual(JournalDates.calendar.component(.hour, from: moved.dueDate!), 15)
        XCTAssertEqual(moved.reminderMinutes, 15)
        store.setDeadline(id, to: date(10, 13), keepingTime: false)
        XCTAssertFalse(store.locate(id)!.task.dueHasTime)
    }

    @MainActor
    func testOldDataMigratesScheduledDayToDeadlineAndKeepsAnOriginalCopy() throws {
        let old = """
        {"version":5,"days":{"2026-10-06":{"todos":[{"id":"00000000-0000-0000-0000-000000000001","title":"旧任务","completed":false},\
        {"id":"00000000-0000-0000-0000-000000000002","title":"已有截止","completed":false,"dueDate":813000000}],"summary":""}}}
        """
        let (store, directory) = try store(old)
        let tasks = store.sortedTasks()
        let migrated = try XCTUnwrap(tasks.first { $0.task.title == "旧任务" })
        XCTAssertEqual(migrated.task.dueDate, date(10, 6), "旧版本里所在的那一天成为截止日期")
        XCTAssertEqual(tasks.first { $0.task.title == "已有截止" }?.task.dueDate, Date(timeIntervalSinceReferenceDate: 813000000), "已有截止日期不改")
        XCTAssertEqual(tasks.compactMap(\.task.number).sorted(), [1, 2])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.backupsDirectory.appendingPathComponent("before-ddl-migration-v5.json").path))
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("journal.json"))) as? [String: Any]
        XCTAssertEqual(raw?["version"] as? Int, 6)
        // 再次打开不会重复迁移：清除截止日期后保持无日期。
        store.setDeadline(migrated.id, to: nil)
        let reopened = JournalStore(directory: directory)
        XCTAssertNil(reopened.locate(migrated.id)?.task.dueDate)
    }
}
