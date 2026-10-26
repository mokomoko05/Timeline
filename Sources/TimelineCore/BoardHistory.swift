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

/// 每页工作板一个文件（`BoardHistory/<id>.json`），只存在本机。一段连续编辑开始前，把改之前的内容存一版；
/// 同一页 10 分钟内的连续修改只存一版。同步覆盖或合并冲突前一定存一版。每页最多留 `limit` 版。
final class BoardHistory: @unchecked Sendable {
    static let interval: TimeInterval = 10 * 60
    static let limit = 60

    let directory: URL
    private let writesInBackground: Bool
    private let queue = DispatchQueue(label: "local.timeline.board-history")
    /// 主线程上的缓存：每页已经存过的版本。读过一次文件就不再读。
    private var versions: [UUID: [BoardVersion]] = [:]

    init(directory: URL, writesInBackground: Bool) {
        self.directory = directory
        self.writesInBackground = writesInBackground
    }

    private func url(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    /// 新的在前。
    func versions(of id: UUID) -> [BoardVersion] {
        if let cached = versions[id] { return cached }
        queue.sync {}
        let loaded = (try? Data(contentsOf: url(for: id))).flatMap { try? JSONDecoder().decode([BoardVersion].self, from: $0) } ?? []
        versions[id] = loaded
        return loaded
    }

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
        let target = url(for: id), directory = directory
        let write = {
            guard let data = try? JSONEncoder().encode(list) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: target, options: .atomic)
        }
        if writesInBackground { queue.async(execute: write) } else { queue.sync(execute: write) }
    }

    func waitUntilIdle() { queue.sync {} }
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
        let current = boards.first { $0.id == id }?.markdown
        return boardHistory.versions(of: id).filter { $0.markdown != current }
    }

    /// 换回某个历史版本：当前内容先存一版，可以撤销。
    public func restoreBoardVersion(_ version: BoardVersion, for id: UUID) {
        guard !isReadOnly, let board = boards.first(where: { $0.id == id }), board.markdown != version.markdown else { return }
        boardHistory.record(board.markdown, for: id, force: true)
        var updated = boards
        if let index = updated.firstIndex(where: { $0.id == id }) {
            updated[index].markdown = version.markdown
            updated[index].updatedAt = Date()
        }
        replaceBoards(updated, action: "恢复工作板版本")
    }

    public func waitForBoardHistory() { boardHistory.waitUntilIdle() }
}
