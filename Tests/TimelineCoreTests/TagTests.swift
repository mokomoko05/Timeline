import XCTest
@testable import TimelineCore

@MainActor
final class TagTests: XCTestCase {
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!

    private func makeStore() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory)
    }

    func testNormalizeRejectsNumbersAndWhitespace() {
        XCTAssertEqual(TagText.normalize("#项目A"), "项目A")
        XCTAssertEqual(TagText.normalize("  ##读书,"), "读书")
        XCTAssertNil(TagText.normalize("#3"), "纯数字是任务编号")
        XCTAssertNil(TagText.normalize("a b"))
        XCTAssertNil(TagText.normalize("#"))
        XCTAssertNil(TagText.normalize(String(repeating: "长", count: 41)))
        XCTAssertEqual(TagText.parseList("#a, B  b,#A 项目/子项"), ["a", "B", "项目/子项"], "不区分大小写去重")
    }

    func testExtractOnlyTakesTagsAtWordStart() {
        XCTAssertEqual(TagText.extract(from: "写报告 #项目A #紧急").tags, ["项目A", "紧急"])
        XCTAssertEqual(TagText.extract(from: "写报告 #项目A #紧急").title, "写报告")
        XCTAssertEqual(TagText.extract(from: "修复 C# 问题").tags, [], "C# 里的 # 不是标签")
        XCTAssertEqual(TagText.extract(from: "看 #3 的进展").tags, [], "#3 是任务编号")
        XCTAssertEqual(TagText.extract(from: "读 [文档](https://example.com/a#intro) #阅读").tags, ["阅读"], "链接里的 # 不算")
        XCTAssertTrue(TagText.extract(from: "读 [文档](https://example.com/a#intro) #阅读").title.contains("a#intro"))
        let only = TagText.extract(from: "#项目A")
        XCTAssertEqual(only.title, "#项目A", "整行只有标签时保留原文，不生成空标题")
        XCTAssertEqual(only.tags, [])
    }

    func testQuickAddTakesTagsBeforeDates() {
        let now = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!
        let parsed = QuickAdd.parse("#周五 明天 15:00 开会 #项目A", now: now)
        XCTAssertEqual(parsed.tags, ["周五", "项目A"], "#周五 是标签，不是日期")
        XCTAssertEqual(parsed.title, "开会")
        XCTAssertEqual(parsed.hour, 15)
        XCTAssertEqual(QuickAdd.parse("开会", now: now).tags, [])
        XCTAssertEqual(QuickAdd.parse("#项目A", now: now).tags, [], "只有标签时按原文当标题")
    }

    func testDraftTagPickerCanSelectBeforeTypingTitleAndRemoveAllTags() throws {
        let store = makeStore()
        var draft = TagText.replacingTags(in: "", with: ["论文", "Reading", "reading"])
        XCTAssertEqual(draft, "#论文 #Reading")
        XCTAssertEqual(TagText.inlineTags(in: draft), ["论文", "Reading"])
        draft = TagText.replacingTags(in: draft, with: ["Reading"])
        XCTAssertEqual(draft, "#Reading")
        XCTAssertEqual(TagText.replacingTags(in: draft, with: []), "")
        draft += " 明天 15:00 读摘要"
        let todo = try XCTUnwrap(store.addParsedTodo(draft, on: day, now: day))
        XCTAssertEqual(todo.task.title, "读摘要")
        XCTAssertEqual(todo.task.tags, ["Reading"])
        XCTAssertNotNil(todo.task.dueDate)
    }

    func testReplacingDraftTagsPreservesLinksDatesAndMultilineText() {
        let body = "明天 15:00 读 [文档](https://example.com/#intro)\n  修复 C# 和 #3 https://example.com/#anchor"
        var draft = body + " #old"
        for _ in 0..<10 { draft = TagText.replacingTags(in: draft, with: ["论文", "New"]) }
        XCTAssertEqual(draft, body + " #论文 #New")
        XCTAssertEqual(TagText.replacingTags(in: draft, with: []), body)
        XCTAssertEqual(TagText.inlineTags(in: draft), ["论文", "New"])
        XCTAssertEqual(TagText.replacingTags(in: "读 #old 摘要\n  第二行", with: ["new"]), "读 摘要\n  第二行 #new")
    }

    func testJournalCanExplicitlySkipAutomaticFocusLinkFromPicker() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addParsedTodo("Read #论文", on: day))
        store.setFocusTask(task.id)
        store.setLogDraft("Unrelated note", on: day)
        store.addDraftTag("灵感", on: day)
        try store.commitLog(on: day, linkDefault: false)
        let log = try XCTUnwrap(store.entry(for: day).logs.last)
        XCTAssertNil(log.taskID)
        XCTAssertNil(log.focusEvent)
        XCTAssertEqual(log.tags, ["灵感"])
        store.setLogDraft("Explicit choice", on: day)
        store.setLogTask(task.id, on: day)
        try store.commitLog(on: day, linkDefault: false)
        XCTAssertEqual(store.entry(for: day).logs.last?.taskID, task.id)
    }

    func testNewTodoCarriesTagsAndRenameMovesThemOutOfTheTitle() throws {
        let store = makeStore()
        let added = try XCTUnwrap(store.addParsedTodo("整理方法部分 #论文", on: day))
        XCTAssertEqual(added.task.title, "整理方法部分")
        XCTAssertEqual(added.task.tags, ["论文"])
        store.renameTodo(added.id, title: "整理方法部分 #论文 #EuroSys", on: added.date)
        let renamed = try XCTUnwrap(store.locate(added.id))
        XCTAssertEqual(renamed.task.title, "整理方法部分")
        XCTAssertEqual(renamed.task.tags, ["论文", "EuroSys"])
    }

    func testTagsSurviveSaveAndReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let added = try XCTUnwrap(store.addParsedTodo("读论文 #论文", on: day))
        store.save()
        let reopened = JournalStore(directory: directory)
        XCTAssertEqual(reopened.locate(added.id)?.task.tags, ["论文"])
    }

    func testOldDocumentsWithoutTagsStillLoad() throws {
        let json = #"{"id":"6B0E6D5B-6C47-4B58-9D5B-0A7C6E8F1A11","title":"旧任务","completed":false}"#
        let todo = try JSONDecoder().decode(Todo.self, from: Data(json.utf8))
        XCTAssertEqual(todo.tags, [])
    }

    func testSetTagsIsUndoableAndNormalized() throws {
        let store = makeStore()
        let added = try XCTUnwrap(store.addParsedTodo("读论文", on: day))
        store.setTags(added.id, ["#论文", "论文", "a b", "3", "阅读"])
        XCTAssertEqual(store.locate(added.id)?.task.tags, ["论文", "阅读"])
        store.undoManager.undo()
        XCTAssertEqual(store.locate(added.id)?.task.tags, [])
    }

    func testTaggedNotesGatherSmallTodosUnderOneTopic() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.addParsedTodo("读摘要 #论文", on: day))
        let b = try XCTUnwrap(store.addParsedTodo("看公式 #论文/方法", on: day))
        let c = try XCTUnwrap(store.addParsedTodo("买菜 #生活", on: day))
        _ = try store.quickLog("摘要读完了", taskID: a.id, on: day, now: day.addingTimeInterval(30))
        _ = try store.quickLog("公式推到一半", taskID: b.id, on: day, now: day.addingTimeInterval(60))
        _ = try store.quickLog("买了西红柿", taskID: c.id, on: day, now: day.addingTimeInterval(90))
        XCTAssertNotNil(store.addFocusLog("▶ 开始专注", taskID: a.id, now: day.addingTimeInterval(120)))

        XCTAssertEqual(store.notes(forTag: "论文").map(\.log.text), ["摘要读完了", "公式推到一半"], "子标签的笔记一起汇总，不含专注记录")
        XCTAssertEqual(store.notes(forTag: "论文/方法").map(\.log.text), ["公式推到一半"])
        XCTAssertEqual(store.notes(forTag: "论").count, 0, "不是前缀匹配")
        XCTAssertEqual(store.tasks(taggedWith: "LUNWEN").count, 0)
        XCTAssertEqual(store.tasks(taggedWith: "论文").count, 2)

        let summaries = store.allTags()
        XCTAssertEqual(Set(summaries.map(\.name)), ["论文", "论文/方法", "生活"])
        let paper = try XCTUnwrap(summaries.first { $0.name == "论文" })
        XCTAssertEqual(paper.taskCount, 2, "含子标签")
        XCTAssertEqual(paper.noteCount, 2)
        XCTAssertEqual(summaries.first { $0.name == "论文/方法" }?.taskCount, 1)
        _ = store.addParsedTodo("另一个 #读书/小说", on: day)
        XCTAssertTrue(store.allTags().contains { $0.name == "读书" }, "只用了子标签时，上级标签也会出现")
    }

    func testSearchMatchesTagsAndHashQueryIsExact() throws {
        let store = makeStore()
        _ = store.addParsedTodo("写报告 #项目A", on: day)
        _ = store.addParsedTodo("项目A 的周会", on: day)
        XCTAssertEqual(store.tasks(matching: "#项目A").map(\.task.title), ["写报告"], "#标签 只找带标签的")
        XCTAssertEqual(store.tasks(matching: "项目A").count, 2, "普通词标题和标签都匹配")
        XCTAssertEqual(store.tasks(matching: "#项目a").count, 1, "不区分大小写")
    }

    func testRepeatingTaskKeepsTagsOnNextOccurrence() throws {
        let store = makeStore()
        let added = try XCTUnwrap(store.addParsedTodo("每天 晨读 #阅读", on: day, now: day))
        store.toggleTodo(added.id, on: added.date, now: day)
        XCTAssertEqual(store.tasks(taggedWith: "阅读").count, 2)
    }
}

@MainActor
final class LogTagTests: XCTestCase {
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!

    private func makeStore() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory)
    }

    func testLogsWrittenWhileFocusingCarryTheTaskAndItsTags() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addParsedTodo("看公式 #论文 #方法", on: day))
        store.setFocusTask(task.id)
        _ = try store.quickLog("推到第三步", on: day)
        let log = try XCTUnwrap(store.allLogs().last?.log)
        XCTAssertEqual(log.taskID, task.id)
        XCTAssertEqual(log.taskNumber, task.task.number)
        XCTAssertEqual(log.taskTags, ["论文", "方法"], "日志里记着待办当时的标签")
        let focusLog = try XCTUnwrap(store.addFocusLog("▶ 开始专注", taskID: task.id, now: day.addingTimeInterval(60)))
        let stored = try XCTUnwrap(store.allLogs(includeFocus: true).first { $0.id == focusLog }?.log)
        XCTAssertEqual(stored.taskTags, ["论文", "方法"], "专注开始、结束记录也带标签")
        XCTAssertEqual(store.logs(forTag: "方法").count, 2)
        XCTAssertEqual(store.notes(forTag: "方法").count, 1, "笔记不含专注记录")
    }

    func testCommitLogAndRelinkRecordTags() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addParsedTodo("读论文 #论文", on: day))
        store.setLogDraft("#\(task.task.number ?? 0) 第一章读完", on: day)
        _ = try store.commitLog(on: day)
        XCTAssertEqual(store.allLogs().last?.log.taskTags, ["论文"])
        _ = try store.quickLog("无关联", on: day)
        let loose = try XCTUnwrap(store.allLogs().last?.log)
        XCTAssertTrue(loose.taskTags.isEmpty)
        store.setLogTask(task.id, forLog: loose.id, on: day)
        XCTAssertEqual(store.allLogs().last?.log.taskTags, ["论文"], "补关联时记下标签")
        store.setLogTask(nil, forLog: loose.id, on: day)
        XCTAssertTrue(store.allLogs().last?.log.taskTags.isEmpty == true)
    }

    func testRetaggingTheTaskMovesItsNotesButDeletedTaskKeepsTheSnapshot() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addParsedTodo("读论文 #论文", on: day))
        _ = try store.quickLog("笔记一", taskID: task.id, on: day)
        store.setTags(task.id, ["阅读"])
        XCTAssertEqual(store.notes(forTag: "阅读").count, 1, "改标签后，旧笔记跟着待办走")
        XCTAssertEqual(store.notes(forTag: "论文").count, 0)
        store.deleteTodo(task.id, on: task.date)
        XCTAssertEqual(store.notes(forTag: "论文").count, 1, "待办删除后，用日志里记下的标签（当时是「论文」）")
        XCTAssertEqual(store.allTags().first?.name, "论文")
        XCTAssertEqual(store.allTags().first?.taskCount, 0)
    }

    func testOldLogsWithoutTagsStillDecodeAndEncodeUnchanged() throws {
        let log = DailyLogEntry(createdAt: day, kind: .note, text: "旧日志")
        let data = try JSONEncoder().encode(log)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("taskTags"), "没有标签时不写新字段")
        XCTAssertEqual(try JSONDecoder().decode(DailyLogEntry.self, from: data).taskTags, [])
    }
}

@MainActor
final class BatchLogTests: XCTestCase {
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!

    private func makeStore() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory)
    }

    private func logIDs(_ store: JournalStore) -> [UUID] { store.allLogs().map(\.log.id) }

    func testBatchTagsAddRemoveAreOneUndoAndWorkWithoutATask() throws {
        let store = makeStore()
        _ = try store.quickLog("甲", on: day, now: day.addingTimeInterval(1))
        _ = try store.quickLog("乙", on: day, now: day.addingTimeInterval(2))
        _ = try store.quickLog("丙", on: day, now: day.addingTimeInterval(3))
        let ids = logIDs(store)
        XCTAssertEqual(store.updateLogTags(add: ["#灵感", "项目/A", "a b"], forLogs: Set(ids.prefix(2))), 2, "非法标签被忽略")
        XCTAssertEqual(store.allLogs().map(\.log.tags), [["灵感", "项目/A"], ["灵感", "项目/A"], []])
        XCTAssertEqual(store.notes(forTag: "灵感").map(\.log.text), ["甲", "乙"], "没有关联待办的日志也能按标签汇总")
        XCTAssertEqual(store.notes(forTag: "项目").count, 2, "含子标签")
        XCTAssertEqual(store.updateLogTags(add: ["灵感"], forLogs: Set(ids.prefix(2))), 0, "已有的不算改动")
        XCTAssertEqual(store.updateLogTags(remove: ["灵感"], forLogs: [ids[0]]), 1)
        XCTAssertEqual(store.allLogs().first?.log.tags, ["项目/A"])
        store.undoManager.undo()
        XCTAssertEqual(store.allLogs().first?.log.tags, ["灵感", "项目/A"], "撤销一次还原整批")
        store.undoManager.undo()
        XCTAssertTrue(store.allLogs().allSatisfy { $0.log.tags.isEmpty })
    }

    func testLogTagsAddToTheLinkedTaskTagsAndShowInSummaries() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addParsedTodo("读论文 #论文", on: day))
        _ = try store.quickLog("笔记", taskID: task.id, on: day)
        let id = try XCTUnwrap(store.allLogs().first?.log.id)
        store.updateLogTags(add: ["待整理"], forLogs: [id])
        XCTAssertEqual(store.tags(of: try XCTUnwrap(store.allLogs().first?.log)), ["论文", "待整理"])
        XCTAssertEqual(store.notes(forTag: "待整理").count, 1)
        XCTAssertEqual(store.allTags().first { $0.name == "待整理" }?.noteCount, 1)
        XCTAssertEqual(store.allTags().first { $0.name == "待整理" }?.taskCount, 0, "只在日志上，不算待办")
    }

    func testBatchLinkSetsTaskTitleNumberAndTagsAndUnlinks() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.addParsedTodo("读论文 #论文", on: day))
        let b = try XCTUnwrap(store.addParsedTodo("写周报", on: day))
        _ = try store.quickLog("甲", taskID: b.id, on: day, now: day.addingTimeInterval(1))
        _ = try store.quickLog("乙", on: day, now: day.addingTimeInterval(2))
        _ = try store.quickLog("丙", on: day, now: day.addingTimeInterval(3))
        let ids = logIDs(store)
        XCTAssertEqual(store.setLogTask(a.id, forLogs: Set(ids)), 3)
        for log in store.allLogs().map(\.log) {
            XCTAssertEqual(log.taskID, a.id)
            XCTAssertEqual(log.taskNumber, a.task.number)
            XCTAssertEqual(log.taskTags, ["论文"])
            XCTAssertEqual(log.taskTitle, "读论文")
        }
        XCTAssertEqual(store.notes(for: a.id).count, 3)
        XCTAssertEqual(store.setLogTask(a.id, forLogs: Set(ids)), 0, "已经关联的不重复改动")
        store.undoManager.undo()
        XCTAssertEqual(store.allLogs().map(\.log.taskID), [b.id, nil, nil], "撤销一次还原整批")
        XCTAssertEqual(store.setLogTask(nil, forLogs: Set(ids)), 1)
        XCTAssertTrue(store.allLogs().allSatisfy { $0.log.taskID == nil && $0.log.taskNumber == nil })
        XCTAssertEqual(store.setLogTask(UUID(), forLogs: Set(ids)), 0, "不存在的待办不改动")
    }

    func testOldLogsWithoutOwnTagsDecodeAndEncodeUnchanged() throws {
        let log = DailyLogEntry(createdAt: day, kind: .note, text: "旧")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(log), as: UTF8.self).contains("\"tags\""), "没有标签不写新字段")
        XCTAssertEqual(try JSONDecoder().decode(DailyLogEntry.self, from: try JSONEncoder().encode(log)).tags, [])
    }
}

@MainActor
final class NotebookTests: XCTestCase {
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!

    private func makeStore(_ directory: URL? = nil) -> JournalStore {
        let directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory)
    }

    func testEmptyTagExistsSurvivesReloadAndIsSearchable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = makeStore(directory)
        XCTAssertEqual(store.createTag("#读书笔记"), "读书笔记")
        XCTAssertEqual(store.createTag("读书笔记"), "读书笔记", "重复创建返回已有的")
        XCTAssertEqual(store.createTag("读书笔记 "), "读书笔记")
        XCTAssertNil(store.createTag("a b"))
        XCTAssertNil(store.createTag("42"))
        let empty = try XCTUnwrap(store.allTags().first { $0.name == "读书笔记" })
        XCTAssertEqual(empty.taskCount, 0)
        XCTAssertEqual(empty.noteCount, 0)

        let reopened = JournalStore(directory: directory)
        XCTAssertEqual(reopened.tagRegistry, ["读书笔记"], "空标签落盘，重启后还在")
        XCTAssertTrue(reopened.allTags().contains { $0.name == "读书笔记" })
        XCTAssertEqual(JournalStore(directory: directory, readOnlySnapshot: true).allTags().first?.name, "读书笔记", "命令行只读打开也看得到")
    }

    func testWritingUnderAnEmptyTagWithoutAnyTodoIsRetrievableByTag() throws {
        let store = makeStore()
        store.createTag("论文")
        _ = try store.quickLog("方法部分的想法", tags: ["论文"], on: day, now: day.addingTimeInterval(1))
        _ = try store.quickLog("无关", on: day, now: day.addingTimeInterval(2))
        XCTAssertEqual(store.notes(forTag: "论文").map(\.log.text), ["方法部分的想法"])
        XCTAssertNil(store.notes(forTag: "论文").first?.log.taskID, "不需要关联待办")
        XCTAssertEqual(store.allTags().first { $0.name == "论文" }?.noteCount, 1)
        XCTAssertFalse(store.removeEmptyTag("论文"), "有内容的标签不能当空标签删")
    }

    func testTagWriteCanAlsoLinkATaskAndKeepsFocusFallback() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addParsedTodo("读摘要 #论文", on: day))
        _ = try store.quickLog("第一章", taskID: task.id, tags: ["精读"], on: day, now: day.addingTimeInterval(1))
        let log = try XCTUnwrap(store.allLogs().first?.log)
        XCTAssertEqual(log.taskID, task.id)
        XCTAssertEqual(log.tags, ["精读"])
        XCTAssertEqual(store.tags(of: log), ["论文", "精读"])
        store.setFocusTask(task.id)
        _ = try store.quickLog("专注中直接记", tags: ["随笔"], on: day, now: day.addingTimeInterval(2))
        XCTAssertEqual(store.allLogs().last?.log.taskID, task.id, "专注期间的日志照常关联到专注任务")
    }

    func testRemoveEmptyTagOnlyWhenUnusedAndHandlesChildren() throws {
        let store = makeStore()
        store.createTag("临时")
        XCTAssertTrue(store.removeEmptyTag("临时"))
        XCTAssertTrue(store.tagRegistry.isEmpty)
        store.createTag("项目/子项")
        XCTAssertTrue(store.allTags().contains { $0.name == "项目" }, "上级随子标签出现")
        _ = store.addParsedTodo("事 #项目/子项", on: day)
        XCTAssertFalse(store.removeEmptyTag("项目"), "子标签在用时不能删上级")
        XCTAssertFalse(store.removeEmptyTag("不存在"))
    }

    func testRestoreMergesRegistryFromBackup() throws {
        let source = makeStore()
        source.createTag("备份里的空标签")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        try source.export(to: file)
        let target = makeStore()
        target.createTag("本地的")
        try target.restore(from: file)
        XCTAssertEqual(Set(target.tagRegistry), ["本地的", "备份里的空标签"])
    }

    func testCopyTextIgnoresImagesAndJoinsInTimeOrder() throws {
        let store = makeStore()
        let name = "x.png"
        _ = try store.quickLog("  第二条 [链接](https://example.com)  ", images: [name], on: day, now: day.addingTimeInterval(2))
        _ = try store.quickLog("", images: [name], on: day, now: day.addingTimeInterval(3))
        _ = try store.quickLog("第一条", on: day, now: day.addingTimeInterval(1))
        let logs = store.allLogs().map(\.log)
        XCTAssertEqual(logs.map(\.copyText), ["第一条", "第二条 [链接](https://example.com)", nil], "只复制文字、保留原文；只有图片的没有可复制内容")
        XCTAssertEqual(store.copyText(forLogs: Set(logs.map(\.id))), "第一条\n第二条 [链接](https://example.com)")
        XCTAssertNil(store.copyText(forLogs: [logs[2].id]))
        XCTAssertNil(store.copyText(forLogs: []))
    }

    func testLinkCandidatesRankFocusRecentThenListAndSearch() throws {
        let store = makeStore()
        for title in ["甲 #论文", "乙", "丙", "丁 读书", "戊"] { _ = store.addParsedTodo(title, on: day) }
        func id(_ n: Int) -> UUID { store.locate(number: n)!.id }
        _ = try store.quickLog("x", taskID: id(3), on: day, now: day.addingTimeInterval(1))
        _ = try store.quickLog("y", taskID: id(5), on: day, now: day.addingTimeInterval(2))
        store.setFocusTask(id(2))
        XCTAssertEqual(store.linkCandidates().compactMap(\.task.number), [2, 5, 3, 1, 4], "专注中 → 最近关联（新的在前）→ 其余按清单顺序")
        XCTAssertEqual(store.linkCandidates(query: "#4").first?.task.number, 4, "编号精确命中")
        XCTAssertEqual(store.linkCandidates(query: "4").first?.task.number, 4)
        XCTAssertEqual(store.linkCandidates(query: "读书").compactMap(\.task.number), [4])
        XCTAssertEqual(store.linkCandidates(query: "#论文").compactMap(\.task.number), [1], "#标签 按标签找")
        XCTAssertEqual(store.linkCandidates(query: "论文").compactMap(\.task.number), [1], "普通词也匹配标签名")
        store.toggleTodo(id(1), on: day)
        XCTAssertFalse(store.linkCandidates().contains { $0.task.number == 1 }, "已完成的默认不列出")
        XCTAssertTrue(store.linkCandidates(includeCompleted: true).contains { $0.task.number == 1 })
        XCTAssertTrue(store.linkCandidates(query: "没有这个词").isEmpty)
    }
}

@MainActor
final class ChapterTests: XCTestCase {
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!

    func testNotebookChaptersGroupDirectNotesThenTaggedTodosThenOthers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let a = try XCTUnwrap(store.addParsedTodo("读摘要 #论文", on: day))
        _ = try XCTUnwrap(store.addParsedTodo("看公式 #论文", on: day))
        let other = try XCTUnwrap(store.addParsedTodo("写周报", on: day))
        _ = try store.quickLog("直接写在笔记本里", tags: ["论文"], on: day, now: day.addingTimeInterval(1))
        _ = try store.quickLog("摘要笔记", taskID: a.id, on: day, now: day.addingTimeInterval(2))
        _ = try store.quickLog("别的待办上的，但日志自己带了标签", taskID: other.id, tags: ["论文"], on: day, now: day.addingTimeInterval(3))

        let chapters = store.chapters(forTag: "论文")
        XCTAssertEqual(chapters.map(\.title), ["直接记录", "读摘要", "看公式", "写周报"])
        XCTAssertEqual(chapters.map { $0.notes.count }, [1, 1, 0, 1], "没有笔记的章节也列出来")
        XCTAssertNil(chapters[0].taskID)
        XCTAssertEqual(chapters[1].number, 1)
        XCTAssertTrue(store.chapters(forTag: "不存在").isEmpty)
    }
}
