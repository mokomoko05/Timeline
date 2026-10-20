import XCTest
@testable import TimelineCore

@MainActor
final class TagRenameTests: XCTestCase {
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!
    private var directory: URL!

    private func makeStore() throws -> JournalStore {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { [directory] in if let directory { try? FileManager.default.removeItem(at: directory) } }
        let store = JournalStore(directory: directory)
        let a = try XCTUnwrap(store.addParsedTodo("读摘要 #论文", on: day)).id
        _ = store.addParsedTodo("看公式 #论文/方法 #阅读", on: day)
        _ = try store.quickLog("一条笔记", taskID: a, tags: ["论文/方法"], on: day)
        store.createTag("论文/空的")
        store.addDraftTag("论文", on: day)
        return store
    }

    func testRenameMovesTheTagAndItsChildrenEverywhereInOneUndo() throws {
        let store = try makeStore()
        XCTAssertEqual(store.renameTag("论文", to: "#研究"), "研究")
        let names = Set(store.allTags().map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["研究", "研究/方法", "研究/空的", "阅读"]))
        XCTAssertFalse(names.contains { $0.hasPrefix("论文") }, "旧名字一处都不剩：待办、日志、快照、注册表、草稿")
        XCTAssertEqual(store.locate(number: 1)?.task.tags, ["研究"])
        XCTAssertEqual(store.locate(number: 2)?.task.tags, ["研究/方法", "阅读"])
        let log = try XCTUnwrap(store.allLogs().first).log
        XCTAssertEqual(log.tags, ["研究/方法"])
        XCTAssertEqual(log.taskTags, ["研究"], "日志里记的任务标签快照也跟着改")
        XCTAssertEqual(store.entry(for: day).logDraftTags, ["研究"])
        XCTAssertEqual(store.notes(forTag: "研究").count, 1)

        store.undo()
        let restored = Set(store.allTags().map(\.name))
        XCTAssertTrue(restored.isSuperset(of: ["论文", "论文/方法", "论文/空的"]), "一次 ⌘Z 全部恢复，包括空标签")
        XCTAssertFalse(restored.contains { $0.hasPrefix("研究") }, "注册表也撤回了")
        store.redo()
        XCTAssertTrue(Set(store.allTags().map(\.name)).contains("研究/空的"), "重做也包括注册表")
    }

    func testRenamingOntoAnExistingTagMergesWithoutDuplicates() throws {
        let store = try makeStore()
        XCTAssertEqual(store.renameTag("论文/方法", to: "阅读"), "阅读")
        XCTAssertEqual(store.locate(number: 2)?.task.tags, ["阅读"], "合并后不会出现两个 #阅读")
        XCTAssertEqual(store.allTags().first { $0.name == "阅读" }?.taskCount, 1)
        XCTAssertEqual(store.notes(forTag: "阅读").count, 1, "原来 #论文/方法 的笔记汇到 #阅读")
    }

    func testRenameRejectsBadNamesAndUnknownTags() throws {
        let store = try makeStore()
        XCTAssertNil(store.renameTag("论文", to: "有 空格"))
        XCTAssertNil(store.renameTag("论文", to: "3"))
        XCTAssertNil(store.renameTag("没有这个", to: "新"))
        XCTAssertEqual(store.renameTag("论文", to: "论文"), "论文", "同名就是什么都不做")
    }

    func testDeleteStripsTheTagButKeepsAllContentAndUndoes() throws {
        let store = try makeStore()
        let before = store.allLogs().count
        XCTAssertEqual(store.deleteTag("论文"), 3, "两个待办、一条日志")
        XCTAssertEqual(store.locate(number: 1)?.task.tags, [])
        XCTAssertEqual(store.locate(number: 2)?.task.tags, ["阅读"], "别的标签还在")
        XCTAssertEqual(store.allLogs().count, before, "日志一条都没删")
        XCTAssertEqual(store.allLogs().first?.log.text, "一条笔记")
        XCTAssertFalse(store.allTags().contains { $0.name.hasPrefix("论文") }, "注册表里的空子标签也去掉了")
        store.undo()
        XCTAssertEqual(store.locate(number: 1)?.task.tags, ["论文"])
        XCTAssertTrue(store.allTags().contains { $0.name == "论文/空的" })
        XCTAssertEqual(store.deleteTag("没有这个"), 0)
    }

    func testRenamedTagMapping() {
        XCTAssertEqual(JournalStore.renamedTag("论文/方法/细节", from: "论文", to: "研究"), "研究/方法/细节")
        XCTAssertEqual(JournalStore.renamedTag("论文集", from: "论文", to: "研究"), "论文集", "只认整段，不认前缀")
        XCTAssertEqual(JournalStore.renamedTag("Paper", from: "paper", to: "研究"), "研究", "不分大小写")
        XCTAssertTrue(JournalStore.isTag("论文/方法", under: "论文"))
        XCTAssertFalse(JournalStore.isTag("论文集", under: "论文"))
    }
}
