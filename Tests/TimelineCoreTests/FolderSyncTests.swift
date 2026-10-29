import XCTest
@testable import TimelineCore

/// 两台「设备」各有自己的数据目录，通过同一个共享文件夹同步。
@MainActor
final class FolderSyncTests: XCTestCase {
    private var directories: [URL] = []
    private var folder: URL!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        folder = makeDirectory()
    }

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
        super.tearDown()
    }

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolderSyncTests-" + UUID().uuidString)
        directories.append(directory)
        return directory
    }

    private func makeDevice(_ name: String) -> FolderSync {
        let sync = FolderSync(store: JournalStore(directory: makeDirectory()), folder: folder, deviceName: name)
        sync.now = { [unowned self] in clock }
        return sync
    }

    /// 每次同步前把时钟拨快一秒，后做的修改时间戳一定更晚。
    private func sync(_ devices: FolderSync...) async throws {
        for device in devices {
            clock += 1
            try await device.sync()
        }
    }

    private func assertSameContent(_ first: FolderSync, _ second: FolderSync, file: StaticString = #filePath, line: UInt = #line) {
        let a = first.store.syncContent, b = second.store.syncContent
        // 同一天里的先后由排序键决定，数组顺序各台设备可以不同。
        XCTAssertEqual(a.days.mapValues { $0.todos.sorted { $0.id.uuidString < $1.id.uuidString } },
                       b.days.mapValues { $0.todos.sorted { $0.id.uuidString < $1.id.uuidString } }, file: file, line: line)
        XCTAssertEqual(a.days.mapValues { $0.logs.sorted { $0.id.uuidString < $1.id.uuidString } },
                       b.days.mapValues { $0.logs.sorted { $0.id.uuidString < $1.id.uuidString } }, file: file, line: line)
        XCTAssertEqual(a.days.mapValues(\.summary), b.days.mapValues(\.summary), file: file, line: line)
        XCTAssertEqual(a.boards, b.boards, file: file, line: line)
        XCTAssertEqual(a.tags, b.tags, file: file, line: line)
        XCTAssertEqual(a.pinnedTask, b.pinnedTask, file: file, line: line)
    }

    private func todo(_ title: String, in sync: FolderSync) -> ScheduledTask? {
        sync.store.tasks().first { $0.task.title == title }
    }

    func testBoardFavoritesAndOrderSyncBothWaysWithoutChangingMarkdown() async throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        let boards = try ["A", "B", "C"].map { try XCTUnwrap(mac.store.ensureBoard(for: .tag($0))) }
        mac.store.setBoardFavoriteOrder(boards.map(\.id))
        try await sync(mac, phone)
        XCTAssertEqual(phone.store.favoriteBoardIDs, boards.map(\.id))
        phone.store.moveBoardFavorite(boards[0].id, to: 2)
        mac.store.setBoardMarkdown("Mac changes while iPhone reorders", for: boards[0].id)
        try await sync(phone, mac, phone)
        XCTAssertEqual(mac.store.favoriteBoardIDs, [boards[1].id, boards[2].id, boards[0].id])
        XCTAssertEqual(phone.store.boards.first { $0.id == boards[0].id }?.markdown, "Mac changes while iPhone reorders")
        phone.store.setBoardFavoriteOrder([])
        try await sync(phone, mac)
        XCTAssertEqual(mac.store.boardFavoriteOrder, [])
        XCTAssertEqual(JournalStore(directory: mac.store.directory).boardFavoriteOrder, [])
    }

    func testEqualSizeRemoteBoardUpdateWithUnchangedModificationTimeIsRead() async throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        let board = try XCTUnwrap(phone.store.ensureBoard(for: .tag("Read")))
        phone.store.setBoardMarkdown("AAAA", for: board.id)
        try await sync(phone, mac)
        let url = FolderSync.snapshotURL(folder, phone.deviceID)
        let original = try Data(contentsOf: url)
        let modified = try XCTUnwrap(url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        // 只把正文替换成等长内容，再还原修改时间；新时间戳仍与原值有相同的编码长度。
        let text = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "AAAA", with: "BBBB")
        var snapshot = try JSONDecoder().decode(SyncSnapshot.self, from: Data(text.utf8))
        let key = "board/" + board.id.uuidString
        var field = try XCTUnwrap(snapshot.records[key]?.fields["markdown"])
        field.stamp.time += 1
        snapshot.records[key]?.fields["markdown"] = field
        let updated = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(original.count, updated.count)
        try updated.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        try await sync(mac)
        let received = try XCTUnwrap(mac.store.boards.first { $0.id == board.id }).markdown
        XCTAssertTrue(received.contains("BBBB"), received)
    }

    func testSyncWaitsForEditorSnapshotBeforeCapturingBoardContent() async throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        let board = try XCTUnwrap(mac.store.ensureBoard(for: .tag("Draft")))
        mac.prepareForSync = {
            try? await Task.sleep(for: .milliseconds(30))
            mac.store.setBoardMarkdown("Latest editor text", for: board.id)
        }
        try await sync(mac, phone)
        XCTAssertEqual(phone.store.boards.first { $0.id == board.id }?.markdown, "Latest editor text")
        mac.prepareForSync = nil
    }

    func testNewDeviceReceivesEverything() async throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        let day = clock
        _ = mac.store.addParsedTodo("写报告 #工作", on: day)
        _ = try mac.store.quickLog("开始写第一节", taskID: todo("写报告", in: mac)?.id, on: day, now: day)
        mac.store.setSummary("今天不错", on: day)
        let board = mac.store.ensureBoard(for: .tag("工作"))!
        mac.store.setBoardMarkdown("# 计划\n- [ ] 第一步", for: board.id)
        mac.store.save()

        try await sync(mac, phone)

        assertSameContent(mac, phone)
        XCTAssertEqual(todo("写报告", in: phone)?.task.number, 1)
        XCTAssertEqual(phone.devices.map(\.name), ["Mac"])
        XCTAssertEqual(phone.store.entry(for: day).summary, "今天不错")
    }

    func testOfflineEditsToDifferentFieldsBothSurvive() async throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        let day = clock
        mac.store.addTodo("买菜", on: day)
        try await sync(mac, phone)
        let id = todo("买菜", in: mac)!.id

        mac.store.renameTodo(id, title: "买菜和水果", on: day)
        phone.store.toggleTodo(id, on: day)
        try await sync(mac, phone, mac)

        assertSameContent(mac, phone)
        let merged = mac.store.locate(id)!.task
        XCTAssertEqual(merged.title, "买菜和水果")
        XCTAssertTrue(merged.isDone)
    }

    func testDeletionPropagatesAndUndoBringsItBack() async throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        let day = clock
        mac.store.addTodo("临时任务", on: day)
        try await sync(mac, phone)
        let id = todo("临时任务", in: mac)!.id

        phone.store.deleteTodo(id, on: day)
        try await sync(phone, mac)
        XCTAssertNil(mac.store.locate(id))

        // 删除那一侧撤销（重新出现）也会同步过去。
        phone.store.undoDelete()
        try await sync(phone, mac)
        XCTAssertNotNil(mac.store.locate(id))
        assertSameContent(mac, phone)
    }

    func testTasksCreatedOfflineOnBothDevicesGetDistinctNumbers() async throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        let day = clock
        mac.store.addTodo("Mac 上的任务", on: day)
        try await sync(mac)
        phone.store.addTodo("手机上的任务", on: day)
        try await sync(phone, mac, phone)

        assertSameContent(mac, phone)
        let numbers = mac.store.tasks().compactMap(\.task.number)
        XCTAssertEqual(Set(numbers).count, 2, "编号不能重复：\(numbers)")
        // 先拿到 #1 的保留它。
        XCTAssertEqual(todo("Mac 上的任务", in: phone)?.task.number, 1)
        // 新建任务继续往后编号，不会再撞上。
        phone.store.addTodo("第三个", on: day)
        XCTAssertEqual(todo("第三个", in: phone)?.task.number, 3)
    }

    func testConcurrentBoardEditsKeepBothVersions() async throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        let board = mac.store.ensureBoard(for: .tag("读书"))!
        mac.store.setBoardMarkdown("原文", for: board.id)
        mac.store.save()
        try await sync(mac, phone)

        // 修改的时间以同步时为准：手机先同步，Mac 的修改更晚，排在前面。
        phone.store.setBoardMarkdown("手机改的", for: board.id)
        phone.store.save()
        mac.store.setBoardMarkdown("Mac 改的", for: board.id)
        mac.store.save()
        try await sync(phone, mac, phone)

        assertSameContent(mac, phone)
        let text = mac.store.boards.first { $0.id == board.id }!.markdown
        XCTAssertTrue(text.hasPrefix("Mac 改的"), text)
        XCTAssertTrue(text.contains("同步冲突：以下是 iPhone"), text)
        XCTAssertTrue(text.hasSuffix("手机改的"), text)

        // 冲突合并之后在此基础上的修改正常覆盖，不再标冲突。
        phone.store.setBoardMarkdown("整理好了", for: board.id)
        phone.store.save()
        try await sync(phone, mac)
        XCTAssertEqual(mac.store.boards.first { $0.id == board.id }!.markdown, "整理好了")
    }

    func testConcurrentLogEditsKeepBothVersions() async throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        let day = clock
        let log = try XCTUnwrap(try mac.store.quickLogEntry("原文", on: day, now: day).entry)
        mac.store.save()
        try await sync(mac, phone)

        phone.store.updateLog(log.id, text: "手机改的", on: day)
        phone.store.save()
        mac.store.updateLog(log.id, text: "Mac 改的", on: day)
        mac.store.save()
        try await sync(phone, mac, phone)

        assertSameContent(mac, phone)
        let text = mac.store.entry(for: day).logs.first { $0.id == log.id }!.text
        XCTAssertTrue(text.hasPrefix("Mac 改的"), text)
        XCTAssertTrue(text.contains("同步冲突：以下是 iPhone"), text)
        XCTAssertTrue(text.hasSuffix("手机改的"), text)

        // 依次修改照常覆盖。
        phone.store.updateLog(log.id, text: "整理好了", on: day)
        phone.store.save()
        try await sync(phone, mac)
        XCTAssertEqual(mac.store.entry(for: day).logs.first { $0.id == log.id }!.text, "整理好了")
    }

    func testSequentialBoardEditsOverwriteWithoutConflict() async throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        let board = mac.store.ensureBoard(for: .tag("读书"))!
        mac.store.setBoardMarkdown("一", for: board.id)
        mac.store.save()
        try await sync(mac, phone)
        phone.store.setBoardMarkdown("二", for: board.id)
        phone.store.save()
        try await sync(phone)
        phone.store.setBoardMarkdown("三", for: board.id)
        phone.store.save()
        try await sync(phone, mac)
        XCTAssertEqual(mac.store.boards.first { $0.id == board.id }!.markdown, "三")
    }

    /// 进后台时正好有一轮同步在跑：`syncUntilExported` 要等它结束，再把之后的修改也导出去。
    func testSyncUntilExportedWaitsForTheRunningRound() async throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        let board = mac.store.ensureBoard(for: .tag("读书"))!
        mac.store.setBoardMarkdown("一", for: board.id)
        try await sync(mac, phone)
        clock += 1
        let running = Task { try await phone.sync() }
        while !phone.isSyncing { await Task.yield() }
        phone.store.setBoardMarkdown("二", for: board.id)
        // 直接再同步一次只会登记「稍后补一轮」，什么也没导出。
        _ = try await phone.sync()
        await phone.syncUntilExported()
        _ = try? await running.value
        try await sync(mac)
        XCTAssertEqual(mac.store.boards.first { $0.id == board.id }!.markdown, "二")
    }

    func testDraftsStayOnTheirDevice() async throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        let day = clock
        mac.store.setLogDraft("还没写完", on: day)
        mac.store.save()
        phone.store.setLogDraft("手机草稿", on: day)
        phone.store.addTodo("任务", on: day)
        phone.store.save()
        try await sync(mac, phone, mac)
        XCTAssertEqual(mac.store.entry(for: day).logDraft, "还没写完")
        XCTAssertEqual(phone.store.entry(for: day).logDraft, "手机草稿")
        XCTAssertNotNil(todo("任务", in: mac))
    }

    func testImagesFollowTheirLogs() async throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        let day = clock
        let name = try mac.store.storeImage(Data([1, 2, 3]), fileExtension: "png")
        _ = try mac.store.quickLog("截图", images: [name], on: day, now: day)
        try await sync(mac, phone)
        XCTAssertEqual(try Data(contentsOf: phone.store.imageURL(name)), Data([1, 2, 3]))
    }

    func testStateSurvivesRestart() async throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        let day = clock
        mac.store.addTodo("任务", on: day)
        try await sync(mac, phone)
        let id = todo("任务", in: mac)!.id

        // 手机重启：重新打开同一个数据目录，设备编号和同步状态都还在，不会把旧内容当成新修改盖掉 Mac 的改动。
        mac.store.renameTodo(id, title: "改过的任务", on: day)
        try await sync(mac)
        let reopened = FolderSync(store: JournalStore(directory: phone.store.directory), folder: folder, deviceName: "iPhone")
        reopened.now = { [unowned self] in clock }
        XCTAssertEqual(reopened.deviceID, phone.deviceID)
        try await sync(reopened)
        XCTAssertEqual(reopened.store.locate(id)?.task.title, "改过的任务")
    }

    func testRecordsRoundTripWithoutChanges() throws {
        let store = JournalStore(directory: makeDirectory())
        let day = clock
        store.addTodo("任务 #标签", on: day)
        _ = try store.quickLog("日志", on: day, now: day)
        _ = store.ensureBoard(for: .tag("标签"))
        store.setSummary("小结", on: day)
        let content = store.syncContent
        var state: [String: SyncRecord] = [:]
        SyncMerge(device: "a", now: day).stampLocalChanges(try content.records(), into: &state)
        XCTAssertEqual(content.applying(state), content)
    }
}
