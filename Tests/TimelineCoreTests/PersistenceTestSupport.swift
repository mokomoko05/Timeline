import Foundation
@testable import TimelineCore

extension JournalStore {
    @MainActor func exportedJSONForTesting() throws -> Data {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: target) }
        try export(to: target)
        return try Data(contentsOf: target)
    }

    @MainActor func setDatabaseWriteFailure(_ enabled: Bool) throws {
        let db = try JournalDatabase(url: databaseURL)
        if enabled { try db.execute("CREATE TRIGGER test_write_failure BEFORE INSERT ON metadata BEGIN SELECT RAISE(ABORT, 'injected disk write failure'); END") }
        else { try db.execute("DROP TRIGGER IF EXISTS test_write_failure") }
    }
}
