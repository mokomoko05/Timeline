import Foundation

/// 最近删除里的一项：删掉的日志、待办或工作板，连同它原来所在的日期。
public struct DeletedItem: Codable, Identifiable, Equatable {
    public enum Content: Codable, Equatable {
        case log(DailyLogEntry, day: String)
        case task(Todo, day: String)
        case board(Board)
    }

    /// 就是原来那条记录的 id：恢复后同步把它当成同一条记录复活。
    public var id: UUID
    public var deletedAt: Date
    public var content: Content

    public init(id: UUID, deletedAt: Date, content: Content) {
        self.id = id
        self.deletedAt = deletedAt
        self.content = content
    }
}

/// 最近删除只存在本机（`Trash.json`），不同步：每台设备各自留一份，别的设备同步过来的删除也会进来，
/// 所以任何一台设备上误删了，其他设备都还能找回来。保留 30 天。
extension JournalStore {
    public static let deletedRetention: TimeInterval = 30 * 24 * 3600
    static let deletedLimit = 1000

    public var trashURL: URL { directory.appendingPathComponent("Trash.json") }

    func loadRecentlyDeleted(now: Date = Date()) {
        guard let data = try? Data(contentsOf: trashURL),
              let items = try? JSONDecoder().decode([DeletedItem].self, from: data) else { return }
        let kept = items.filter { now.timeIntervalSince($0.deletedAt) < Self.deletedRetention }
        recentlyDeleted = kept
        if kept.count != items.count { writeRecentlyDeleted() }
    }

    private func writeRecentlyDeleted() {
        guard !isReadOnly else { return }
        if recentlyDeleted.isEmpty {
            try? FileManager.default.removeItem(at: trashURL)
        } else if let data = try? JSONEncoder().encode(recentlyDeleted) {
            try? data.write(to: trashURL, options: .atomic)
        }
    }

    /// 比较修改前后的这几天：消失的日志、待办进最近删除（只是挪到别的日期不算），又出现的（撤销、恢复）移出来。
    func trackDeletions<Keys: Sequence>(from old: [String: DayEntry], to new: [String: DayEntry], keys: Keys, now: Date = Date()) where Keys.Element == String {
        var removed: [DeletedItem] = []
        var returned = Set<UUID>()
        for key in keys {
            let before = old[key], after = new[key]
            let beforeLogs = before?.logs ?? [], afterLogs = after?.logs ?? []
            if beforeLogs != afterLogs {
                let kept = Set(afterLogs.map(\.id))
                removed += beforeLogs.filter { !kept.contains($0.id) }.map { DeletedItem(id: $0.id, deletedAt: now, content: .log($0, day: key)) }
                returned.formUnion(kept.subtracting(beforeLogs.map(\.id)))
            }
            let beforeTodos = before?.todos ?? [], afterTodos = after?.todos ?? []
            if beforeTodos != afterTodos {
                let kept = Set(afterTodos.map(\.id))
                removed += beforeTodos.filter { !kept.contains($0.id) }.map { DeletedItem(id: $0.id, deletedAt: now, content: .task($0, day: key)) }
                returned.formUnion(kept.subtracting(beforeTodos.map(\.id)))
            }
        }
        if !removed.isEmpty {
            let present = Set(new.values.flatMap { $0.logs.map(\.id) + $0.todos.map(\.id) })
            removed.removeAll { present.contains($0.id) }
        }
        updateRecentlyDeleted(adding: removed, returned: returned, now: now)
    }

    /// 工作板：整页消失才算删除（归档、清空内容都不算，清空靠版本历史找回）。
    func trackBoardDeletions(from old: [Board], to new: [Board], now: Date = Date()) {
        let kept = Set(new.map(\.id)), had = Set(old.map(\.id))
        let removed = old.filter { !kept.contains($0.id) && $0.hasContent }.map { DeletedItem(id: $0.id, deletedAt: now, content: .board($0)) }
        updateRecentlyDeleted(adding: removed, returned: kept.subtracting(had), now: now)
    }

    private func updateRecentlyDeleted(adding removed: [DeletedItem], returned: Set<UUID>, now: Date) {
        guard !removed.isEmpty || (!returned.isEmpty && recentlyDeleted.contains(where: { returned.contains($0.id) })) else { return }
        let replaced = Set(removed.map(\.id))
        var items = recentlyDeleted.filter { !returned.contains($0.id) && !replaced.contains($0.id) && now.timeIntervalSince($0.deletedAt) < Self.deletedRetention }
        items.insert(contentsOf: removed, at: 0)
        if items.count > Self.deletedLimit { items.removeLast(items.count - Self.deletedLimit) }
        recentlyDeleted = items
        writeRecentlyDeleted()
    }

    /// 放回原来的日期 / 工作板列表，可以撤销；同步把它当作一次新修改，其他设备上也会回来。
    @discardableResult
    public func restoreDeleted(_ id: UUID) -> Bool {
        guard !isReadOnly, let item = recentlyDeleted.first(where: { $0.id == id }) else { return false }
        switch item.content {
        case .log(let log, let day):
            guard let date = JournalDates.date(for: day) else { return false }
            if days.values.contains(where: { $0.logs.contains { $0.id == log.id } }) { break }
            change(date, action: "恢复日志") { entry in
                let index = entry.logs.firstIndex { $0.createdAt > log.createdAt } ?? entry.logs.count
                entry.logs.insert(log, at: index)
            }
        case .task(let todo, let day):
            guard let date = JournalDates.date(for: day) else { return false }
            if locate(todo.id) != nil { break }
            var restored = todo
            // 编号被别的任务占了（另一台设备同步时重新编过号），换一个新号。
            if restored.number.map({ locate(number: $0) != nil }) ?? true { restored = allocate(restored) }
            change(date, action: "恢复待办") { $0.todos.append(restored) }
        case .board(var board):
            if boards.contains(where: { $0.id == board.id }) { break }
            // 同一个任务 / 标签已经有了新的工作板：恢复成归档页，不顶替现在这页。
            if self.board(for: board.owner) != nil { board.archived = true }
            replaceBoards(boards + [board], action: "恢复工作板")
        }
        if recentlyDeleted.contains(where: { $0.id == id }) { updateRecentlyDeleted(adding: [], returned: [id], now: Date()) }
        return true
    }

    /// 立即永久删除。
    public func purgeDeleted(_ ids: Set<UUID>) {
        guard !isReadOnly, recentlyDeleted.contains(where: { ids.contains($0.id) }) else { return }
        recentlyDeleted.removeAll { ids.contains($0.id) }
        writeRecentlyDeleted()
    }

    public func emptyRecentlyDeleted() { purgeDeleted(Set(recentlyDeleted.map(\.id))) }

    /// 最近删除里的日志还引用着的图片：清理没用的图片时要留着。
    var imagesInRecentlyDeleted: Set<String> {
        Set(recentlyDeleted.flatMap { item -> [String] in
            if case .log(let log, _) = item.content { return log.images }
            return []
        })
    }
}

extension DeletedItem {
    /// 列表里显示的一行字。
    public var title: String {
        switch content {
        case .log(let log, _):
            let text = log.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return text.isEmpty ? (log.images.isEmpty ? "" : "[图片]") : text
        case .task(let todo, _): return String(TaskText.rendered(todo.title).characters)
        case .board(let board):
            if case .tag(let name) = board.owner { return "#" + name }
            return board.title
        }
    }

    /// 原来所在的日期（工作板没有）。
    public var day: Date? {
        switch content {
        case .log(_, let day), .task(_, let day): return JournalDates.date(for: day)
        case .board: return nil
        }
    }
}
