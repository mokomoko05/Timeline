import XCTest
@testable import TimelineCore

/// 热路径缓存：结果必须和未缓存的计算一致，并在数据变化后失效。
@MainActor
final class HotPathCacheTests: XCTestCase {
    private func makeStore() -> (JournalStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (JournalStore(directory: directory), directory)
    }

    func testPlainTextFastPathMatchesMarkdownRendering() {
        for source in ["读一篇论文", "Read the paper today", "整理 2026 年计划"] {
            XCTAssertEqual(String(TaskText.rendered(source).characters), source)
            XCTAssertTrue(TaskText.rendered(source).runs.allSatisfy { $0.link == nil })
        }
        // 有标记、网址、别名的文字仍走完整渲染，重复调用结果一致（来自缓存）。
        let markdown = "看 **重点** [资料](https://example.com)"
        XCTAssertEqual(TaskText.rendered(markdown), TaskText.rendered(markdown))
        XCTAssertEqual(String(TaskText.rendered(markdown).characters), "看 重点 资料")
        XCTAssertEqual(TaskText.rendered("https://example.com").runs.compactMap(\.link).map(\.absoluteString), ["https://example.com"])
        let aliased = TaskText.rendered("https://example.com/long/path", alias: "短名")
        XCTAssertEqual(String(aliased.characters), "短名")
        XCTAssertEqual(aliased.runs.compactMap(\.link).map(\.absoluteString), ["https://example.com/long/path"])
    }

    func testLocateByIDAndNumberStaysCorrectAcrossEdits() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let today = Date()
        store.addTodo("第一项", on: today)
        store.addTodo("第二项", on: today)
        let tasks = store.tasks()
        for item in tasks {
            XCTAssertEqual(store.locate(item.id)?.task.title, item.task.title)
            XCTAssertEqual(store.locate(number: item.task.number!)?.id, item.id)
        }
        let removed = tasks[0]
        store.deleteTodo(removed.id, on: removed.date)
        XCTAssertNil(store.locate(removed.id), "删除后索引必须失效")
        XCTAssertNil(store.locate(number: removed.task.number!))
        store.addTodo("第三项", on: today)
        let added = store.tasks().first { $0.task.title == "第三项" }!
        XCTAssertEqual(store.locate(added.id)?.task.title, "第三项")
    }

    func testCachedNoteCountMatchesNotesAndUpdatesAfterLogging() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let today = Date()
        store.addTodo("写论文", on: today)
        let task = try XCTUnwrap(store.tasks().first)
        XCTAssertEqual(store.noteCount(for: task.id), 0)
        try store.quickLog("第一条笔记", taskID: task.id, on: today)
        XCTAssertEqual(store.noteCount(for: task.id), 1)
        try store.quickLog("第二条笔记", taskID: task.id, on: today)
        XCTAssertEqual(store.noteCount(for: task.id), store.notes(for: task.id).count)
        XCTAssertEqual(store.noteCount(for: task.id), 2)
    }

    func testSuccessfulSaveDoesNotRepublishUnchangedStatus() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.save()
        var publications = 0
        let subscription = store.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        store.save()
        XCTAssertEqual(publications, 0, "没有变化的保存不应让观察仓库的窗口重绘")
    }

    func testCalendarCacheKeepsMondayFirstGregorianInCurrentZone() {
        let calendar = JournalDates.calendar
        XCTAssertEqual(calendar.identifier, .gregorian)
        XCTAssertEqual(calendar.firstWeekday, 2)
        XCTAssertEqual(calendar.timeZone, TimeZone.current)
        let key = JournalDates.key(Date())
        XCTAssertEqual(JournalDates.date(for: key).map(JournalDates.key), key)
    }

    func testBatchedImageTextWritesEveryReferenceWithOnePublish() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let today = Date()
        try store.quickLog("两张图", images: ["a.png", "b.png"], on: today)
        try store.quickLog("同一张图再次引用", images: ["a.png"], on: today)
        XCTAssertEqual(Set(store.imagesMissingText()), ["a.png", "b.png"])
        var publications = 0
        let subscription = store.objectWillChange.sink { publications += 1 }
        store.setImageTexts(["a.png": "Alpha", "b.png": "Beta"])
        subscription.cancel()
        XCTAssertTrue(store.imagesMissingText().isEmpty)
        let texts = store.allLogs().flatMap { $0.log.imageText.values }
        XCTAssertEqual(texts.sorted(), ["Alpha", "Alpha", "Beta"])
        XCTAssertLessThanOrEqual(publications, 2, "一批结果只触发一次 days 更新（加上保存标记）")
    }
}
