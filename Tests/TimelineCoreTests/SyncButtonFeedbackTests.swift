import Combine
import XCTest
@testable import TimelineCore

@MainActor
final class SyncButtonFeedbackTests: XCTestCase {
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

    func testManualSyncReportsRealStagesAndCompletionThenReturnsToIdle() async {
        let feedback = SyncButtonFeedback(sync: sync, completionDuration: 0.05)
        var stages: [SyncPhase] = []
        let observation = sync.$phase.sink { stages.append($0) }
        await feedback.run { await self.sync.syncUntilExported() }
        XCTAssertFalse(feedback.isWorking)
        XCTAssertEqual(feedback.phase, .completed)
        XCTAssertTrue(feedback.shouldShow)
        for stage: SyncPhase in [.preparing, .reading, .merging, .saving, .publishing, .completed] { XCTAssertTrue(stages.contains(stage)) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(feedback.phase, .idle)
        XCTAssertFalse(feedback.shouldShow)
        withExtendedLifetime(observation) { }
    }

    func testBackgroundChecksNeverShowBusyOrCompletionFeedback() async throws {
        let feedback = SyncButtonFeedback(sync: sync)
        var phases: [SyncPhase] = []
        let observation = feedback.$phase.sink { phases.append($0) }
        try await sync.sync()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(phases, [.idle])
        XCTAssertFalse(feedback.shouldShow)
        withExtendedLifetime(observation) { }
    }

    func testLocalEditAndAutomaticCompletionStayQuiet() async throws {
        let feedback = SyncButtonFeedback(sync: sync, completionDuration: 0.05)
        var visibleStates: [Bool] = []
        let observation = feedback.$shouldShow.sink { visibleStates.append($0) }
        sync.startAutomaticSync(delay: 0.15, interval: 3600)
        try await sync.sync()
        XCTAssertFalse(feedback.shouldShow)
        _ = try sync.store.quickLog("Local edit", on: Date())
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(sync.hasLocalChanges)
        XCTAssertFalse(feedback.shouldShow)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, sync.hasLocalChanges || sync.isSyncing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(sync.hasLocalChanges)
        XCTAssertEqual(feedback.phase, .idle)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(feedback.shouldShow)
        XCTAssertEqual(visibleStates, [false])
        withExtendedLifetime(observation) { }
    }

    func testBoardEditingDefersPendingFeedbackAndHidesItOnNextEdit() async throws {
        let board = try XCTUnwrap(sync.store.ensureBoard(for: .tag("Editing")))
        try await sync.sync()
        let feedback = SyncButtonFeedback(sync: sync, quietPeriod: 0.15)
        sync.uploadPending = { _ in true }
        for index in 0..<5 {
            sync.store.setBoardMarkdown("Revision \(index)", for: board.id)
            try await sync.sync()
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertFalse(feedback.shouldShow)
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(feedback.shouldShow)
        XCTAssertEqual(feedback.phase, .waitingForUpload)
        sync.store.setBoardMarkdown("Typing again", for: board.id)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(feedback.shouldShow)
        sync.uploadPending = { _ in false }
        try await sync.sync()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(feedback.shouldShow)
        XCTAssertEqual(feedback.phase, .idle)
    }

    func testAutomaticFileErrorsWaitUntilQuietAndRecoveryStaysQuiet() async throws {
        try await sync.sync()
        let peer = FolderSync(store: JournalStore(directory: root.appendingPathComponent("peer")), folder: sync.folder, deviceName: "Peer")
        _ = try peer.store.quickLog("Peer change", on: Date())
        try await peer.sync()
        let stream = sync.folder.appendingPathComponent("streams/" + peer.deviceID)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: stream, includingPropertiesForKeys: nil).first)
        let valid = try Data(contentsOf: file)
        try Data("broken".utf8).write(to: file)
        let feedback = SyncButtonFeedback(sync: sync, quietPeriod: 0.15)
        try await sync.sync()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(sync.fileErrors.isEmpty)
        XCTAssertFalse(feedback.shouldShow)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(feedback.shouldShow)
        XCTAssertEqual(feedback.phase, .failed)
        try valid.write(to: file)
        try await sync.sync()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(sync.fileErrors.isEmpty)
        XCTAssertFalse(feedback.shouldShow)
        XCTAssertEqual(feedback.phase, .idle)
    }

    func testImportedRemoteContentDoesNotLookLikeLocalEdit() async throws {
        let feedback = SyncButtonFeedback(sync: sync)
        let mac = FolderSync(store: JournalStore(directory: root.appendingPathComponent("peer")), folder: sync.folder, deviceName: "Peer")
        try await sync.sync()
        _ = try mac.store.quickLog("Remote change", on: Date())
        try await mac.sync()
        try await sync.sync()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(sync.hasLocalChanges)
        XCTAssertFalse(feedback.shouldShow)
    }

    func testWaitingForBackgroundReceiptDoesNotRevealButton() async throws {
        let feedback = SyncButtonFeedback(sync: sync)
        sync.uploadPending = { _ in true }
        try await sync.sync()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(sync.waitingForUpload)
        XCTAssertFalse(sync.hasLocalChanges)
        XCTAssertFalse(feedback.shouldShow)
    }

    func testWaitingRemainsVisibleAndLateCloudConfirmationShowsCompletion() async throws {
        sync.uploadPending = { _ in true }
        let feedback = SyncButtonFeedback(sync: sync)
        await feedback.run { await self.sync.syncUntilExported(timeout: 0.15) }
        XCTAssertEqual(feedback.phase, .waitingForUpload)
        XCTAssertFalse(feedback.isWorking)
        sync.uploadPending = { _ in false }
        try await sync.sync()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(feedback.phase, .completed)
    }

    func testFailureCannotBePresentedAsSuccess() async {
        sync.uploadPending = { _ in throw NSError(domain: "Test.Upload", code: 1) }
        let feedback = SyncButtonFeedback(sync: sync)
        await feedback.run { await self.sync.syncUntilExported(timeout: 0.15) }
        XCTAssertEqual(feedback.phase, .failed)
        XCTAssertFalse(feedback.isWorking)
    }
    func testAutomaticFailureStaysQuietUntilItPersistsButNeverShowsCompleted() async throws {
        try await sync.sync()
        sync.persistentErrorDelay = 0.1
        let feedback = SyncButtonFeedback(sync: sync, completionDuration: 0.05, quietPeriod: 0.1)
        sync.uploadPending = { _ in throw NSError(domain: "Test.Upload", code: 1) }
        _ = try sync.store.quickLog("Edit", on: Date())
        do { try await sync.sync() } catch {}
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNotNil(sync.lastError)
        XCTAssertNotEqual(feedback.phase, .failed, "偶发失败不报")
        XCTAssertNotEqual(feedback.phase, .completed)
        try await Task.sleep(nanoseconds: 120_000_000)
        do { try await sync.sync() } catch {}
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(feedback.phase, .failed, "持续失败才报")
        _ = try sync.store.quickLog("Continue editing", on: Date())
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(feedback.shouldShow)
        XCTAssertEqual(feedback.phase, .idle)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(feedback.shouldShow)
        XCTAssertEqual(feedback.phase, .failed)
    }

    func testBackgroundSaveFailureIsReportedImmediatelyDuringQuietPeriod() async throws {
        let feedback = SyncButtonFeedback(sync: sync)
        try sync.store.setDatabaseWriteFailure(true)
        _ = try sync.store.quickLog("Unsaved edit", on: Date())
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNotNil(sync.store.errorMessage)
        XCTAssertTrue(feedback.shouldShow)
        XCTAssertEqual(feedback.phase, .failed)
        try sync.store.setDatabaseWriteFailure(false)
    }

    func testLocalSaveFailureNeverShowsSyncCompletedAndRetryCanRecover() async throws {
        try await sync.sync()
        try sync.store.setDatabaseWriteFailure(true)
        _ = try sync.store.quickLog("Unsaved edit", on: Date())
        let feedback = SyncButtonFeedback(sync: sync, completionDuration: 0.05)
        await feedback.run { do { try await self.sync.store.saveAndWait() } catch { } }
        XCTAssertTrue(feedback.shouldShow)
        XCTAssertEqual(feedback.phase, .failed)
        try sync.store.setDatabaseWriteFailure(false)
        await feedback.run {
            do { try await self.sync.store.saveAndWait() } catch { return }
            await self.sync.syncUntilExported()
        }
        XCTAssertEqual(feedback.phase, .completed)
    }

}
