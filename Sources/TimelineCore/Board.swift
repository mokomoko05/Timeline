import Foundation

public enum BoardOwner: Codable, Equatable, Hashable {
    case task(UUID)
    case tag(String)

    var lookupKey: BoardOwner {
        if case .tag(let name) = self { return .tag(TagText.key(name)) }
        return self
    }

    public func matches(_ other: BoardOwner) -> Bool {
        switch (self, other) {
        case (.task(let first), .task(let second)): return first == second
        case (.tag(let first), .tag(let second)): return TagText.key(first) == TagText.key(second)
        default: return false
        }
    }
}

public struct Board: Codable, Equatable, Identifiable {
    public var id: UUID
    public var owner: BoardOwner
    public var title: String
    public var markdown: String
    public var archived: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var hasContent: Bool { !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public init(id: UUID = UUID(), owner: BoardOwner, title: String, markdown: String = "", now: Date = Date()) {
        self.id = id
        self.owner = owner
        self.title = title
        self.markdown = markdown
        archived = false
        createdAt = now
        updatedAt = now
    }

    private enum CodingKeys: String, CodingKey {
        case id, owner, title, markdown, items, archived, createdAt, updatedAt
    }

    private struct LegacyItem: Decodable {
        let kind: String
        let title: String
        let body: String
        let completed: Bool

        var markdown: String {
            if kind == "step" {
                let heading = "- [\(completed ? "x" : " ")] \(title)"
                let details = body.components(separatedBy: "\n").map { "  " + $0 }.joined(separator: "\n")
                return body.isEmpty ? heading : heading + "\n\n" + details
            }
            return [title.isEmpty ? "" : "## " + title, body].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        owner = try values.decode(BoardOwner.self, forKey: .owner)
        title = try values.decode(String.self, forKey: .title)
        archived = try values.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        if let source = try values.decodeIfPresent(String.self, forKey: .markdown) {
            markdown = source
        } else {
            markdown = try values.decodeIfPresent([LegacyItem].self, forKey: .items)?
                .map(\.markdown).joined(separator: "\n\n") ?? ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(owner, forKey: .owner)
        try values.encode(title, forKey: .title)
        try values.encode(markdown, forKey: .markdown)
        try values.encode(archived, forKey: .archived)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
    }
}

extension JournalStore {
    public var favoriteBoardIDs: [UUID] { boardFavoriteOrder ?? [] }

    public func setBoardFavoriteOrder(_ ids: [UUID]) {
        guard !isReadOnly else { return }
        var seen = Set<UUID>()
        let order = ids.filter { seen.insert($0).inserted }
        guard boardFavoriteOrder != order else { return }
        boardFavoriteOrder = order
        registryChanged()
    }

    public func toggleBoardFavorite(_ id: UUID) {
        guard boards.contains(where: { $0.id == id }) else { return }
        var order = favoriteBoardIDs
        if order.contains(id) { order.removeAll { $0 == id } } else { order.append(id) }
        setBoardFavoriteOrder(order)
    }

    public func moveBoardFavorite(_ id: UUID, to destination: Int) {
        var order = favoriteBoardIDs
        guard let index = order.firstIndex(of: id) else { return }
        order.remove(at: index)
        order.insert(id, at: max(0, min(destination, order.count)))
        setBoardFavoriteOrder(order)
    }

    public func board(for owner: BoardOwner) -> Board? {
        if cachedBoardIndices == nil {
            var indices: [BoardOwner: Int] = [:]
            for (index, board) in boards.enumerated() where !board.archived {
                let key = board.owner.lookupKey
                if indices[key] == nil { indices[key] = index }
            }
            cachedBoardIndices = indices
        }
        return cachedBoardIndices?[owner.lookupKey].map { boards[$0] }
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

    public func setBoardMarkdown(_ markdown: String, for id: UUID) {
        guard !isReadOnly, let index = boards.firstIndex(where: { $0.id == id }), boards[index].markdown != markdown else { return }
        var updated = boards
        updated[index].markdown = markdown
        updated[index].updatedAt = Date()
        replaceBoards(updated, action: "编辑工作板", debounce: true)
    }

    public func toggleBoardMarkdownTask(atLine line: Int, in id: UUID) {
        guard !isReadOnly, let board = boards.first(where: { $0.id == id }) else { return }
        var lines = board.markdown.components(separatedBy: "\n")
        guard line > 0, line <= lines.count,
              let expression = try? NSRegularExpression(pattern: #"^(?:[ \t]*>[ \t]*)*[ \t]*(?:[-+*]|[0-9]+[.)])[ \t]+\[([ xX])\](?=[ \t\r]|$)"#) else { return }
        let source = lines[line - 1] as NSString
        guard let match = expression.firstMatch(in: source as String, range: NSRange(location: 0, length: source.length)) else { return }
        let marker = match.range(at: 1)
        lines[line - 1] = source.replacingCharacters(in: marker, with: source.substring(with: marker) == " " ? "x" : " ")
        setBoardMarkdown(lines.joined(separator: "\n"), for: id)
    }
}
