import CSQLite
import Foundation

/// 仅供 JournalWriter 串行队列使用；云端仍使用不可变 JSON 批次，绝不共享 WAL。
final class JournalDatabase {
    private var connection: OpaquePointer?
    private(set) var document: JournalDocument?
    private var syncState: SyncState?
    private(set) var lastChangedRows = 0
    private(set) var lastPayloadBytes = 0
    let url: URL

    struct Failure: LocalizedError {
        let code: Int32
        let detail: String
        var errorDescription: String? { "SQLite (\(code)): \(detail)" }
    }

    init(url: URL, readOnly: Bool = false) throws {
        self.url = url
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let opened = sqlite3_open_v2(url.path, &connection, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard opened == SQLITE_OK else {
            let error = failure(); sqlite3_close(connection); connection = nil; throw error
        }
        do {
            sqlite3_busy_timeout(connection, 2000)
            let version = try scalar("PRAGMA user_version")
            guard version == 0 || version == 1 else { throw CocoaError(.fileReadUnknown) }
            if !readOnly {
                try execute("PRAGMA journal_mode=WAL")
                try execute("PRAGMA synchronous=FULL")
                try execute("PRAGMA wal_autocheckpoint=512")
                try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value BLOB NOT NULL) WITHOUT ROWID")
                try execute("CREATE TABLE IF NOT EXISTS entities (key TEXT PRIMARY KEY, value BLOB NOT NULL) WITHOUT ROWID")
                try execute("CREATE TABLE IF NOT EXISTS sync_records (key TEXT PRIMARY KEY, value BLOB NOT NULL) WITHOUT ROWID")
                if version == 0 { try execute("PRAGMA user_version=1") }
            }
        } catch {
            sqlite3_close(connection); connection = nil; throw error
        }
    }

    deinit { sqlite3_close(connection) }
    private func failure() -> Failure { Failure(code: sqlite3_errcode(connection), detail: url.path + ": " + String(cString: sqlite3_errmsg(connection))) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    func scalar(_ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// 使用 SQLite backup API，包含 WAL 中已提交内容。
    func backup(to target: URL) throws {
        var output: OpaquePointer?
        guard sqlite3_open_v2(target.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close(output); throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(output) }
        guard let backup = sqlite3_backup_init(output, "main", connection, "main") else { throw failure() }
        let code = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard code == SQLITE_DONE, finished == SQLITE_OK else { throw Failure(code: code, detail: "Unable to create consistent database backup") }
        guard sqlite3_exec(output, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    private func rows(_ table: String) throws -> [String: Data] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "SELECT key,value FROM \(table)", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        var result: [String: Data] = [:]
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let key = sqlite3_column_text(statement, 0) else { throw failure() }
            let length = Int(sqlite3_column_bytes(statement, 1))
            result[String(cString: key)] = length == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, 1)!, count: length)
        }
        return result
    }

    private func put(_ table: String, key: String, data: Data?) throws {
        let sql = data == nil ? "DELETE FROM \(table) WHERE key=?" : "INSERT INTO \(table)(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE value != excluded.value"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, key, -1, transient) == SQLITE_OK else { throw failure() }
        if let data {
            let code = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), transient) }
            guard code == SQLITE_OK else { throw failure() }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        lastChangedRows += Int(sqlite3_changes(connection))
        if sqlite3_changes(connection) > 0 { lastPayloadBytes += data?.count ?? 0 }
    }

    func load() throws -> JournalDocument? {
        let meta = try rows("metadata")
        guard let header = meta["journal"] else { return nil }
        var result = try JSONDecoder().decode(JournalDocument.self, from: header)
        let entities = try rows("entities")
        let decoder = JSONDecoder()
        // 有序列表使用每条实体自己的位置，改正文不重写整天的 ID 列表。
        var todos: [String: [(Int, Todo)]] = [:], logs: [String: [(Int, DailyLogEntry)]] = [:]
        var boards: [(Int, Board)] = []
        for (key, data) in entities {
            if key.hasPrefix("day/") { result.days[String(key.dropFirst(4))] = try decoder.decode(DayEntry.self, from: data) }
            else if key.hasPrefix("todo/") {
                let item = try decoder.decode(Located<Todo>.self, from: data)
                todos[item.day, default: []].append((item.position, item.value))
            } else if key.hasPrefix("log/") {
                let item = try decoder.decode(Located<DailyLogEntry>.self, from: data)
                logs[item.day, default: []].append((item.position, item.value))
            } else if key.hasPrefix("board/") {
                let item = try decoder.decode(Located<Board>.self, from: data)
                boards.append((item.position, item.value))
            }
        }
        for (day, items) in todos { result.days[day, default: DayEntry()].todos = items.sorted { $0.0 < $1.0 }.map(\.1) }
        for (day, items) in logs { result.days[day, default: DayEntry()].logs = items.sorted { $0.0 < $1.0 }.map(\.1) }
        if !boards.isEmpty { result.boards = boards.sorted { $0.0 < $1.0 }.map(\.1) }
        document = result
        return result
    }

    func loadSyncState() throws -> SyncState? {
        let meta = try rows("metadata")
        guard let data = meta["sync"] else { return nil }
        var state = try JSONDecoder().decode(SyncState.self, from: data)
        state.records = try rows("sync_records").mapValues { try JSONDecoder().decode(SyncRecord.self, from: $0) }
        if let ledger = meta["transport"] { state.ledger = try JSONDecoder().decode(IncrementalState.self, from: ledger) }
        syncState = state
        return state
    }

    private struct Located<T: Codable>: Codable {
        var day: String
        var position: Int
        var value: T
    }

    /// 队列上比较值快照，仅编码变动实体；缓存仅在 COMMIT 成功后更新。
    func save(_ next: JournalDocument, state: SyncState? = nil) throws {
        var edits: [String: Data?] = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let old = document
        for day in Set(next.days.keys).union(old?.days.keys.map { $0 } ?? []) {
            let before = old?.days[day], after = next.days[day]
            guard before != after else { continue }
            var metadata = after
            metadata?.todos = []; metadata?.logs = []
            edits["day/" + day] = .some(try metadata.map { try encoder.encode($0) })
            let previousTodos = Dictionary((before?.todos ?? []).enumerated().map { ($1.id, ($0, $1)) }, uniquingKeysWith: { first, _ in first })
            let currentTodos = Dictionary((after?.todos ?? []).enumerated().map { ($1.id, ($0, $1)) }, uniquingKeysWith: { first, _ in first })
            for id in Set(previousTodos.keys).union(currentTodos.keys) {
                let a = previousTodos[id], b = currentTodos[id]
                if a?.0 != b?.0 || a?.1 != b?.1 {
                    edits["todo/" + id.uuidString] = .some(try b.map { try encoder.encode(Located(day: day, position: $0.0, value: $0.1)) })
                }
            }
            let previousLogs = Dictionary((before?.logs ?? []).enumerated().map { ($1.id, ($0, $1)) }, uniquingKeysWith: { first, _ in first })
            let currentLogs = Dictionary((after?.logs ?? []).enumerated().map { ($1.id, ($0, $1)) }, uniquingKeysWith: { first, _ in first })
            for id in Set(previousLogs.keys).union(currentLogs.keys) {
                let a = previousLogs[id], b = currentLogs[id]
                if a?.0 != b?.0 || a?.1 != b?.1 {
                    edits["log/" + id.uuidString] = .some(try b.map { try encoder.encode(Located(day: day, position: $0.0, value: $0.1)) })
                }
            }
        }
        // 移动跨日期的实体时删除与新增不能由字典遍历顺序决定。
        for (day, entry) in next.days {
            if let before = old?.days[day], before == entry { continue }
            for (index, todo) in entry.todos.enumerated() where edits.keys.contains("todo/" + todo.id.uuidString) {
                edits["todo/" + todo.id.uuidString] = .some(try encoder.encode(Located(day: day, position: index, value: todo)))
            }
            for (index, log) in entry.logs.enumerated() where edits.keys.contains("log/" + log.id.uuidString) {
                edits["log/" + log.id.uuidString] = .some(try encoder.encode(Located(day: day, position: index, value: log)))
            }
        }
        if old?.boards != next.boards {
            let before = Dictionary((old?.boards ?? []).enumerated().map { ($1.id, ($0, $1)) }, uniquingKeysWith: { first, _ in first })
            let after = Dictionary((next.boards ?? []).enumerated().map { ($1.id, ($0, $1)) }, uniquingKeysWith: { first, _ in first })
            for id in Set(before.keys).union(after.keys) {
                let a = before[id], b = after[id]
                if a?.0 != b?.0 || a?.1 != b?.1 { edits["board/" + id.uuidString] = .some(try b.map { try encoder.encode(Located(day: "", position: $0.0, value: $0.1)) }) }
            }
        }
        var header = next
        header.days = [:]; header.boards = next.boards?.isEmpty == true ? [] : nil
        let headerData = try encoder.encode(header)
        lastChangedRows = 0; lastPayloadBytes = 0
        try execute("BEGIN IMMEDIATE")
        do {
            for (key, value) in edits { try put("entities", key: key, data: value) }
            try put("metadata", key: "journal", data: headerData)
            if let state {
                // 基线元数据丢失或重建时，旧记录不能混进新设备基线。
                if syncState == nil { try execute("DELETE FROM sync_records") }
                if syncState?.records != state.records {
                    for key in Set(syncState?.records.keys.map { $0 } ?? []).union(state.records.keys) where syncState?.records[key] != state.records[key] {
                        try put("sync_records", key: key, data: try state.records[key].map { try encoder.encode($0) })
                    }
                }
                var context = state
                context.records = [:]; context.ledger = nil
                try put("metadata", key: "sync", data: encoder.encode(context))
                try put("metadata", key: "transport", data: state.ledger.map { try encoder.encode($0) })
            }
            try execute("COMMIT")
            document = next
            if let state { syncState = state }
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func saveTransport(_ state: SyncState) throws {
        guard let saved = try syncState ?? loadSyncState(), saved.device == state.device, saved.commitID == state.commitID,
              saved.folderPath == state.folderPath else { throw CocoaError(.fileWriteUnknown) }
        let data = try state.ledger.map { try IncrementalSync.encode($0) }
        try put("metadata", key: "transport", data: data)
        syncState?.ledger = state.ledger
    }
}
