import XCTest
@testable import TimelineCore

@MainActor
final class SyncRecoveryTests: XCTestCase {
    private var directories: [URL] = []
    private var timestamp = Date(timeIntervalSince1970: 1_800_000_000)
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TimelineAudit-" + UUID().uuidString)
        directories.append(url)
        return url
    }
    override func tearDown() {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }
    private func device(_ name: String, folder: URL, store: JournalStore? = nil) -> FolderSync {
        let result = FolderSync(store: store ?? JournalStore(directory: directory()), folder: folder, deviceName: name)
        result.now = { [unowned self] in timestamp }
        return result
    }
    private func sync(_ devices: FolderSync...) async throws {
        for device in devices { timestamp += 1; try await device.sync() }
    }

    func testChangingToEmptySyncFolderMustPublishExistingLibrary() async throws {
        let folder = directory(), replacement = directory()
        let mac = device("Mac", folder: folder)
        let board = try XCTUnwrap(mac.store.ensureBoard(for: .tag("Keep")))
        mac.store.setBoardMarkdown("Existing library", for: board.id)
        mac.store.save()
        try await sync(mac)
        let switched = device("Mac", folder: replacement, store: mac.store)
        let phone = device("Phone", folder: replacement)
        try await sync(switched, phone)
        print("AUDIT folder-change complete=\(switched.lastSync != nil) boardsReceived=\(phone.store.boards.count)")
        XCTAssertEqual(phone.store.boards.first { $0.id == board.id }?.markdown, "Existing library")
    }

    func testReimportingPreviouslyUploadedPurgedOriginalMustUploadAgain() async throws {
        let folder = directory()
        let mac = device("Mac", folder: folder), phone = device("Phone", folder: folder)
        let bytes = Data([1, 2, 3, 4])
        let name = try mac.store.storeImage(bytes, fileExtension: "png")
        let log = try mac.store.quickLogEntry("First use", images: [name], on: timestamp, now: timestamp)
        try await sync(mac, phone)
        if let id = log.entry?.id { mac.store.deleteLog(id, on: timestamp) }
        try await sync(mac, phone)
        // 模拟无引用图片经过保留期后已从云端清理。
        let remote = folder.appendingPathComponent("images").appendingPathComponent(name)
        try FileManager.default.removeItem(at: remote)
        let reimported = try mac.store.storeImage(bytes, fileExtension: "png")
        XCTAssertEqual(reimported, name)
        _ = try mac.store.quickLog("Use original again", images: [reimported], on: timestamp)
        try await sync(mac, phone)
        let downloaded = try await phone.downloadImage(name)
        print("AUDIT reimport complete=\(mac.lastSync != nil) remoteExists=\(FileManager.default.fileExists(atPath: remote.path)) download=\(downloaded)")
        XCTAssertTrue(downloaded)
    }

    func testFailedJournalSaveMustNotAcknowledgeAndOverwriteRemoteAfterRestart() async throws {
        let folder = directory()
        let mac = device("Mac", folder: folder), phone = device("Phone", folder: folder)
        let board = try XCTUnwrap(mac.store.ensureBoard(for: .tag("Save")))
        mac.store.setBoardMarkdown("Old content", for: board.id)
        try await sync(mac, phone)
        let journal = phone.store.directory.appendingPathComponent("journal.json")
        let oldData = try Data(contentsOf: journal)
        phone.store.saveRetryDelays = [3600]
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        mac.store.setBoardMarkdown("Latest remote content", for: board.id)
        try await sync(mac)
        do { try await sync(phone); XCTFail("Failed persistence must fail sync") } catch {}
        try await sync(mac)
        print("AUDIT journal-save error=\(phone.store.errorMessage != nil) syncComplete=\(phone.lastSync != nil) acknowledged=\(mac.devices.first?.hasReceivedLocalChanges == true)")
        XCTAssertNotNil(phone.store.errorMessage)
        XCTAssertNotNil(phone.lastError)
        XCTAssertFalse(mac.devices.first?.hasReceivedLocalChanges == true)
        // 模拟进程退出，磁盘恢复可写但只留下旧正文；同步状态已推进。
        try FileManager.default.removeItem(at: journal)
        try oldData.write(to: journal)
        let reopened = device("Phone", folder: folder, store: JournalStore(directory: phone.store.directory))
        try await sync(reopened, mac)
        print("AUDIT journal-save finalMac=\(mac.store.boards.first { $0.id == board.id }?.markdown ?? "missing")")
        XCTAssertEqual(mac.store.boards.first { $0.id == board.id }?.markdown, "Latest remote content")
    }

    func testMissingStateFileMustNotReuseOldTransportSequenceForNewIdentity() async throws {
        let folder = directory()
        let mac = device("Mac", folder: folder), phone = device("Phone", folder: folder)
        let board = try XCTUnwrap(mac.store.ensureBoard(for: .tag("Recovery")))
        mac.store.setBoardMarkdown("Original", for: board.id)
        mac.store.save()
        try await sync(mac)
        try FileManager.default.removeItem(at: mac.stateURL)
        let reopened = device("Mac", folder: folder, store: JournalStore(directory: mac.store.directory))
        reopened.store.setBoardMarkdown("Recovered latest", for: board.id)
        try await sync(reopened, phone)
        print("AUDIT lost-state idChanged=\(reopened.deviceID != mac.deviceID) receiverWaiting=\(phone.waitingForDownload)")
        XCTAssertTrue(phone.store.boards.first { $0.id == board.id }?.markdown.contains("Recovered latest") == true)
    }

    func testSameTagBoardsCreatedIndependentlyMustShowSameContentAfterSync() async throws {
        let folder = directory()
        let mac = device("Mac", folder: folder), phone = device("Phone", folder: folder)
        let first = try XCTUnwrap(mac.store.ensureBoard(for: .tag("VibeAnApp")))
        let second = try XCTUnwrap(phone.store.ensureBoard(for: .tag("VibeAnApp")))
        mac.store.setBoardMarkdown("Mac version", for: first.id)
        phone.store.setBoardMarkdown("Phone version", for: second.id)
        try await sync(mac, phone, mac, phone)
        let macText = mac.store.board(for: .tag("VibeAnApp"))?.markdown
        let phoneText = phone.store.board(for: .tag("VibeAnApp"))?.markdown
        print("AUDIT duplicate-board count=\(mac.store.boards.count) mac=\(macText ?? "missing") phone=\(phoneText ?? "missing")")
        XCTAssertEqual(macText, phoneText)
    }


    func testUncommittedStateUsesPreviousBaselineAfterRestart() async throws {
        let mac = device("Mac", folder: directory())
        let board = try XCTUnwrap(mac.store.ensureBoard(for: .tag("Crash")))
        mac.store.setBoardMarkdown("Durable", for: board.id)
        try await sync(mac)
        let committed = try Data(contentsOf: mac.stateURL)
        var staged = try JSONDecoder().decode(SyncState.self, from: committed)
        staged.commitID = "not-in-journal"
        try committed.write(to: mac.stateURL.deletingLastPathComponent().appendingPathComponent("state.previous.json"))
        try JSONEncoder().encode(staged).write(to: mac.stateURL)
        let reopened = device("Mac", folder: mac.folder, store: JournalStore(directory: mac.store.directory))
        XCTAssertEqual(reopened.deviceID, mac.deviceID)
        try await sync(reopened)
        XCTAssertEqual(reopened.store.board(id: board.id)?.markdown, "Durable")
    }

    func testRemovedOwnStreamRepublishesFullCheckpointWithoutLocalEdit() async throws {
        let mac = device("Mac", folder: directory())
        let board = try XCTUnwrap(mac.store.ensureBoard(for: .tag("Repair")))
        mac.store.setBoardMarkdown("Recover all", for: board.id)
        try await sync(mac)
        try FileManager.default.removeItem(at: mac.folder.appendingPathComponent("streams"))
        let phone = device("Phone", folder: mac.folder)
        try await sync(mac, phone)
        XCTAssertEqual(phone.store.board(id: board.id)?.markdown, "Recover all")
        XCTAssertFalse(phone.waitingForDownload)
    }

    func testDuplicateBoardAliasesPreserveFavoritesHistoryAndFutureEdits() async throws {
        let folder = directory(), mac = device("Mac", folder: folder), phone = device("Phone", folder: folder)
        let first = try XCTUnwrap(mac.store.ensureBoard(for: .tag("Same")))
        let second = try XCTUnwrap(phone.store.ensureBoard(for: .tag("same")))
        mac.store.setBoardMarkdown("Mac draft", for: first.id)
        phone.store.setBoardMarkdown("Phone draft", for: second.id)
        mac.store.setBoardFavoriteOrder([first.id, second.id])
        try await sync(mac, phone, mac, phone)
        let canonical = try XCTUnwrap(mac.store.board(for: .tag("SAME")))
        XCTAssertTrue(canonical.markdown.contains("Mac draft"))
        XCTAssertTrue(canonical.markdown.contains("Phone draft"))
        XCTAssertEqual(mac.store.favoriteBoardIDs, [canonical.id])
        XCTAssertEqual(mac.store.board(id: second.id)?.id, canonical.id)
        XCTAssertFalse(mac.store.boardVersions(for: canonical.id).isEmpty)
        // 用户整理过合并正文后，旧别名原文不能每轮复活。
        mac.store.setBoardMarkdown("Edited canonical", for: second.id)
        try await sync(mac, phone, mac, phone)
        XCTAssertEqual(mac.store.board(id: first.id)?.markdown, "Edited canonical")
        XCTAssertEqual(phone.store.board(id: second.id)?.markdown, "Edited canonical")
    }
}
