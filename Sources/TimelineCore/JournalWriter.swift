import Foundation

/// 单写队列：实体增量与同步基线在同一 SQLite 事务内提交。
final class JournalWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Timeline.JournalWriter", qos: .userInitiated)
    private let fileURL: URL
    private let backupsDirectory: URL
    private var database: JournalDatabase?
    private var writtenVersion = 0
    private var dailyBackupKey: String?
    private var startupBackup: JournalDocument?
    private let stateLock = NSLock()
    private var persistedState: SyncState?
    var databaseURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("journal.sqlite") }

    init(fileURL: URL, backupsDirectory: URL) {
        self.fileURL = fileURL; self.backupsDirectory = backupsDirectory
    }

    static func encode<Document: Encodable>(_ document: Document) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    func load(readOnly: Bool) throws -> JournalDocument? {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
            let db = try JournalDatabase(url: databaseURL, readOnly: readOnly)
            try db.execute("BEGIN DEFERRED")
            let document: JournalDocument
            let state: SyncState?
            do {
                guard let loaded = try db.load() else { throw CocoaError(.fileReadCorruptFile) }
                document = loaded
                state = try db.loadSyncState()
                try db.execute("COMMIT")
            } catch { try? db.execute("ROLLBACK"); throw error }
            database = db
            remember(state)
            if !readOnly {
                startupBackup = document
                queue.async { [self] in
                    do {
                        try Self.encode(document).write(to: fileURL.deletingLastPathComponent().appendingPathComponent("journal.backup.json"), options: .atomic)
                        startupBackup = nil
                    } catch { /* 保留待备份快照，下一次保存时重试并报告错误。 */ }
                }
            }
            return document
        }
    }

    func loadSyncState() throws -> SyncState? {
        // load() 已在同一读事务中解码；初始化同步器不能再排队等待启动备份并重读整库。
        stateLock.withLock { persistedState }
    }

    private func remember(_ state: SyncState?) { stateLock.withLock { persistedState = state } }

    /// 仅显式恢复操作可替换损坏库。原主库及 WAL/SHM 全部留档。
    func prepareForRestore(archive: URL) throws {
        try queue.sync {
            database = nil
            remember(nil)
            writtenVersion = 0
            startupBackup = nil
            guard FileManager.default.fileExists(atPath: databaseURL.path) else { return }
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: databaseURL.path + suffix)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.copyItem(at: source, to: archive.appendingPathComponent(source.lastPathComponent))
                }
            }
            // 所有文件复制成功后才撤下旧库；失败时原文件不动。
            for suffix in ["-wal", "-shm", ""] {
                let source = URL(fileURLWithPath: databaseURL.path + suffix)
                if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.removeItem(at: source) }
            }
        }
    }

    func writeNow(_ document: JournalDocument, version: Int, state: SyncState? = nil, changedDays: Set<String>? = nil) -> Error? {
        queue.sync { write(document, version: version, state: state, changedDays: changedDays) }
    }

    func write(_ document: JournalDocument, version: Int, state: SyncState? = nil, changedDays: Set<String>? = nil,
               timing: (@Sendable (TimeInterval, TimeInterval, TimeInterval) -> Void)? = nil,
               completion: @escaping @Sendable (Error?) -> Void) {
        let queued = timing == nil ? 0 : ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            let started = timing == nil ? 0 : ProcessInfo.processInfo.systemUptime
            let error = write(document, version: version, state: state, changedDays: changedDays)
            let finished = timing == nil ? 0 : ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                timing?((started - queued) * 1000, (finished - started) * 1000, (ProcessInfo.processInfo.systemUptime - finished) * 1000)
                completion(error)
            }
        }
    }

    func writeAwaited(_ document: JournalDocument, version: Int, state: SyncState? = nil, changedDays: Set<String>?,
                      timing: (@Sendable (TimeInterval, TimeInterval, TimeInterval) -> Void)?,
                      completion: @escaping @Sendable (Error?) -> Void) {
        let queued = timing == nil ? 0 : ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            let started = timing == nil ? 0 : ProcessInfo.processInfo.systemUptime
            let error = write(document, version: version, state: state, changedDays: changedDays)
            let finished = timing == nil ? 0 : ProcessInfo.processInfo.systemUptime
            if let timing {
                DispatchQueue.main.async { timing((started - queued) * 1000, (finished - started) * 1000, (ProcessInfo.processInfo.systemUptime - finished) * 1000) }
            }
            completion(error)
        }
    }

    /// 同步入队，保证主线程上分配的版本顺序不会被 async 执行器重排。
    func commit(_ document: JournalDocument, version: Int, state: SyncState, changedDays: Set<String>? = nil,
                completion: @escaping @Sendable (Error?) -> Void) {
        queue.async { [self] in completion(write(document, version: version, state: state, changedDays: changedDays)) }
    }

    func saveTransport(_ state: SyncState, completion: @escaping @Sendable (Error?) -> Void) {
        queue.async { [self] in
            do {
                guard let database else { throw CocoaError(.fileNoSuchFile) }
                try database.saveTransport(state)
                stateLock.withLock { persistedState?.ledger = state.ledger }
                completion(nil)
            } catch { completion(error) }
        }
    }

    func loadDays(from start: String, through end: String, completion: @escaping @Sendable (Result<[String: DayEntry], Error>) -> Void) {
        queue.async { [self] in
            completion(Result { guard let database else { throw CocoaError(.fileNoSuchFile) }; return try database.loadDays(from: start, through: end) })
        }
    }

    func waitUntilIdle() { queue.sync {} }
    func statistics() -> (rows: Int, bytes: Int) { queue.sync { (database?.lastChangedRows ?? 0, database?.lastPayloadBytes ?? 0) } }

    private func write(_ document: JournalDocument, version: Int, state: SyncState? = nil, changedDays: Set<String>? = nil) -> Error? {
        guard version > writtenVersion else { return nil }
        do {
            if database == nil { try migrate(document, state: state) }
            else {
                guard FileManager.default.fileExists(atPath: databaseURL.path) else { throw CocoaError(.fileNoSuchFile) }
                if let startupBackup {
                    try Self.encode(startupBackup).write(to: fileURL.deletingLastPathComponent().appendingPathComponent("journal.backup.json"), options: .atomic)
                    self.startupBackup = nil
                }
                try makeDailyBackup(database?.document ?? document)
                try database?.save(document, state: state, changedDays: changedDays)
                if let state { remember(state) }
            }
            writtenVersion = version
            return nil
        } catch { return error }
    }

    private func legacyState(commitID: String?) -> SyncState? {
        let root = fileURL.deletingLastPathComponent().appendingPathComponent("Sync")
        for name in ["state.json", "state.previous.json"] {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(name)),
                  var state = try? JSONDecoder().decode(SyncState.self, from: data), state.commitID == commitID else { continue }
            if let data = try? Data(contentsOf: root.appendingPathComponent("transport.json")),
               let transport = try? JSONDecoder().decode(IncrementalState.self, from: data),
               transport.deviceID == state.device, transport.folderPath == state.folderPath, transport.commitID == state.commitID,
               transport.revision >= (state.ledger?.revision ?? -1) { state.ledger = transport }
            return state
        }
        return nil
    }

    private func migrate(_ document: JournalDocument, state: SyncState?) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: databaseURL.path) else { throw CocoaError(.fileWriteFileExists) }
        try manager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        // 先备份源文件；出错不切换权威存储，重启可重新开始迁移。
        for relative in ["journal.json", "Sync/state.json", "Sync/state.previous.json", "Sync/transport.json"] {
            let source = fileURL.deletingLastPathComponent().appendingPathComponent(relative)
            let backup = backupsDirectory.appendingPathComponent("before-sqlite-" + relative.replacingOccurrences(of: "/", with: "-"))
            if manager.fileExists(atPath: source.path), !manager.fileExists(atPath: backup.path) { try manager.copyItem(at: source, to: backup) }
        }
        let staging = databaseURL.appendingPathExtension("migration-" + UUID().uuidString)
        defer {
            for path in [staging.path, staging.path + "-wal", staging.path + "-shm"] { try? manager.removeItem(atPath: path) }
        }
        var db: JournalDatabase? = try JournalDatabase(url: staging)
        let importedState = state ?? legacyState(commitID: document.syncCommitID)
        try db?.save(document, state: importedState)
        guard try db?.load() == document, try db?.scalar("SELECT count(*) FROM pragma_integrity_check WHERE integrity_check != 'ok'") == 0,
              try db?.loadSyncState() == importedState else { throw CocoaError(.fileReadCorruptFile) }
        try db?.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        db = nil
        try manager.moveItem(at: staging, to: databaseURL)
        database = try JournalDatabase(url: databaseURL)
        _ = try database?.load()
        remember(try database?.loadSyncState())
        try makeDailyBackup(document)
    }

    private func makeDailyBackup(_ document: JournalDocument) throws {
        let key = JournalDates.key(Date())
        guard dailyBackupKey != key else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let daily = backupsDirectory.appendingPathComponent("\(key).json")
        if !manager.fileExists(atPath: daily.path) { try Self.encode(document).write(to: daily, options: .atomic) }
        let snapshots = try manager.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: nil)
            .filter { JournalDates.date(for: $0.deletingPathExtension().lastPathComponent) != nil }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for obsolete in snapshots.dropFirst(30) { try manager.removeItem(at: obsolete) }
        dailyBackupKey = key
    }
}
