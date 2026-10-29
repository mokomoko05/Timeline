import XCTest
@testable import TimelineCore

final class SyncImageMaintenanceTests: XCTestCase {
    private let day: TimeInterval = 86400

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testImageInventoryDoesNotUploadWholeLibraryWithEachNewPhoto() throws {
        let folder = try directory(), now = Date()
        var state = IncrementalState()
        let initial = Set((0..<10_000).map { "image-\($0).jpg" })
        XCTAssertGreaterThan(try SyncImageMaintenance.publish(protected: initial, folder: folder, device: "mac", now: now, state: &state), 100_000)
        let originalLease = state.imageLease
        let expanded = initial.union(["new-photo.jpg"])
        XCTAssertEqual(try SyncImageMaintenance.publish(protected: expanded, folder: folder, device: "mac", now: now + 60, state: &state), 0)
        XCTAssertEqual(state.imageLease, originalLease)
        XCTAssertGreaterThan(try SyncImageMaintenance.publish(protected: expanded, folder: folder, device: "mac", now: now + day, state: &state), 100_000)
        XCTAssertNotEqual(state.imageLease, originalLease)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(SyncImageMaintenance.leases).path)
        XCTAssertEqual(files.count, 2)
    }

    func testCleanupWaitsForUploadAndCanRestoreQuarantinedOriginal() throws {
        let folder = try directory(), now = Date()
        let image = folder.appendingPathComponent("images/orphan.png")
        try FolderSync.coordinatedWrite(Data([1, 2, 3]), to: image)
        var state = IncrementalState()
        state.imageInventoryComplete = true
        state.protectedImages = []
        try SyncImageMaintenance.publish(protected: [], folder: folder, device: "mac", state: &state)
        state.pendingCloud = []
        try SyncImageMaintenance.collect(folder: folder, device: "mac", now: now, state: &state, uploadPending: { _ in false })
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
        let trash = folder.appendingPathComponent("image-trash/orphan.png")
        try SyncImageMaintenance.collect(folder: folder, device: "mac", now: now + 31 * day, state: &state,
                                         uploadPending: { $0 == trash })
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path), "Do not remove original until quarantine upload is confirmed")
        XCTAssertEqual(try Data(contentsOf: trash), Data([1, 2, 3]))
        XCTAssertTrue(state.pendingCloud.contains("image-trash/orphan.png"))
        state.pendingCloud = [] // 下一轮同步已确认隔离副本上传。
        try SyncImageMaintenance.collect(folder: folder, device: "mac", now: now + 32 * day, state: &state, uploadPending: { _ in false })
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
        state.protectedImages = ["orphan.png"]
        try SyncImageMaintenance.collect(folder: folder, device: "mac", now: now + 33 * day, state: &state, uploadPending: { _ in false })
        XCTAssertEqual(try Data(contentsOf: image), Data([1, 2, 3]), "A restored reference recovers the original bytes")
        XCTAssertNil(state.imageCandidates?["orphan.png"])
    }

    func testCleanupDefersForLegacyOrOfflinePeerAndIncompleteBackupInventory() throws {
        let folder = try directory(), now = Date()
        let image = folder.appendingPathComponent("images/orphan.png")
        try FolderSync.coordinatedWrite(Data([1]), to: image)
        var state = IncrementalState()
        state.protectedImages = []
        try SyncImageMaintenance.publish(protected: [], folder: folder, device: "mac", state: &state)
        state.pendingCloud = []
        try SyncImageMaintenance.collect(folder: folder, device: "mac", now: now, state: &state, uploadPending: { _ in false })
        XCTAssertNil(state.lastMaintenance, "Unreadable backups must block collection")
        state.imageInventoryComplete = true
        try FolderSync.coordinatedWrite(Data([0]), to: folder.appendingPathComponent("devices/phone.json"))
        try SyncImageMaintenance.collect(folder: folder, device: "mac", now: now + 400 * day, state: &state, uploadPending: { _ in false })
        XCTAssertNil(state.lastMaintenance, "A peer without a receipt and protected-image inventory blocks collection")
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
    }

    func testUnreferencedTrashSurvivesNinetyDaysAndPendingUploads() throws {
        let folder = try directory(), now = Date()
        let trash = folder.appendingPathComponent("image-trash/orphan.png")
        try FolderSync.coordinatedWrite(Data([1]), to: trash)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: trash.path)
        var state = IncrementalState()
        state.imageInventoryComplete = true
        state.protectedImages = []
        try SyncImageMaintenance.publish(protected: [], folder: folder, device: "mac", state: &state)
        state.pendingCloud = []
        try SyncImageMaintenance.collect(folder: folder, device: "mac", now: now + 89 * day, state: &state, uploadPending: { _ in false })
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path))
        try SyncImageMaintenance.collect(folder: folder, device: "mac", now: now + 91 * day, state: &state, uploadPending: { _ in true })
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path))
        try SyncImageMaintenance.collect(folder: folder, device: "mac", now: now + 93 * day, state: &state, uploadPending: { _ in false })
        XCTAssertFalse(FileManager.default.fileExists(atPath: trash.path))
    }

    func testDeletingRestoredImageStartsNewQuarantineRetention() throws {
        let folder = try directory(), now = Date()
        let image = folder.appendingPathComponent("images/again.png")
        let trash = folder.appendingPathComponent("image-trash/again.png")
        try FolderSync.coordinatedWrite(Data([7]), to: image)
        try FolderSync.coordinatedWrite(Data([7]), to: trash)
        try FileManager.default.setAttributes([.modificationDate: now - 40 * day], ofItemAtPath: image.path)
        try FileManager.default.setAttributes([.modificationDate: now - 200 * day], ofItemAtPath: trash.path)
        var state = IncrementalState()
        state.imageInventoryComplete = true
        state.protectedImages = []
        state.imageCandidates = ["again.png": now - 31 * day]
        try SyncImageMaintenance.publish(protected: [], folder: folder, device: "mac", state: &state)
        state.pendingCloud = []
        try SyncImageMaintenance.collect(folder: folder, device: "mac", now: now, state: &state, uploadPending: { _ in false })
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
        XCTAssertEqual(try Data(contentsOf: trash), Data([7]), "The previous quarantine age must not immediately delete a restored original")
    }
}
