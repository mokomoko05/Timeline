import Foundation
import XCTest
@testable import TimelineCore

final class LegacyMigrationTests: XCTestCase {
    private func supportDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    @MainActor
    func testMigrationCopiesAllContentAndPreservesLegacyDataWithoutOverwritingNewChanges() throws {
        let support = try supportDirectory()
        let legacy = support.appendingPathComponent("Dayleaf")
        let store = JournalStore(directory: legacy)
        let task = try XCTUnwrap(store.addParsedTodo("Migration task #test", on: Date()))
        _ = try store.quickLogEntry("Migration note", taskID: task.id, on: Date())
        store.save()
        try FileManager.default.createDirectory(at: store.imagesDirectory, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: store.imageURL("test.png"))
        let original = try Data(contentsOf: store.fileURL)
        XCTAssertTrue(try JournalStore.migrateLegacyDirectory(applicationSupport: support))
        let migrated = JournalStore(directory: support.appendingPathComponent("Timeline"))
        XCTAssertEqual(migrated.tasks().map(\.id), store.tasks().map(\.id))
        XCTAssertEqual(migrated.allLogs().map(\.log.id), store.allLogs().map(\.log.id))
        XCTAssertEqual(try Data(contentsOf: migrated.imageURL("test.png")), Data([1, 2, 3]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: migrated.backupURL.path))
        _ = migrated.addParsedTodo("New app task", on: Date())
        migrated.save()
        let updated = try Data(contentsOf: migrated.fileURL)
        XCTAssertFalse(try JournalStore.migrateLegacyDirectory(applicationSupport: support))
        XCTAssertEqual(try Data(contentsOf: migrated.fileURL), updated)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }

    func testCorruptLegacyDataDoesNotPublishPartialMigration() throws {
        let support = try supportDirectory()
        let legacy = support.appendingPathComponent("Dayleaf")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: legacy.appendingPathComponent("journal.json"))
        XCTAssertThrowsError(try JournalStore.migrateLegacyDirectory(applicationSupport: support))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("Timeline").path))
        XCTAssertEqual(try String(contentsOf: legacy.appendingPathComponent("journal.json")), "broken")
    }

    func testExistingEmptyDestinationIsNeverSilentlyTreatedAsMigrated() throws {
        let support = try supportDirectory()
        let manager = FileManager.default
        for name in ["Dayleaf", "Timeline"] {
            try manager.createDirectory(at: support.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("{\"version\":6,\"days\":{}}".utf8).write(to: support.appendingPathComponent("Dayleaf/journal.json"))
        XCTAssertThrowsError(try JournalStore.migrateLegacyDirectory(applicationSupport: support))
    }

    func testFreshInstallAndNewAndLegacyEnvironmentOverrides() throws {
        XCTAssertFalse(try JournalStore.migrateLegacyDirectory(applicationSupport: supportDirectory()))
        XCTAssertEqual(JournalStore.defaultDirectory(environment: [:]).lastPathComponent, "Timeline")
        XCTAssertEqual(JournalStore.defaultDirectory(environment: ["DAYLEAF_DATA_DIR": "/tmp/legacy"]).path, "/tmp/legacy")
        XCTAssertEqual(JournalStore.defaultDirectory(environment: ["DAYLEAF_DATA_DIR": "/tmp/legacy", "TIMELINE_DATA_DIR": "/tmp/new"]).path, "/tmp/new")
        XCTAssertEqual(JournalStore.defaultDirectory(environment: ["DAYLEAF_DATA_DIR": "/tmp/legacy", "TIMELINE_DATA_DIR": ""]).path, "/tmp/legacy")
    }
}
