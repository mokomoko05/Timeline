import Foundation

public enum BoardOwner: Codable, Equatable, Hashable {
    case task(UUID)
    case tag(String)

    public func matches(_ other: BoardOwner) -> Bool {
        switch (self, other) {
        case (.task(let first), .task(let second)): return first == second
        case (.tag(let first), .tag(let second)): return TagText.key(first) == TagText.key(second)
        default: return false
        }
    }
}

public struct BoardItem: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable { case step, note }
    public var id: UUID
    public var kind: Kind
    public var title: String
    public var body: String
    public var completed: Bool

    public init(id: UUID = UUID(), kind: Kind = .step, title: String = "", body: String = "", completed: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.completed = kind == .step && completed
    }
}

public struct Board: Codable, Equatable, Identifiable {
    public var id: UUID
    public var owner: BoardOwner
    public var title: String
    public var items: [BoardItem]
    public var archived: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), owner: BoardOwner, title: String, items: [BoardItem] = [], now: Date = Date()) {
        self.id = id
        self.owner = owner
        self.title = title
        self.items = items
        archived = false
        createdAt = now
        updatedAt = now
    }

    public var stepCount: Int { items.filter { $0.kind == .step }.count }
    public var completedCount: Int { items.filter { $0.kind == .step && $0.completed }.count }
}

extension JournalStore {
    public func board(for owner: BoardOwner) -> Board? {
        boards.first { !$0.archived && $0.owner.matches(owner) }
    }

    public func boardTitle(_ board: Board) -> String {
        switch board.owner {
        case .task(let id): return locate(id).map { String(TaskText.rendered($0.task.title).characters) } ?? board.title
        case .tag(let name): return "#" + name
        }
    }

    public func isBoardArchived(_ board: Board) -> Bool {
        if board.archived { return true }
        if case .task(let id) = board.owner { return locate(id) == nil }
        return false
    }

    @discardableResult
    public func ensureBoard(for owner: BoardOwner) -> Board? {
        if let existing = board(for: owner) { return existing }
        guard !isReadOnly else { return nil }
        let resolved: BoardOwner
        let title: String
        switch owner {
        case .task(let id):
            guard let task = locate(id) else { return nil }
            resolved = owner
            title = String(TaskText.rendered(task.task.title).characters)
        case .tag(let raw):
            guard let name = createTag(raw) else { return nil }
            resolved = .tag(name)
            title = name
        }
        let board = Board(owner: resolved, title: title)
        replaceBoards(boards + [board], action: "创建工作板")
        return board
    }

    @discardableResult
    public func addBoardItem(to boardID: UUID, kind: BoardItem.Kind = .step, title: String = "", body: String = "") -> UUID? {
        guard !isReadOnly, boards.contains(where: { $0.id == boardID }) else { return nil }
        let item = BoardItem(kind: kind, title: title, body: body)
        mutateBoard(boardID, action: "添加工作板条目") { $0.items.append(item) }
        return item.id
    }

    public func updateBoardItem(_ itemID: UUID, in boardID: UUID, title: String? = nil, body: String? = nil, completed: Bool? = nil) {
        mutateBoard(boardID, action: "编辑工作板", debounce: title != nil || body != nil) { board in
            guard let index = board.items.firstIndex(where: { $0.id == itemID }) else { return }
            if let title { board.items[index].title = title }
            if let body { board.items[index].body = body }
            if let completed, board.items[index].kind == .step { board.items[index].completed = completed }
        }
    }

    public func deleteBoardItem(_ itemID: UUID, in boardID: UUID) {
        mutateBoard(boardID, action: "删除工作板条目") { $0.items.removeAll { $0.id == itemID } }
    }

    public func moveBoardItem(_ itemID: UUID, in boardID: UUID, to target: Int) {
        mutateBoard(boardID, action: "排序工作板") { board in
            guard let source = board.items.firstIndex(where: { $0.id == itemID }) else { return }
            let item = board.items.remove(at: source)
            board.items.insert(item, at: max(0, min(target, board.items.count)))
        }
    }

    public func applyBoardTemplate(_ titles: [String], to boardID: UUID) {
        mutateBoard(boardID, action: "应用工作板模板") { board in
            board.items.append(contentsOf: titles.map { BoardItem(title: $0) })
        }
    }

    private func mutateBoard(_ id: UUID, action: String, debounce: Bool = false, mutation: (inout Board) -> Void) {
        guard !isReadOnly, let index = boards.firstIndex(where: { $0.id == id }) else { return }
        var updated = boards
        mutation(&updated[index])
        guard updated != boards else { return }
        updated[index].updatedAt = Date()
        replaceBoards(updated, action: action, debounce: debounce)
    }
}
