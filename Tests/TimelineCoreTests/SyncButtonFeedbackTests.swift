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

    func testLocalEditShowsAutomaticallyThenCompletionHidesButton() async throws {
        let feedback = SyncButtonFeedback(sync: sync, completionDuration: 0.05)
        sync.startAutomaticSync(delay: 0.15, interval: 3600)
        try await sync.sync()
        XCTAssertFalse(feedback.shouldShow)
        _ = try sync.store.quickLog("Local edit", on: Date())
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(sync.hasLocalChanges)
        XCTAssertTrue(feedback.shouldShow)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, feedback.phase != .completed { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(feedback.phase, .completed)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(feedback.shouldShow)
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
}
