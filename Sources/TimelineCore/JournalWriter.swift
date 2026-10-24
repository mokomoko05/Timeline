import Foundation

/// 在串行队列上编码并写入 journal。
///
/// 主线程只取一份文档快照（值类型，写时复制，开销很小），编码和原子写入都在这里完成。
/// 每次写入带递增版本号：较旧的快照到达时已被更新的版本取代，直接跳过，不会用旧内容覆盖新内容。
/// 同步写入（退出、关窗口、需要确认落盘的操作）走同一个队列，所以一定排在所有已提交的后台写入之后。
final class JournalWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Timeline.JournalWriter", qos: .userInitiated)
    private let fileURL: URL
    private let backupsDirectory: URL
    // 以下状态只在 `queue` 上访问。
    private var writtenVersion = 0
    private var dailyBackupKey: String?

    init(fileURL: URL, backupsDirectory: URL) {
        self.fileURL = fileURL
        self.backupsDirectory = backupsDirectory
    }

    static func encode<Document: Encodable>(_ document: Document) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    /// 阻塞到写入完成；返回 nil 表示成功（或已被更新的版本取代）。
    func writeNow<Document: Encodable>(_ document: Document, version: Int) -> Error? {
        queue.sync { write(document, version: version) }
    }

    /// 后台写入；完成后在主线程回调。
    func write<Document: Encodable>(_ document: Document, version: Int,
                                    completion: @escaping @Sendable (Error?) -> Void) {
        queue.async { [self] in
            let error = write(document, version: version)
            DispatchQueue.main.async { completion(error) }
        }
    }

    /// 测试和退出流程用：等所有已提交的写入完成。
    func waitUntilIdle() { queue.sync {} }

    private func write<Document: Encodable>(_ document: Document, version: Int) -> Error? {
        guard version > writtenVersion else { return nil }
        do {
            let data = try Self.encode(document)
            try makeDailyBackup(data)
            try data.write(to: fileURL, options: .atomic)
            writtenVersion = version
            return nil
        } catch {
            return error
        }
    }

    /// 每天第一次保存时留一份快照，保留最近 30 天。
    private func makeDailyBackup(_ data: Data) throws {
        let key = JournalDates.key(Date())
        guard dailyBackupKey != key else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let daily = backupsDirectory.appendingPathComponent("\(key).json")
        if !manager.fileExists(atPath: daily.path) { try data.write(to: daily, options: .atomic) }
        let snapshots = try manager.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: nil)
            .filter { JournalDates.date(for: $0.deletingPathExtension().lastPathComponent) != nil }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for obsolete in snapshots.dropFirst(30) { try manager.removeItem(at: obsolete) }
        dailyBackupKey = key
    }
}
