import XCTest
@testable import TimelineCore

@MainActor
final class RecentlyDeletedTests: XCTestCase {
    private var directories: [URL] = []
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
        super.tearDown()
    }

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RecentlyDeletedTests-" + UUID().uuidString)
        directories.append(directory)
        return directory
    }

    private func logID(_ text: String, in store: JournalStore) -> UUID? {
        store.allLogs().first { $0.log.text == text }?.log.id
    }

    func testDeletedLogCanBeRestoredAfterRestart() throws {
        let directory = makeDirectory()
        let store = JournalStore(directory: directory)
        let day = clock
        _ = try store.quickLog("第一条", on: day, now: day)
        _ = try store.quickLog("第二条", on: day, now: day.addingTimeInterval(60))
        let id = try XCTUnwrap(logID("第一条", in: store))
        store.deleteLog(id, on: day)
        XCTAssertEqual(store.recentlyDeleted.map(\.id), [id])
        XCTAssertEqual(store.recentlyDeleted.first?.title, "第一条")

        let reloaded = JournalStore(directory: directory)
        XCTAssertEqual(reloaded.recentlyDeleted.map(\.id), [id])
        XCTAssertTrue(reloaded.restoreDeleted(id))
        XCTAssertTrue(reloaded.recentlyDeleted.isEmpty)
        // 放回原来的时间位置。
        XCTAssertEqual(reloaded.entry(for: day).logs.map(\.text), ["第一条", "第二条"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: reloaded.trashURL.path))
    }

    func testUndoTakesItemBackOutOfRecentlyDeleted() throws {
        let store = JournalStore(directory: makeDirectory())
        let day = clock
        _ = try store.quickLog("会撤销的", on: day, now: day)
        let id = try XCTUnwrap(logID("会撤销的", in: store))
        _ = store.deleteLogs([id])
        XCTAssertEqual(store.recentlyDeleted.count, 1)
        store.undo()
        XCTAssertTrue(store.recentlyDeleted.isEmpty)
        XCTAssertNotNil(logID("会撤销的", in: store))
    }

    func testMovingATaskToAnotherDayIsNotADeletion() {
        let store = JournalStore(directory: makeDirectory())
        let day = clock
        store.addTodo("搬家", on: day)
        let id = store.tasks().first!.id
        store.placeTodo(id, on: day.addingTimeInterval(3 * 86400))
        XCTAssertTrue(store.recentlyDeleted.isEmpty)
        store.deleteTodo(id, on: day.addingTimeInterval(3 * 86400))
        XCTAssertEqual(store.recentlyDeleted.first?.title, "搬家")
        XCTAssertTrue(store.restoreDeleted(id))
        XCTAssertNotNil(store.locate(id))
        XCTAssertEqual(store.locate(id)?.task.number, 1)
    }

    func testRestoredTaskGetsNewNumberWhenItsNumberWasTaken() {
        let store = JournalStore(directory: makeDirectory())
        let day = clock
        store.addTodo("旧的", on: day)
        let id = store.tasks().first!.id
        store.deleteTodo(id, on: day)
        // 删除后，同一个编号被同步来的任务占了。
        var other = Todo(title: "占位")
        other.number = 1
        var content = store.syncContent
        content.days[JournalDates.key(day), default: DayEntry()].todos.append(other)
        store.applySyncContent(content)
        XCTAssertTrue(store.restoreDeleted(id))
        XCTAssertNotEqual(store.locate(id)?.task.number, 1)
    }

    func testOldItemsExpire() throws {
        let directory = makeDirectory()
        let store = JournalStore(directory: directory)
        let day = clock
        _ = try store.quickLog("很久以前", on: day, now: day)
        let id = try XCTUnwrap(logID("很久以前", in: store))
        store.deleteLog(id, on: day)
        XCTAssertEqual(store.recentlyDeleted.count, 1)
        let reloaded = JournalStore(directory: directory)
        reloaded.loadRecentlyDeleted(now: Date().addingTimeInterval(JournalStore.deletedRetention + 60))
        XCTAssertTrue(reloaded.recentlyDeleted.isEmpty)
    }

    func testPurgeAndEmpty() throws {
        let store = JournalStore(directory: makeDirectory())
        let day = clock
        _ = try store.quickLog("甲", on: day, now: day)
        _ = try store.quickLog("乙", on: day, now: day)
        let first = try XCTUnwrap(logID("甲", in: store))
        _ = store.deleteLogs([first, try XCTUnwrap(logID("乙", in: store))])
        store.purgeDeleted([first])
        XCTAssertEqual(store.recentlyDeleted.map(\.title), ["乙"])
        store.emptyRecentlyDeleted()
        XCTAssertTrue(store.recentlyDeleted.isEmpty)
    }

    func testImagesOfDeletedLogsAreKept() throws {
        let store = JournalStore(directory: makeDirectory())
        let day = clock
        let name = try store.storeImage(Data([1, 2, 3]), fileExtension: "png")
        _ = try store.quickLog("带图", images: [name], on: day, now: day)
        let id = try XCTUnwrap(logID("带图", in: store))
        store.deleteLog(id, on: day)
        XCTAssertTrue(store.imagesInRecentlyDeleted.contains(name))
        XCTAssertFalse(store.unusedImageNames().contains(name))
    }

    func testDeletionFromAnotherDeviceLandsInRecentlyDeletedAndRestoreSyncsBack() async throws {
        let folder = makeDirectory()
        let mac = FolderSync(store: JournalStore(directory: makeDirectory()), folder: folder, deviceName: "Mac")
        let phone = FolderSync(store: JournalStore(directory: makeDirectory()), folder: folder, deviceName: "iPhone")
        mac.now = { [unowned self] in clock }
        phone.now = { [unowned self] in clock }
        func sync(_ devices: FolderSync...) async throws {
            for device in devices { clock += 1; try await device.sync() }
        }
        let day = clock
        _ = try mac.store.quickLog("手机上误删", on: day, now: day)
        try await sync(mac, phone)
        let id = try XCTUnwrap(logID("手机上误删", in: phone.store))

        phone.store.deleteLog(id, on: day)
        try await sync(phone, mac)
        XCTAssertNil(logID("手机上误删", in: mac.store))
        XCTAssertEqual(mac.store.recentlyDeleted.map(\.id), [id])

        XCTAssertTrue(mac.store.restoreDeleted(id))
        try await sync(mac, phone)
        XCTAssertNotNil(logID("手机上误删", in: phone.store))
        XCTAssertTrue(phone.store.recentlyDeleted.isEmpty)
    }

    func testBoardHistoryKeepsVersionsAndRestores() {
        let directory = makeDirectory()
        let store = JournalStore(directory: directory)
        let board = store.ensureBoard(for: .tag("读书"))!
        store.setBoardMarkdown("第一版", for: board.id)
        // 同一段连续编辑只存编辑前的一版（空白页不存）。
        store.setBoardMarkdown("第一版，改了", for: board.id)
        store.setBoardMarkdown("第一版，又改了", for: board.id)
        XCTAssertEqual(store.boardVersions(for: board.id).map(\.markdown), ["第一版"])

        // 隔了 10 分钟以上再改：上一段编辑的结果存一版。
        store.boardHistory.record("第一版，又改了", for: board.id, now: Date().addingTimeInterval(BoardHistory.interval + 1))
        store.setBoardMarkdown("第二段编辑", for: board.id)
        XCTAssertEqual(store.boardVersions(for: board.id).map(\.markdown), ["第一版，又改了", "第一版"])

        store.setBoardMarkdown("全删了重写", for: board.id)
        let version = store.boardVersions(for: board.id).first!
        store.restoreBoardVersion(version, for: board.id)
        XCTAssertEqual(store.boards.first { $0.id == board.id }?.markdown, "第一版，又改了")
        // 被换掉的内容也留了一版，可以再换回来。
        XCTAssertTrue(store.boardVersions(for: board.id).contains { $0.markdown == "全删了重写" })
        store.undo()
        XCTAssertEqual(store.boards.first { $0.id == board.id }?.markdown, "全删了重写")

        store.waitForBoardHistory()
        let reloaded = JournalStore(directory: directory)
        XCTAssertFalse(reloaded.boardVersions(for: board.id).isEmpty)
    }

    func testSyncOverwriteAlwaysSavesTheLocalVersion() async throws {
        let folder = makeDirectory()
        let mac = FolderSync(store: JournalStore(directory: makeDirectory()), folder: folder, deviceName: "Mac")
        let phone = FolderSync(store: JournalStore(directory: makeDirectory()), folder: folder, deviceName: "iPhone")
        mac.now = { [unowned self] in clock }
        phone.now = { [unowned self] in clock }
        func sync(_ devices: FolderSync...) async throws {
            for device in devices { clock += 1; try await device.sync() }
        }
        let board = mac.store.ensureBoard(for: .tag("读书"))!
        mac.store.setBoardMarkdown("Mac 写的长文", for: board.id)
        try await sync(mac, phone)
        phone.store.setBoardMarkdown("手机覆盖", for: board.id)
        try await sync(phone, mac)
        XCTAssertEqual(mac.store.boards.first { $0.id == board.id }?.markdown, "手机覆盖")
        XCTAssertEqual(mac.store.boardVersions(for: board.id).first?.markdown, "Mac 写的长文")
    }
}
