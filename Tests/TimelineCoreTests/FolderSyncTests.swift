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

    func testDirectoryCoordinationCreatesNestedStreamAndRejectsFileAsParent() throws {
        let file = folder.appendingPathComponent("streams/testdevice/nested/change.json")
        try FolderSync.coordinatedWrite(Data("first".utf8), to: file)
        try FolderSync.coordinatedWrite(Data("second".utf8), to: file)
        XCTAssertEqual(try FolderSync.coordinatedRead(file), Data("second".utf8))
        XCTAssertEqual(try FolderSync.coordinatedDirectoryContents(file.deletingLastPathComponent()).map(\.lastPathComponent), ["change.json"])
        XCTAssertThrowsError(try FolderSync.coordinatedWrite(Data(), to: file.appendingPathComponent("child.json")))
    }

    func testFolderAccessBalancesPresenterRegistration() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let access = SyncFolderAccess(folder: folder, changed: {})
        access.start()
        access.start()
        XCTAssertEqual(NSFileCoordinator.filePresenters.filter { $0 === access }.count, 1)
        access.stop()
        access.stop()
        XCTAssertFalse(NSFileCoordinator.filePresenters.contains { $0 === access })
    }

    func testTransportCheckRequiresMatchingReplyAndKeepsJournalUntouched() async throws {
        let phone = makeDevice("Phone")
        let content = phone.store.syncContent
        let probe = "probe" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let root = folder.appendingPathComponent("transport-checks/" + probe)
        let check = Task { try await phone.verifyTransport(probe: probe, timeout: 5) }
        let request = root.appendingPathComponent("request.txt")
        while !FileManager.default.fileExists(atPath: request.path) { try await Task.sleep(nanoseconds: 10_000_000) }
        try FolderSync.coordinatedWrite(Data("wrong reply".utf8), to: root.appendingPathComponent("reply.txt"))
        try await Task.sleep(nanoseconds: 100_000_000)
        try FolderSync.coordinatedWrite(Data(probe.utf8), to: root.appendingPathComponent("reply.txt"))
        _ = try await check.value
        XCTAssertEqual(phone.store.syncContent, content)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        do {
            _ = try await phone.verifyTransport(probe: "../escape")
            XCTFail("Unsafe paths must be rejected")
        } catch { }
    }

    func testRemoteChangeIsObservedWithoutWaitingForPollingTimer() async throws {
        let phone = makeDevice("Phone"), mac = makeDevice("Mac")
        try await sync(phone, mac, phone)
        phone.startAutomaticSync(interval: 3600)
        defer { phone.stopAutomaticSync() }
        clock += 1
        _ = try mac.store.quickLog("Observed cloud change", on: clock)
        try await sync(mac)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !phone.store.allLogs().contains(where: { $0.log.text == "Observed cloud change" }) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(phone.store.allLogs().contains { $0.log.text == "Observed cloud change" })
        // 通知不能引发反复导出或新的云端批次。
        try await sync(phone)
        let files = try FolderSync.coordinatedDirectoryContents(folder.appendingPathComponent("streams/" + phone.deviceID))
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try await sync(phone)
        XCTAssertEqual(try FolderSync.coordinatedDirectoryContents(folder.appendingPathComponent("streams/" + phone.deviceID)), files)
        XCTAssertEqual(phone.lastWrittenBytes, 0)
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

    private func streamFiles(_ sync: FolderSync) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent(IncrementalSync.directory).appendingPathComponent(sync.deviceID), includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func legacy(_ device: FolderSync) throws -> SyncSnapshot {
        var records: [String: SyncRecord] = [:]
        SyncMerge(device: device.deviceID, now: clock).stampLocalChanges(try device.store.syncContent.records(), into: &records)
        return SyncSnapshot(device: device.deviceID, name: device.deviceName, exportedAt: clock, records: records)
    }

    func testLargeLibraryTransfersOnlyChangedBoardAndIdlePollTransfersNothing() async throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        let text = String(repeating: "Original board content. ", count: 700)
        var ids: [UUID] = []
        for index in 0..<80 {
            let board = try XCTUnwrap(mac.store.ensureBoard(for: .tag("Large\(index)")))
            ids.append(board.id)
            mac.store.setBoardMarkdown(text, for: board.id)
        }
        try await sync(mac, phone)
        let initialBytes = mac.lastWrittenBytes
        XCTAssertGreaterThan(initialBytes, 1_000_000)
        mac.store.setBoardMarkdown(text + "Changed.", for: ids[0])
        try await sync(mac, phone)
        XCTAssertLessThan(mac.lastWrittenBytes, initialBytes / 40)
        XCTAssertLessThan(phone.lastReadBytes, initialBytes / 40)
        XCTAssertEqual(phone.store.boards.first { $0.id == ids[0] }?.markdown, text + "Changed.")
        print("Sync transfer: initial=\(initialBytes) bytes, edit=\(mac.lastWrittenBytes) bytes, receiver=\(phone.lastReadBytes) bytes")
        // 先交换回执，随后空闲轮询不重读内容，不发布额外云端文件。
        try await sync(mac, phone, mac, phone)
        XCTAssertEqual(mac.lastReadBytes, 0)
        XCTAssertEqual(mac.lastWrittenBytes, 0)
        XCTAssertEqual(phone.lastReadBytes, 0)
        XCTAssertEqual(phone.lastWrittenBytes, 0)
    }

    func testInterruptedPublicationRetainsBatchAndImageQueueAcrossRestart() async throws {
        let mac = makeDevice("Mac")
        let name = try mac.store.storeImage(Data([8, 9, 10]), fileExtension: "png")
        let day = JournalDates.date(for: "2026-10-10")!
        _ = try mac.store.quickLog("Offline original", images: [name], on: day)
        mac.store.save()
        // 原图与批次写入后，在迁移标记发布时失败；自己的标记不参与读取。
        let obstruction = FolderSync.snapshotURL(folder, mac.deviceID)
        try FileManager.default.createDirectory(at: obstruction, withIntermediateDirectories: true)
        do { try await mac.sync(); XCTFail("Publication should fail") } catch { }
        let batch = try XCTUnwrap(streamFiles(mac).first)
        let original = try Data(contentsOf: batch)
        let reopened = FolderSync(store: JournalStore(directory: mac.store.directory), folder: folder, deviceName: "Mac")
        reopened.now = { [unowned self] in clock }
        reopened.uploadPending = { $0.lastPathComponent == name }
        try FileManager.default.removeItem(at: obstruction)
        try await sync(reopened)
        XCTAssertEqual(try streamFiles(reopened).count, 1)
        XCTAssertEqual(try Data(contentsOf: batch), original, "Retry must preserve sequence and bytes")
        XCTAssertTrue(reopened.waitingForUpload, "The interrupted image upload still needs confirmation")
        XCTAssertEqual(reopened.pendingUploadFiles, 1)
        let phone = makeDevice("iPhone")
        try await sync(phone)
        XCTAssertEqual(phone.store.allLogs().first?.log.images, [name])
        XCTAssertFalse(FileManager.default.fileExists(atPath: phone.store.imagesDirectory.appendingPathComponent(name).path))
        let downloaded = try await phone.downloadImage(name)
        XCTAssertTrue(downloaded)
        XCTAssertEqual(try Data(contentsOf: phone.store.imagesDirectory.appendingPathComponent(name)), Data([8, 9, 10]))
    }

    func testMissingDeltaWaitsWithoutSkippingAndRecoversWhenItArrives() async throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        let board = try XCTUnwrap(mac.store.ensureBoard(for: .tag("Gap")))
        mac.store.setBoardMarkdown("One", for: board.id)
        try await sync(mac, phone)
        mac.store.setBoardMarkdown("Two", for: board.id)
        try await sync(mac)
        let middle = try XCTUnwrap(streamFiles(mac).last)
        let saved = try Data(contentsOf: middle)
        mac.store.setBoardMarkdown("Three", for: board.id)
        try await sync(mac)
        try FileManager.default.removeItem(at: middle)
        try await sync(phone)
        XCTAssertTrue(phone.waitingForDownload)
        XCTAssertEqual(phone.store.boards.first { $0.id == board.id }?.markdown, "One")
        try saved.write(to: middle)
        try await sync(phone)
        XCTAssertFalse(phone.waitingForDownload)
        XCTAssertEqual(phone.store.boards.first { $0.id == board.id }?.markdown, "Three")
    }

    func testCorruptedBatchIsRejectedWithoutAdvancingReceiver() async throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        let board = try XCTUnwrap(mac.store.ensureBoard(for: .tag("Integrity")))
        mac.store.setBoardMarkdown("Safe", for: board.id)
        try await sync(mac, phone)
        mac.store.setBoardMarkdown("Latest", for: board.id)
        try await sync(mac)
        let file = try XCTUnwrap(streamFiles(mac).last)
        let valid = try Data(contentsOf: file)
        try Data("corrupted".utf8).write(to: file)
        do { try await phone.sync(); XCTFail("Corruption should fail verification") } catch { }
        XCTAssertEqual(phone.store.boards.first { $0.id == board.id }?.markdown, "Safe")
        try valid.write(to: file)
        try await sync(phone)
        XCTAssertEqual(phone.store.boards.first { $0.id == board.id }?.markdown, "Latest")
    }

    func testFailedLocalStateWriteDoesNotForgetUnpublishedChanges() async throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        let board = try XCTUnwrap(mac.store.ensureBoard(for: .tag("Durability")))
        mac.store.setBoardMarkdown("Must survive a failed save", for: board.id)
        try mac.store.setDatabaseWriteFailure(true)
        do { try await mac.sync(); XCTFail("Blocked state file must fail") } catch { }
        try mac.store.setDatabaseWriteFailure(false)
        try await sync(mac, phone)
        XCTAssertEqual(phone.store.boards.first { $0.id == board.id }?.markdown, "Must survive a failed save")
    }

    func testTamperedOriginalIsRejectedAndCanBeRetriedWithoutQualityLoss() async throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        let original = Data([1, 2, 3, 4])
        let name = try mac.store.storeImage(original, fileExtension: "png")
        _ = try mac.store.quickLog("Original", images: [name], on: clock)
        try await sync(mac, phone)
        let remote = folder.appendingPathComponent("images").appendingPathComponent(name)
        try Data([0]).write(to: remote)
        do { _ = try await phone.downloadImage(name); XCTFail("Tampered original must be rejected") } catch { }
        let local = phone.store.imagesDirectory.appendingPathComponent(name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
        try original.write(to: remote)
        let downloaded = try await phone.downloadImage(name)
        XCTAssertTrue(downloaded)
        XCTAssertEqual(try Data(contentsOf: local), original)
    }

    func testVisibleImageRequestDownloadsAndNotifiesWithoutAnotherContentMerge() async throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        let name = try mac.store.storeImage(Data([5, 6, 7]), fileExtension: "png")
        _ = try mac.store.quickLog("Visible image", images: [name], on: clock)
        try await sync(mac, phone)
        let local = phone.store.imagesDirectory.appendingPathComponent(name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
        let downloaded = expectation(description: "Visible image arrives")
        let observer = NotificationCenter.default.addObserver(forName: JournalStore.imageAvailable, object: nil, queue: .main) { note in
            if note.object as? URL == local { downloaded.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertEqual(phone.store.imageURL(name), local)
        await fulfillment(of: [downloaded], timeout: 3)
        XCTAssertEqual(try Data(contentsOf: local), Data([5, 6, 7]))
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
        let url = FolderSync.snapshotURL(folder, phone.deviceID)
        try FolderSync.coordinatedWrite(JSONEncoder().encode(legacy(phone)), to: url)
        try await sync(mac)
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

    func testPendingUploadDoesNotReportSuccessfulSyncAndRetriesWithoutRewriting() async throws {
        let phone = makeDevice("iPhone")
        let board = try XCTUnwrap(phone.store.ensureBoard(for: .tag("Pending")))
        phone.store.setBoardMarkdown("Waiting for cloud", for: board.id)
        phone.uploadPending = { _ in true }
        try await sync(phone)
        XCTAssertTrue(phone.waitingForUpload)
        XCTAssertNil(phone.lastSync)
        XCTAssertEqual(phone.lastCheck, clock)
        XCTAssertEqual(phone.lastExport, clock)
        XCTAssertNil(phone.lastUpload)
        XCTAssertNotNil(phone.uploadWaitingSince)
        let url = try XCTUnwrap(streamFiles(phone).last)
        let exported = try Data(contentsOf: url)
        clock += 10
        try await phone.sync()
        XCTAssertEqual(try Data(contentsOf: url), exported, "Polling upload must not restart the upload by rewriting the snapshot")
        phone.uploadPending = { _ in false }
        try await sync(phone)
        XCTAssertFalse(phone.waitingForUpload)
        XCTAssertEqual(phone.lastSync, clock)
        XCTAssertEqual(phone.lastUpload, clock)
        XCTAssertNil(phone.uploadWaitingSince)
        let uploaded = phone.lastUpload
        try await sync(phone)
        XCTAssertEqual(phone.lastUpload, uploaded, "Checking again must not imply another upload")
        let restored = FolderSync(store: JournalStore(directory: phone.store.directory), folder: folder, deviceName: "iPhone")
        XCTAssertEqual(restored.lastUpload, uploaded)
        XCTAssertEqual(restored.lastCheck, phone.lastCheck)
    }

    func testManualSyncTimeoutKeepsLatestExportAndReportsIncompleteUpload() async throws {
        let phone = makeDevice("iPhone")
        let board = try XCTUnwrap(phone.store.ensureBoard(for: .tag("Offline")))
        phone.store.setBoardMarkdown("Preserve latest", for: board.id)
        phone.uploadPending = { _ in true }
        await phone.syncUntilExported(timeout: 0.05)
        XCTAssertTrue(phone.waitingForUpload)
        XCTAssertNil(phone.lastSync)
        XCTAssertNotNil(phone.lastError)
        let snapshot = try JSONDecoder().decode(SyncBatch.self, from: Data(contentsOf: XCTUnwrap(streamFiles(phone).last)))
        XCTAssertEqual(snapshot.records["board/" + board.id.uuidString]?.fields["markdown"]?.value, .string("Preserve latest"))
        let progress = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: phone.stateURL.deletingLastPathComponent().appendingPathComponent("status.json")))
        XCTAssertEqual(progress["stage"], "timedOut")
    }

    func testManualDeadlineStillReturnsWhenTheRunningRoundIsBlocked() async throws {
        let phone = makeDevice("iPhone")
        var release: CheckedContinuation<Void, Never>?
        phone.prepareForSync = { await withCheckedContinuation { release = $0 } }
        let started = Date()
        await phone.syncUntilExported(timeout: 0.05)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3)
        XCTAssertTrue(phone.isSyncing)
        XCTAssertEqual(phone.lastErrorCode, "Timeline.SyncTimeout")
        release?.resume()
        while phone.isSyncing { try await Task.sleep(for: .milliseconds(5)) }
    }

    func testImmutableRevisionDeliversBoardWhenOverwrittenSnapshotRemainsStale() async throws {
        let phone = makeDevice("iPhone"), mac = makeDevice("Mac")
        let board = try XCTUnwrap(phone.store.ensureBoard(for: .tag("VibeAnApp")))
        phone.store.setBoardMarkdown("Old cloud copy", for: board.id)
        try await sync(phone, mac)
        let legacy = FolderSync.snapshotURL(folder, phone.deviceID)
        let first = try JSONDecoder().decode(SyncBatch.self, from: Data(contentsOf: XCTUnwrap(streamFiles(phone).first)))
        let stale = try JSONEncoder().encode(SyncSnapshot(device: phone.deviceID, name: "iPhone", exportedAt: clock, records: first.records))
        phone.store.setBoardMarkdown("Latest text still queued on the overwritten file", for: board.id)
        try await sync(phone)
        try stale.write(to: legacy, options: .atomic)
        try await sync(mac, mac)
        XCTAssertEqual(mac.store.boards.first { $0.id == board.id }?.markdown, "Latest text still queued on the overwritten file")
        XCTAssertEqual(mac.devices.map(\.name), ["iPhone"], "Multiple revisions represent one device")
        mac.store.setBoardMarkdown("Reverse direction", for: board.id)
        try await sync(mac, phone)
        XCTAssertEqual(phone.store.boards.first { $0.id == board.id }?.markdown, "Reverse direction")
    }

    func testBatchHistoryCompactsOnlyAfterCheckpointsUpload() async throws {
        let phone = makeDevice("iPhone")
        let offline = makeDevice("Offline Mac")
        let board = try XCTUnwrap(phone.store.ensureBoard(for: .tag("Retention")))
        let day = JournalDates.date(for: "2026-10-10")!
        let task = try XCTUnwrap(phone.store.addParsedTodo("Remove before compaction", on: day))
        try await sync(phone, offline)
        phone.store.deleteTodo(task.id, on: day)
        phone.uploadPending = { _ in true }
        for n in 0..<140 {
            phone.store.setBoardMarkdown("Revision \(n)", for: board.id)
            try await sync(phone)
        }
        XCTAssertEqual(try streamFiles(phone).count, 141, "Unconfirmed checkpoints must not discard history")
        phone.uploadPending = { _ in false }
        try await sync(phone)
        let files = try streamFiles(phone)
        XCTAssertLessThanOrEqual(files.count, IncrementalSync.checkpointInterval * 2 + 2)
        let before = try Dictionary(uniqueKeysWithValues: files.map { ($0, try Data(contentsOf: $0)) })
        try await sync(phone)
        for (url, data) in before { XCTAssertEqual(try Data(contentsOf: url), data) }
        let newDevice = makeDevice("New phone")
        try await sync(newDevice)
        XCTAssertEqual(newDevice.store.boards.first { $0.id == board.id }?.markdown, "Revision 139")
        XCTAssertNil(newDevice.store.locate(task.id), "A compacted checkpoint retains deletion tombstones")
        try await sync(offline)
        XCTAssertNil(offline.store.locate(task.id), "An offline device must not resurrect deleted tasks")
    }

    func testRestartWithUnchangedContentDoesNotRewriteCloudFiles() async throws {
        let phone = makeDevice("iPhone")
        let board = try XCTUnwrap(phone.store.ensureBoard(for: .tag("Restart")))
        phone.store.setBoardMarkdown("Already exported", for: board.id)
        phone.store.save()
        try await sync(phone)
        let legacy = FolderSync.snapshotURL(folder, phone.deviceID)
        let original = try Data(contentsOf: legacy)
        let revisionDirectory = folder.appendingPathComponent(IncrementalSync.directory).appendingPathComponent(phone.deviceID)
        let revisions = try FileManager.default.contentsOfDirectory(at: revisionDirectory, includingPropertiesForKeys: nil)
        let reopened = FolderSync(store: JournalStore(directory: phone.store.directory), folder: folder, deviceName: "iPhone")
        reopened.now = { [unowned self] in clock }
        try await sync(reopened)
        XCTAssertEqual(try Data(contentsOf: legacy), original, "Reopening must not restart the upload of unchanged content")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: revisionDirectory, includingPropertiesForKeys: nil), revisions)
    }

    func testDeviceExportTimeIsPreservedWhenReadingCachedFiles() async throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        _ = mac.store.ensureBoard(for: .tag("Receipt"))
        try await sync(mac)
        let exportTime = clock
        let urls = try streamFiles(mac) + [FolderSync.snapshotURL(folder, mac.deviceID)]
        for url in urls { try FileManager.default.setAttributes([.modificationDate: exportTime + 60], ofItemAtPath: url.path) }
        try await sync(phone, phone)
        XCTAssertEqual(phone.devices.count, 1)
        XCTAssertEqual(phone.devices.first?.exportedAt, exportTime, "The peer's export time must not become the cloud download modification time")
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: phone.store.imagesDirectory.appendingPathComponent(name).path), "Initial sync must not download the whole original image library")
        let downloaded = try await phone.downloadImage(name)
        XCTAssertTrue(downloaded)
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
