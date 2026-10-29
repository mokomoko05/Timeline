import Foundation

/// 列表摘要和搜索内容一次准备好，搜索输入和拖动收藏时不重复解析 Markdown。
public struct BoardListEntry: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date
    public let headings: [String]
    public let openTasks: Int
    public let doneTasks: Int
    private let searchText: String

    public init(board: Board, title: String) {
        id = board.id
        self.title = title
        updatedAt = board.updatedAt
        let lines = board.markdown.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        headings = Array(lines.filter { $0.hasPrefix("#") }.prefix(3).map { $0.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) })
        openTasks = lines.filter { $0.hasPrefix("- [ ]") }.count
        doneTasks = lines.filter { $0.hasPrefix("- [x]") || $0.hasPrefix("- [X]") }.count
        searchText = Self.normalized(title + "\n" + board.markdown)
    }

    public func matches(_ query: String) -> Bool {
        Self.normalized(query).split(whereSeparator: \.isWhitespace).allSatisfy { searchText.contains($0) }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
