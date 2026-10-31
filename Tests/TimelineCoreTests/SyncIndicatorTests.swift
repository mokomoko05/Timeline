import Combine
import XCTest
@testable import TimelineCore

@MainActor
final class SyncIndicatorTests: XCTestCase {
    private var root: URL!
    private var sync: FolderSync!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        sync = FolderSync(store: JournalStore(directory: root.appendingPathComponent("data")), folder: root.appendingPathComponent("cloud"), deviceName: "Test")
    }

    override func tearDown() {
        sync.stopAutomaticSync()
        sync = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func settle(_ seconds: TimeInterval = 0.03) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    private func waitForState(_ indicator: SyncIndicator, _ expected: SyncIndicatorState, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, indicator.state != expected { try await settle(0.01) }
        XCTAssertEqual(indicator.state, expected)
    }

    func testResolvePriorities() {
        func resolve(working: Bool = false, editing: Bool = false, confirming: Bool = false, errors: Bool = false, local: Bool = false, quiet: Bool = true) -> SyncIndicatorState {
            .resolve(working: working, editing: editing, confirming: confirming, hasFileErrors: errors, unconfirmedLocalChanges: local, quietElapsed: quiet)
        }
        XCTAssertEqual(resolve(), .hidden)
        XCTAssertEqual(resolve(local: true, quiet: false), .hidden, "刚改完：还在正常的上传时间内")
        XCTAssertEqual(resolve(local: true), .pending)
        XCTAssertEqual(resolve(errors: true, local: true), .attention)
        XCTAssertEqual(resolve(editing: true, errors: true, local: true), .hidden, "输入时什么都不显示")
        XCTAssertEqual(resolve(working: true, editing: true), .working, "用户自己点的同步除外")
        XCTAssertEqual(resolve(confirming: true, errors: true), .confirmed)
    }

    func testAutomaticSyncNeverPublishesAnyStateWhenChangesGoOutInTime() async throws {
        let indicator = SyncIndicator(sync: sync, quietPeriod: 5)
        var states: [SyncIndicatorState] = []
        let observation = indicator.$state.sink { states.append($0) }
        sync.startAutomaticSync(delay: 0.02, interval: 3600)
        try await sync.sync()
        _ = try sync.store.quickLog("Local edit", on: Date())
        try await settle(0.02)
        XCTAssertTrue(sync.hasLocalChanges)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, sync.hasLocalChanges { try await settle(0.01) }
        XCTAssertFalse(sync.hasLocalChanges)
        try await settle()
        XCTAssertEqual(states, [.hidden], "各个同步阶段都不发布，顶栏不会动")
        withExtendedLifetime(observation) { }
    }

    func testStalledUploadShowsQuietPendingOnlyAfterQuietPeriodAndNotWhileEditing() async throws {
        let indicator = SyncIndicator(sync: sync, quietPeriod: 0.15)
        sync.uploadPending = { _ in true }
        try await sync.sync()
        _ = try sync.store.quickLog("Local edit", on: Date())
        try await sync.sync()
        XCTAssertTrue(sync.hasLocalChanges)
        try await settle()
        XCTAssertEqual(indicator.state, .hidden)
        try await waitForState(indicator, .pending)
        indicator.setEditing(true)
        XCTAssertEqual(indicator.state, .hidden)
        indicator.setEditing(false)
        XCTAssertEqual(indicator.state, .pending)
        // 上传确认后悄悄消失，不闪完成提示。
        sync.uploadPending = { _ in false }
        var states: [SyncIndicatorState] = []
        let observation = indicator.$state.dropFirst().sink { states.append($0) }
        try await sync.sync()
        try await waitForState(indicator, .hidden)
        XCTAssertEqual(states, [.hidden])
        withExtendedLifetime(observation) { }
    }

    func testRemoteContentAndReceiptUploadsStayHidden() async throws {
        let indicator = SyncIndicator(sync: sync, quietPeriod: 0)
        let mac = FolderSync(store: JournalStore(directory: root.appendingPathComponent("peer")), folder: sync.folder, deviceName: "Peer")
        try await sync.sync()
        _ = try mac.store.quickLog("Remote change", on: Date())
        try await mac.sync()
        sync.uploadPending = { _ in true }
        try await sync.sync()
        try await settle()
        XCTAssertTrue(sync.waitingForUpload)
        XCTAssertFalse(sync.hasLocalChanges)
        XCTAssertEqual(indicator.state, .hidden, "回执等上传不是本机修改")
    }

    func testManualSyncConfirmsOnlyWhenReallyDone() async throws {
        let indicator = SyncIndicator(sync: sync, confirmDuration: 0.05)
        var during: SyncIndicatorState?
        let outcome = await indicator.run {
            during = indicator.state
            await self.sync.syncUntilExported()
        }
        XCTAssertEqual(during, .working)
        XCTAssertEqual(outcome, .confirmed)
        XCTAssertEqual(indicator.state, .confirmed)
        try await waitForState(indicator, .hidden)
    }

    func testManualSyncStillUploadingIsWaitingNotFailure() async throws {
        let indicator = SyncIndicator(sync: sync, quietPeriod: 0)
        sync.uploadPending = { _ in true }
        _ = try sync.store.quickLog("Local edit", on: Date())
        try await sync.sync()
        let outcome = await indicator.run { await self.sync.syncUntilExported(timeout: 0.1) }
        XCTAssertEqual(sync.lastErrorCode, "Timeline.SyncTimeout")
        XCTAssertEqual(outcome, .waiting)
        XCTAssertEqual(indicator.state, .pending)
    }

    func testAnEarlierFailureDoesNotOutliveALaterSuccessfulRoundThatIsOnlyWaiting() async throws {
        try await sync.sync()
        let parent = sync.folder.deletingLastPathComponent()
        let folder = sync.folder
        try FileManager.default.moveItem(at: folder, to: parent.appendingPathComponent("moved"))
        try Data().write(to: folder)
        do { try await sync.sync(); XCTFail("文件夹变成了文件，这一轮应该失败") } catch {}
        XCTAssertNotNil(sync.lastError)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: parent.appendingPathComponent("moved"), to: folder)
        sync.uploadPending = { _ in true }
        try await sync.sync()
        XCTAssertTrue(sync.waitingForUpload)
        XCTAssertNil(sync.lastError, "这一轮成功了，只是在等上传")
        XCTAssertEqual(sync.failureStreak, 0)
    }

    private func breakFolder() throws -> () throws -> Void {
        let parent = sync.folder.deletingLastPathComponent()
        let moved = parent.appendingPathComponent("moved-away")
        try FileManager.default.createDirectory(at: sync.folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: sync.folder, to: moved)
        try Data().write(to: sync.folder)
        return { [folder = sync.folder] in
            try FileManager.default.removeItem(at: folder)
            try FileManager.default.moveItem(at: moved, to: folder)
        }
    }

    func testRepeatedFailuresWhileTypingStayQuietUntilTheDelayPasses() async throws {
        try await sync.sync()
        sync.persistentErrorDelay = 0.2
        let restore = try breakFolder()
        for _ in 0..<3 { do { try await sync.sync() } catch {} }
        XCTAssertEqual(sync.failureStreak, 3)
        XCTAssertNotNil(sync.lastError)
        XCTAssertNil(sync.persistentError, "连败几轮但还没到时间：不提醒")
        try await settle(0.25)
        do { try await sync.sync() } catch {}
        XCTAssertNotNil(sync.persistentError, "到时间还没成功才提醒")
        try restore()
        try await sync.sync()
        XCTAssertNil(sync.persistentError)
    }

    func testASuccessBeforeTheDelayRestartsTheClock() async throws {
        try await sync.sync()
        sync.persistentErrorDelay = 0.2
        var restore = try breakFolder()
        do { try await sync.sync() } catch {}
        try await settle(0.25)
        try restore()
        try await sync.sync()
        restore = try breakFolder()
        do { try await sync.sync() } catch {}
        XCTAssertNil(sync.persistentError, "中间成功过，这是新的一串失败")
        try restore()
    }

    func testAutomaticSyncRetriesAtTheDeadlineAndReportsWithoutFurtherEdits() async throws {
        try await sync.sync()
        sync.persistentErrorDelay = 0.2
        let restore = try breakFolder()
        sync.startAutomaticSync(interval: 3600)
        let deadline = Date().addingTimeInterval(3)
        while sync.persistentError == nil, Date() < deadline { try await settle(0.02) }
        XCTAssertNotNil(sync.persistentError, "用户停下不打字也要按时提醒")
        sync.stopAutomaticSync()
        try restore()
    }
}
