import XCTest
@testable import TimelineCore

@MainActor
final class PinAndMentionTests: XCTestCase {
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!
    private var directory: URL!

    private func makeStore(titles: [String] = ["读论文 #论文", "写周报", "整理发票", "复习 英语"]) -> JournalStore {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { [directory] in if let directory { try? FileManager.default.removeItem(at: directory) } }
        let store = JournalStore(directory: directory)
        for title in titles { _ = store.addParsedTodo(title, on: day) }
        return store
    }

    private func id(_ store: JournalStore, _ number: Int) -> UUID { store.locate(number: number)!.id }

    // MARK: - 固定关联

    func testPinnedTaskIsTheDefaultLinkButFocusAndExplicitWin() throws {
        let store = makeStore()
        XCTAssertTrue(store.pinTask(id(store, 2)))
        _ = try store.quickLog("固定期间的日志", on: day, now: day.addingTimeInterval(1))
        XCTAssertEqual(store.allLogs().last?.log.taskNumber, 2, "没指定、没专注时，记到固定的待办")

        store.setFocusTask(id(store, 3))
        _ = try store.quickLog("专注期间", on: day, now: day.addingTimeInterval(2))
        XCTAssertEqual(store.allLogs().last?.log.taskNumber, 3, "专注中的优先于固定的")
        store.setFocusTask(nil)

        _ = try store.quickLog("显式", taskID: id(store, 1), on: day, now: day.addingTimeInterval(3))
        XCTAssertEqual(store.allLogs().last?.log.taskNumber, 1, "明确指定的最优先")

        _ = try store.quickLog("不关联", linkDefault: false, on: day, now: day.addingTimeInterval(4))
        XCTAssertNil(store.allLogs().last?.log.taskID, "明确不关联就不关联")
        XCTAssertEqual(store.pinnedTask?.task.number, 2, "不关联不会取消固定")
    }

    func testPausedFocusDoesNotProvideAnAutomaticLogLink() throws {
        let store = makeStore()
        let focused = id(store, 3)
        store.setFocusTask(focused)
        store.setFocusPaused(true)
        _ = try store.quickLog("暂停期间的日志", on: day, now: day.addingTimeInterval(5))
        XCTAssertNil(store.allLogs().last?.log.taskID)
        XCTAssertNil(store.defaultLinkTask)
        store.setFocusPaused(false)
        _ = try store.quickLog("恢复后的日志", on: day, now: day.addingTimeInterval(6))
        XCTAssertEqual(store.allLogs().last?.log.taskID, focused)
    }

    func testPinSurvivesCompletionAndReloadButClearsWhenDeleted() throws {
        let store = makeStore()
        store.pinTask(id(store, 2))
        XCTAssertEqual(JournalStore(directory: directory).pinnedTask?.task.number, 2, "固定写进数据文件，重启后还在")

        store.toggleTodo(id(store, 2), on: day)
        XCTAssertEqual(store.pinnedTask?.id, id(store, 2), "完成后仍固定")
        XCTAssertEqual(JournalStore(directory: directory).pinnedTask?.id, id(store, 2))
        _ = try store.quickLog("完成后的补记", on: day)
        XCTAssertEqual(store.allLogs().last?.log.taskID, id(store, 2))
        store.toggleTodo(id(store, 2), on: day)
        XCTAssertEqual(store.pinnedTask?.id, id(store, 2))

        XCTAssertFalse(store.pinTask(UUID()), "不存在的待办不能固定")
        store.toggleTodo(id(store, 3), on: day)
        XCTAssertTrue(store.pinTask(id(store, 3)), "已完成的待办也能固定")

        store.pinTask(id(store, 4))
        store.deleteTodo(id(store, 4), on: store.locate(number: 4)!.date)
        XCTAssertNil(store.pinnedTask)
        XCTAssertTrue(store.pinTask(nil))
    }

    func testDayLogCommitFallsBackToPinnedToo() throws {
        let store = makeStore()
        store.pinTask(id(store, 2))
        store.setLogDraft("日志窗口里写的", on: day)
        _ = try store.commitLog(on: day)
        XCTAssertEqual(store.allLogs().last?.log.taskNumber, 2)
        store.setLogDraft("#1 明确指定", on: day)
        _ = try store.commitLog(on: day)
        XCTAssertEqual(store.allLogs().last?.log.taskNumber, 1, "正文里的 #N 优先于固定")
    }

    // MARK: - 快速日志里的 #N

    func testQuickLogUnderstandsLeadingTaskReference() throws {
        let store = makeStore()
        _ = try store.quickLog("#2 周报写了一半", on: day, now: day.addingTimeInterval(1))
        var last = store.allLogs().last!.log
        XCTAssertEqual(last.taskNumber, 2)
        XCTAssertEqual(last.text, "周报写了一半", "开头的 #N 变成关联，不留在正文里")

        _ = try store.quickLog("#2", on: day, now: day.addingTimeInterval(2))
        last = store.allLogs().last!.log
        XCTAssertEqual(last.text, "#2", "只有 #N 没有内容时当作普通文字")
        XCTAssertNil(last.taskID)

        _ = try store.quickLog("#99 不存在的编号", on: day, now: day.addingTimeInterval(3))
        last = store.allLogs().last!.log
        XCTAssertEqual(last.text, "#99 不存在的编号")
        XCTAssertNil(last.taskID)

        _ = try store.quickLog("#2 显式的优先", taskID: id(store, 1), on: day, now: day.addingTimeInterval(4))
        last = store.allLogs().last!.log
        XCTAssertEqual(last.taskNumber, 1, "明确传入的任务优先于正文里的 #N")
        XCTAssertEqual(last.text, "#2 显式的优先")
    }

    func testQuickLogEntryReportsWhereTheLogLanded() throws {
        let store = makeStore()
        store.pinTask(id(store, 4))
        var result = try store.quickLogEntry("甲", on: day, now: day.addingTimeInterval(1))
        XCTAssertEqual(result.entry?.taskNumber, 4)
        result = try store.quickLogEntry("乙", linkDefault: false, on: day, now: day.addingTimeInterval(2))
        XCTAssertNil(result.entry?.taskID)
        let command = try store.quickLogEntry("/help", on: day)
        XCTAssertNil(command.entry, "不是普通记录就没有日志")
    }

    // MARK: - 智能候选

    func testCandidatesMatchPinyinInitialsAndMissingCharacters() {
        let store = makeStore()
        func numbers(_ query: String) -> [Int] { store.linkCandidates(query: query).compactMap(\.task.number) }
        XCTAssertEqual(numbers("dlw"), [1], "拼音首字母")
        XCTAssertEqual(numbers("lunwen"), [1], "全拼")
        XCTAssertEqual(numbers("DLW"), [1], "不分大小写")
        XCTAssertEqual(numbers("zbz"), [], "不相干的首字母没有结果")
        XCTAssertEqual(numbers("zhoubao"), [2])
        XCTAssertEqual(numbers("读文"), [1], "漏字也能找到")
        XCTAssertEqual(numbers("英语"), [4])
        XCTAssertEqual(numbers("fx"), [4], "复习的首字母 fx 对应「复习」")
        XCTAssertTrue(numbers("").count == 4)
    }

    func testWarmedPinyinGivesTheSameMatches() async {
        let store = makeStore(titles: ["整理行李 #旅行", "同步日历"])
        await store.warmLinkMatching()
        XCTAssertEqual(store.linkCandidates(query: "zlxl").compactMap(\.task.number), [1], "后台先转好的拼音首字母")
        XCTAssertEqual(store.linkCandidates(query: "tongbu").compactMap(\.task.number), [2], "后台先转好的全拼")
        XCTAssertEqual(store.tagCandidates(query: "lx").first?.name, "旅行", "标签也按拼音找")
    }

    func testCandidatesPreferStrongMatchesAndNumberExact() {
        let store = makeStore(titles: ["周报模板", "写周报", "报销", "10 号结算"])
        func numbers(_ query: String) -> [Int] { store.linkCandidates(query: query).compactMap(\.task.number) }
        XCTAssertEqual(numbers("周报").first, 1, "开头匹配排在包含之前")
        XCTAssertEqual(numbers("#4").first, 4, "编号精确命中最前")
        XCTAssertEqual(numbers("1").first, 1)
        XCTAssertEqual(numbers("10").first, 4, "标题里的 10 也算，但编号 10 不存在，不抢第一")
    }

    func testCandidatesRankFocusPinnedContextRecentInThatOrder() throws {
        let store = makeStore(titles: ["甲 #论文", "乙 #读书", "丙 #论文/方法", "丁", "戊"])
        _ = try store.quickLog("x", taskID: id(store, 5), on: day, now: day.addingTimeInterval(1))
        store.setFocusTask(id(store, 4))
        store.pinTask(id(store, 2))
        func numbers(_ context: [String]) -> [Int] { store.linkCandidates(contextTags: context).compactMap(\.task.number) }
        XCTAssertEqual(numbers([]), [4, 2, 5, 1, 3], "专注 → 固定 → 最近 → 其余按清单顺序")
        XCTAssertEqual(numbers(["论文"]), [4, 2, 1, 3, 5], "写在 #论文 下时，带这个标签（含子标签）的排在最近之前")
    }

    func testFuzzyMatchesComeAfterLiteralOnes() {
        let store = makeStore(titles: ["读论文", "读一篇关于论述的文章", "文论"])
        let order = store.linkCandidates(query: "读论文").compactMap(\.task.number)
        XCTAssertEqual(order.first, 1)
        let fuzzy = store.linkCandidates(query: "读文").compactMap(\.task.number)
        XCTAssertEqual(Set(fuzzy), [1, 2], "读…文 按顺序出现的都算")
        XCTAssertFalse(fuzzy.contains(3), "顺序不对不算")
    }

    // MARK: - 日志窗口的 # 标签草稿

    func testDayLogDraftTagsAreCommittedKeptOnFailureAndPersisted() throws {
        let store = makeStore()
        store.addDraftTag("#论文", on: day)
        store.addDraftTag("论文", on: day)
        store.addDraftTag("读书/笔记", on: day)
        store.addDraftTag("3", on: day)
        XCTAssertEqual(store.entry(for: day).logDraftTags, ["论文", "读书/笔记"], "去重，纯数字不是标签")

        store.setLogDraft("", on: day)
        XCTAssertThrowsError(try store.commitLog(on: day), "空内容提交失败")
        XCTAssertEqual(store.entry(for: day).logDraftTags, ["论文", "读书/笔记"], "失败时草稿里的标签还在")

        store.save()
        XCTAssertEqual(JournalStore(directory: directory).entry(for: day).logDraftTags, ["论文", "读书/笔记"], "标签草稿随数据保存，重启还在")

        store.removeDraftTag("读书/笔记", on: day)
        store.setLogDraft("写了一段", on: day)
        _ = try store.commitLog(on: day)
        let log = try XCTUnwrap(store.allLogs().last?.log)
        XCTAssertEqual(log.tags, ["论文"], "提交后成为这条日志自己的标签")
        XCTAssertEqual(store.notes(forTag: "论文").map(\.log.id), [log.id], "能从标签里检索到")
        XCTAssertTrue(store.entry(for: day).logDraftTags.isEmpty, "提交后清空")
    }

    func testOnlyTagsWithoutTextStillNeedsContent() throws {
        let store = makeStore()
        store.addDraftTag("论文", on: day)
        store.setLogDraft("", on: day)
        XCTAssertThrowsError(try store.commitLog(on: day))
        XCTAssertTrue(store.entry(for: day).hasContent, "只选了标签也算有草稿，不会被当成空的一天清掉")
    }
}

@MainActor
final class ClosedTasksInMentionTests: XCTestCase {
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!

    func testClosedAndDroppedTasksAreFoundButRankAfterOpenOnes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        for title in ["论文 初稿", "论文 终稿", "论文 参考文献", "写周报"] { _ = store.addParsedTodo(title, on: day) }
        func id(_ n: Int) -> UUID { store.locate(number: n)!.id }
        store.toggleTodo(id(1), on: store.locate(number: 1)!.date)          // 做完了
        store.dropTodo(id(2), on: store.locate(number: 2)!.date)            // 放弃了

        func numbers(_ query: String, closed: Bool = true) -> [Int] {
            store.linkCandidates(query: query, includeCompleted: closed).compactMap(\.task.number)
        }
        XCTAssertEqual(numbers("论文", closed: false), [3], "不带 includeCompleted 时仍只有未完成的（选择器默认行为不变）")
        XCTAssertEqual(numbers("论文"), [3, 1, 2], "已完成、已放弃的也能搜到，排在未完成的后面")
        XCTAssertEqual(numbers("lw"), [3, 1, 2], "拼音首字母同样")
        XCTAssertEqual(numbers("#1").first, 1, "编号精确命中排第一，哪怕它已经完成")
        XCTAssertEqual(numbers("#2").first, 2, "已放弃的也一样")
        XCTAssertEqual(numbers("").prefix(2), [3, 4], "不输入查询词时，未完成的在最前")
    }

    func testLoggingAgainstAClosedTaskStillWorks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let done = try XCTUnwrap(store.addParsedTodo("交报销单", on: day)).task.id
        let dropped = try XCTUnwrap(store.addParsedTodo("交报销材料", on: day)).task.id
        store.toggleTodo(done, on: store.locate(done)!.date)
        store.dropTodo(dropped, on: store.locate(dropped)!.date)
        _ = try store.quickLog("补记", taskID: done, on: day)   // 选中已完成的任务也能记日志
        XCTAssertEqual(store.allLogs().last?.log.taskID, done)
    }
}

@MainActor
final class BatchDeleteLogsTests: XCTestCase {
    func testDeletesAcrossDaysInOneUndoStepAndEmptyDaysDisappear() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let day1 = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!
        let day2 = day1.addingTimeInterval(86400)
        _ = try store.quickLog("甲", on: day1, now: day1.addingTimeInterval(1))
        _ = try store.quickLog("乙", on: day1, now: day1.addingTimeInterval(2))
        _ = try store.quickLog("丙", on: day2, now: day2.addingTimeInterval(1))
        let ids = Set(store.allLogs().map(\.log.id).prefix(3))
        XCTAssertEqual(store.deleteLogs(ids), 3)
        XCTAssertTrue(store.allLogs().isEmpty)
        XCTAssertFalse(store.entry(for: day2).hasContent, "空了的一天不留壳")
        store.undo()
        XCTAssertEqual(store.allLogs().count, 3, "一次 ⌘Z 整批恢复")
        XCTAssertEqual(store.deleteLogs([]), 0)
        XCTAssertEqual(store.deleteLogs([UUID()]), 0, "不存在的不算")
        XCTAssertEqual(store.allLogs().count, 3)
    }
}
