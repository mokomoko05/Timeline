import XCTest
@testable import TimelineCore

/// 后台保存：不阻塞主线程，按版本顺序落盘，旧快照不会覆盖新内容。
@MainActor
final class BackgroundSaveTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
        super.tearDown()
    }

    private func makeStore() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        let store = JournalStore(directory: directory)
        store.writesInBackground = true
        return store
    }

    private func reloaded(_ store: JournalStore) -> JournalStore {
        JournalStore(directory: store.directory, readOnlySnapshot: true)
    }

    func testRapidMutationsAllLandOnDiskInOrder() {
        let store = makeStore()
        let today = Date()
        for index in 1...40 { store.addTodo("Task \(index)", on: today) }
        store.waitForPendingWrites()
        let titles = Set(reloaded(store).tasks().map(\.task.title))
        XCTAssertEqual(titles, Set((1...40).map { "Task \($0)" }))
    }

    func testPendingFlagClearsOnlyAfterTheLatestWriteCompletes() async throws {
        let store = makeStore()
        store.addTodo("First", on: Date())
        XCTAssertTrue(store.hasPendingSave, "后台写入完成前仍标记为未保存")
        store.addTodo("Second", on: Date())
        store.waitForPendingWrites()
        // 完成回调在主队列上：让出一次主线程。
        for _ in 0..<20 where store.hasPendingSave { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.hasPendingSave)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(reloaded(store).tasks().count, 2)
    }

    func testSynchronousSaveIsABarrierAfterQueuedBackgroundWrites() {
        let store = makeStore()
        for index in 1...10 { store.addTodo("Queued \(index)", on: Date()) }
        store.save()
        XCTAssertFalse(store.hasPendingSave)
        XCTAssertEqual(reloaded(store).tasks().count, 10, "save() 返回时文件已包含全部修改")
    }

    func testCompletionOfAnOlderWriteDoesNotClearNewerPendingChanges() async throws {
        let store = makeStore()
        store.addTodo("Older", on: Date())
        // 旧写入已落盘，但它的完成回调还排在主队列里；此时又有新修改。
        store.waitForPendingWrites()
        store.addTodo("Newer", on: Date())
        await Task.yield()
        XCTAssertTrue(store.hasPendingSave, "旧写入的回调不能清掉新修改的未保存标记")
        store.waitForPendingWrites()
        for _ in 0..<20 where store.hasPendingSave { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.hasPendingSave)
        XCTAssertEqual(Set(reloaded(store).tasks().map(\.task.title)), ["Older", "Newer"])
    }

    func testFailedBackgroundWriteKeepsChangesAndReportsError() async throws {
        let store = makeStore()
        store.addTodo("Saved", on: Date())
        store.waitForPendingWrites()
        // 实体写入之后、事务提交之前让 SQLite 报错，验证整个事务回滚。
        try store.setDatabaseWriteFailure(true)
        store.addTodo("Unsaved", on: Date())
        store.waitForPendingWrites()
        for _ in 0..<20 where store.errorMessage == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.hasPendingSave, "失败后仍标记未保存，退出时会提示")
        XCTAssertEqual(store.tasks().count, 2, "修改保留在内存中")
    }

    func testFailedWriteRetriesByItselfOnceTheDiskRecovers() async throws {
        let store = makeStore()
        store.saveRetryDelays = [0.05]
        store.addTodo("Saved", on: Date())
        store.waitForPendingWrites()
        try store.setDatabaseWriteFailure(true)
        store.addTodo("Later", on: Date())
        store.waitForPendingWrites()
        for _ in 0..<20 where store.errorMessage == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(store.errorMessage)
        // 问题排除后不用再改什么，自动重试就写进去了。
        try store.setDatabaseWriteFailure(false)
        for _ in 0..<100 where store.errorMessage != nil {
            try await Task.sleep(for: .milliseconds(20))
            store.waitForPendingWrites()
        }
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.hasPendingSave)
        XCTAssertEqual(Set(reloaded(store).tasks().map(\.task.title)), ["Saved", "Later"])
    }
    func testAwaitedSaveDoesNotLoseEditsQueuedImmediatelyAfterIt() async throws {
        let store = makeStore()
        store.addTodo("Before barrier", on: Date())
        let barrier = Task { @MainActor in try await store.saveAndWait() }
        await Task.yield()
        store.addTodo("After barrier", on: Date())
        try await barrier.value
        try await store.saveAndWait()
        XCTAssertFalse(store.hasPendingSave)
        XCTAssertEqual(Set(reloaded(store).tasks().map(\.task.title)), ["Before barrier", "After barrier"])
    }

}
