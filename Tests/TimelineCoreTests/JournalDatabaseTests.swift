import XCTest
@testable import TimelineCore

@MainActor
final class JournalDatabaseTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TimelineDatabase-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testMigrationPreservesSourceAndDatabaseIsTheOnlyAuthority() throws {
        let directory = try directory()
        let json = directory.appendingPathComponent("journal.json")
        var day = DayEntry(); day.logs = [DailyLogEntry(createdAt: Date(), kind: .note, text: "Original")]
        let original = try JSONEncoder().encode(JournalDocument(days: ["2026-10-30": day]))
        try original.write(to: json)
        let store = JournalStore(directory: directory)
        XCTAssertFalse(store.isReadOnly)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.databaseURL.path))
        XCTAssertEqual(try Data(contentsOf: json), original)
        XCTAssertEqual(try Data(contentsOf: store.backupsDirectory.appendingPathComponent("before-sqlite-journal.json")), original)
        store.updateLog(day.logs[0].id, text: "In SQLite", on: JournalDates.date(for: "2026-10-30")!)
        XCTAssertEqual(JournalStore(directory: directory).allLogs().first?.log.text, "In SQLite")
        XCTAssertEqual(try Data(contentsOf: json), original, "Legacy JSON is a frozen migration source, not a second writable authority")
    }

    func testBrokenDatabaseNeverFallsBackToStaleJSON() throws {
        let directory = try directory()
        try Data("broken SQLite".utf8).write(to: directory.appendingPathComponent("journal.sqlite"))
        try JSONEncoder().encode(JournalDocument()).write(to: directory.appendingPathComponent("journal.json"))
        let store = JournalStore(directory: directory)
        XCTAssertTrue(store.isReadOnly)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(try String(contentsOf: store.databaseURL), "broken SQLite")
    }

    func testEmptyBoardArraySurvivesMigrationValidation() throws {
        let directory = try directory()
        let document = JournalDocument(boards: [])
        let database = try JournalDatabase(url: directory.appendingPathComponent("journal.sqlite"))
        try database.save(document)
        XCTAssertEqual(try database.load(), document)
    }

    func testLostSyncMetadataCannotResurrectOldBaselineRecords() async throws {
        let directory = try directory(), cloud = try self.directory()
        let store = JournalStore(directory: directory)
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("OldBaseline")))
        store.setBoardMarkdown("Old", for: board.id)
        try await FolderSync(store: store, folder: cloud, deviceName: "Before").sync()
        let database = try JournalDatabase(url: store.databaseURL)
        try database.execute("DELETE FROM metadata WHERE key IN ('sync', 'transport')")
        let reopened = JournalStore(directory: directory)
        XCTAssertNil(try reopened.persistedSyncState())
        var content = reopened.syncContent
        content.boards = []
        reopened.applySyncContent(content, persistImmediately: false)
        let newCloud = try self.directory()
        try await FolderSync(store: reopened, folder: newCloud, deviceName: "After").sync()
        let reloaded = JournalStore(directory: directory, readOnlySnapshot: true)
        XCTAssertNil(try reloaded.persistedSyncState()?.records["board/" + board.id.uuidString])
        XCTAssertTrue(reloaded.boards.isEmpty)
    }

    func testTransactionRollsBackEntityBaselineCursorAndOutboxTogether() async throws {
        let directory = try directory(), store = JournalStore(directory: try self.directory())
        let sync = FolderSync(store: store, folder: directory, deviceName: "Test")
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Atomic")))
        store.setBoardMarkdown("Committed", for: board.id)
        try await sync.sync()
        let oldState = try store.persistedSyncState()
        let fault = try JournalDatabase(url: store.databaseURL)
        try fault.execute("CREATE TRIGGER baseline_failure BEFORE INSERT ON metadata WHEN NEW.key='sync' BEGIN SELECT RAISE(ABORT, 'fail after entities'); END")
        var content = store.syncContent
        content.boards[0].markdown = "Uncommitted"
        store.applySyncContent(content, persistImmediately: false)
        do { try await sync.sync(); XCTFail("Transaction must fail") } catch {}
        let disk = JournalStore(directory: store.directory, readOnlySnapshot: true)
        XCTAssertEqual(disk.board(id: board.id)?.markdown, "Committed")
        XCTAssertEqual(try disk.persistedSyncState(), oldState)
        try fault.execute("DROP TRIGGER baseline_failure")
        try await sync.sync()
        XCTAssertEqual(JournalStore(directory: store.directory).board(id: board.id)?.markdown, "Uncommitted")
    }

    func testSmallEditAmongTenThousandLogsWritesOnlyOneEntity() throws {
        let directory = try directory()
        let date = JournalDates.date(for: "2026-10-30")!
        var day = DayEntry()
        day.logs = (0..<10_000).map { DailyLogEntry(createdAt: date + Double($0), kind: .note, text: "Record \($0) " + String(repeating: "content ", count: 20)) }
        try JSONEncoder().encode(JournalDocument(days: [JournalDates.key(date): day])).write(to: directory.appendingPathComponent("journal.json"))
        let store = JournalStore(directory: directory)
        XCTAssertFalse(store.isReadOnly)
        let db = try JournalDatabase(url: store.databaseURL)
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let start = Date()
        store.updateLog(day.logs[5_000].id, text: "Small edit", on: date)
        let elapsed = Date().timeIntervalSince(start) * 1000
        let stats = store.persistenceStatistics
        let wal = URL(fileURLWithPath: store.databaseURL.path + "-wal")
        let walBytes = try wal.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        print("PERSISTENCE logs=10000 changedRows=\(stats.rows) payloadBytes=\(stats.bytes) walBytes=\(walBytes) foregroundMS=\(elapsed) configuration=debug")
        XCTAssertLessThanOrEqual(stats.rows, 2)
        XCTAssertLessThan(stats.bytes, 2_000)
        XCTAssertLessThan(walBytes, 128 * 1024)
        XCTAssertEqual(JournalStore(directory: directory, readOnlySnapshot: true).allLogs().first { $0.log.id == day.logs[5_000].id }?.log.text, "Small edit")
    }

    func testFailureDuringMigrationDoesNotPublishPartialDatabase() throws {
        let directory = try directory()
        let json = try JSONEncoder().encode(JournalDocument())
        try json.write(to: directory.appendingPathComponent("journal.json"))
        try Data("blocks backup directory".utf8).write(to: directory.appendingPathComponent("Backups"))
        let store = JournalStore(directory: directory)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.databaseURL.path))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), json)
    }
    func testOneLogSyncWithTenThousandLogsKeepsLocalAndCloudWritesSmall() async throws {
        let directory = try directory(), cloud = try self.directory()
        let date = JournalDates.date(for: "2026-10-30")!
        var day = DayEntry()
        day.logs = (0..<10_000).map { DailyLogEntry(createdAt: date + Double($0), kind: .note, text: "Large library record \($0)") }
        try JSONEncoder().encode(JournalDocument(days: [JournalDates.key(date): day])).write(to: directory.appendingPathComponent("journal.json"))
        let store = JournalStore(directory: directory)
        store.writesInBackground = true
        let sync = FolderSync(store: store, folder: cloud, deviceName: "Large")
        try await sync.sync()
        let db = try JournalDatabase(url: store.databaseURL)
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let start = Date()
        store.updateLog(day.logs[5_000].id, text: "One incremental edit", on: date)
        let mainMS = Date().timeIntervalSince(start) * 1000
        let syncStart = Date()
        try await sync.sync()
        let stats = store.persistenceStatistics
        let walBytes = try URL(fileURLWithPath: store.databaseURL.path + "-wal").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        print("PERSISTENCE_SYNC logs=10000 mainMS=\(mainMS) syncMS=\(Date().timeIntervalSince(syncStart) * 1000) rows=\(stats.rows) payloadBytes=\(stats.bytes) walBytes=\(walBytes) cloudBytes=\(sync.lastWrittenBytes) configuration=debug")
        XCTAssertLessThan(sync.lastWrittenBytes, 4_000)
        XCTAssertLessThan(stats.bytes, 64 * 1024)
        XCTAssertLessThan(walBytes, 256 * 1024)
        let disk = JournalStore(directory: directory, readOnlySnapshot: true)
        XCTAssertEqual(disk.allLogs().first { $0.log.id == day.logs[5_000].id }?.log.text, "One incremental edit")
        XCTAssertEqual(try disk.persistedSyncState()?.records["log/" + day.logs[5_000].id.uuidString]?.values["text"]?.string, "One incremental edit")
    }
}
