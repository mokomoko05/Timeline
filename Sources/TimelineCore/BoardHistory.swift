import Foundation

/// 工作板的一个历史版本。
public struct BoardVersion: Codable, Identifiable, Equatable {
    public var id: UUID
    public var savedAt: Date
    public var markdown: String

    public init(id: UUID = UUID(), savedAt: Date, markdown: String) {
        self.id = id
        self.savedAt = savedAt
        self.markdown = markdown
    }
}

/// 历史与正文一起提交到本机 SQLite；兼容导入旧 `BoardHistory/<id>.json`。一段连续编辑开始前，把改之前的内容存一版；
/// 同一页 10 分钟内的连续修改只存一版。同步覆盖或合并冲突前一定存一版。每页最多留 `limit` 版。
final class BoardHistory: @unchecked Sendable {
    static let interval: TimeInterval = 10 * 60
    static let limit = 60

    /// 主线程上的值缓存；旧文件只在迁移时导入。
    private var versions: [UUID: [BoardVersion]] = [:]
    private var persistedSnapshot: [String: [BoardVersion]] = [:]

    init(initial: [String: [BoardVersion]] = [:]) {
        versions = Dictionary(initial.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } }, uniquingKeysWith: { a, b in Array((a + b).sorted { $0.savedAt > $1.savedAt }.prefix(Self.limit)) })
        persistedSnapshot = Dictionary(versions.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    static func legacyVersions(in directory: URL) throws -> [String: [BoardVersion]] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        var result: [String: [BoardVersion]] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            result[id.uuidString] = try JSONDecoder().decode([BoardVersion].self, from: Data(contentsOf: file))
        }
        return result
    }

    /// 新的在前。旧文件已在迁移时统一导入，前台不读盘。
    func versions(of id: UUID) -> [BoardVersion] { versions[id] ?? [] }

    /// 存下 `markdown` 作为这页的一个版本；`force` 为 false 时，离上一版不到 10 分钟就跳过。
    func record(_ markdown: String, for id: UUID, now: Date = Date(), force: Bool = false) {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var list = versions(of: id)
        if let latest = list.first {
            if latest.markdown == markdown { return }
            if !force, now.timeIntervalSince(latest.savedAt) < Self.interval { return }
        }
        list.insert(BoardVersion(savedAt: now, markdown: markdown), at: 0)
        if list.count > Self.limit { list.removeLast(list.count - Self.limit) }
        versions[id] = list
        persistedSnapshot[id.uuidString] = list
    }

    func importVersions(_ incoming: [String: [BoardVersion]]) {
        for (key, list) in incoming {
            guard let id = UUID(uuidString: key) else { continue }
            let previous = versions(of: id)
            let ids = Set(previous.map(\.id))
            versions[id] = Array((previous + list.filter { !ids.contains($0.id) }).sorted { $0.savedAt > $1.savedAt }.prefix(Self.limit))
            persistedSnapshot[id.uuidString] = versions[id]
        }
    }

    var snapshot: [String: [BoardVersion]] {
        persistedSnapshot
    }

}

extension JournalStore {
    /// 工作板内容变了：把变化前的内容记进历史。
    func recordBoardVersions(from old: [Board], to new: [Board], force: Bool = false) {
        guard !isReadOnly else { return }
        let updated = old.count == new.count && zip(old, new).allSatisfy { $0.id == $1.id }
            ? Dictionary(uniqueKeysWithValues: zip(old.map(\.id), new.map(\.markdown)))
            : Dictionary(new.map { ($0.id, $0.markdown) }, uniquingKeysWith: { first, _ in first })
        for board in old where updated[board.id] != board.markdown {
            boardHistory.record(board.markdown, for: board.id, force: force)
        }
    }

    /// 这页工作板的历史版本，新的在前（不含当前内容）。
    public func boardVersions(for id: UUID) -> [BoardVersion] {
        let canonical = resolvedBoardID(id)
        let current = board(id: canonical)?.markdown
        var seen = Set<UUID>()
        return boards.filter { resolvedBoardID($0.id) == canonical }.flatMap { board in
            boardHistory.versions(of: board.id) + (board.mergedInto != nil && board.hasContent ? [BoardVersion(id: board.id, savedAt: board.updatedAt, markdown: board.markdown)] : [])
        }
            .filter { $0.markdown != current && seen.insert($0.id).inserted }.sorted { $0.savedAt > $1.savedAt }
    }

    /// 换回某个历史版本：当前内容先存一版，可以撤销。
    public func restoreBoardVersion(_ version: BoardVersion, for id: UUID) {
        let id = resolvedBoardID(id)
        guard !isReadOnly, let board = boards.first(where: { $0.id == id }), board.markdown != version.markdown else { return }
        boardHistory.record(board.markdown, for: id, force: true)
        var updated = boards
        if let index = updated.firstIndex(where: { $0.id == id }) {
            updated[index].markdown = version.markdown
            updated[index].updatedAt = Date()
        }
        replaceBoards(updated, action: "恢复工作板版本")
    }

    public func waitForBoardHistory() { save() }
}
