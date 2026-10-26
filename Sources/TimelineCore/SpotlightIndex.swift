import Combine
@preconcurrency import CoreSpotlight
import Foundation
import OSLog
import UniformTypeIdentifiers

/// 放进系统 Spotlight 的一项：一条日志、一个待办或一页工作板。
public struct SpotlightItem: Equatable, Sendable {
    public enum Kind: String, Sendable { case log, task, board }

    public let kind: Kind
    public let id: UUID
    public var title: String
    public var detail: String
    public var text: String
    public var date: Date?
    public var tags: [String]

    /// Spotlight 里的唯一标识，也是点开结果时交回来的值：`log:<id>`。
    public var identifier: String { kind.rawValue + ":" + id.uuidString }

    /// 内容的指纹：没变的不重新索引。用稳定的 FNV-1a（`Hasher` 每次启动都不一样）。
    var signature: UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in [title, detail, text, tags.joined(separator: " "), date.map { String($0.timeIntervalSince1970) } ?? ""].joined(separator: "\u{1}").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return hash
    }

    var searchableItem: CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: kind == .board ? .text : .content)
        attributes.title = title
        attributes.contentDescription = detail
        attributes.textContent = text
        attributes.keywords = tags
        attributes.contentCreationDate = date
        attributes.contentModificationDate = date
        return CSSearchableItem(uniqueIdentifier: identifier, domainIdentifier: kind.rawValue, attributeSet: attributes)
    }

    /// 点开 Spotlight 结果：交回来的标识拆成种类和 id。
    public static func parse(_ identifier: String) -> (kind: Kind, id: UUID)? {
        let parts = identifier.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = Kind(rawValue: parts[0]), let id = UUID(uuidString: parts[1]) else { return nil }
        return (kind, id)
    }
}

extension JournalStore {
    /// 当前数据里该进 Spotlight 的全部内容。草稿、归档的工作板、空日志不进。
    public func spotlightItems() -> [SpotlightItem] {
        var items: [SpotlightItem] = []
        let format = Date.FormatStyle(date: .abbreviated, time: .shortened)
        for day in days.values {
            for log in day.logs {
                let body = log.searchableText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                let first = body.split(whereSeparator: \.isNewline).first.map { SpotlightText.plain(String($0)) } ?? ""
                var detail = log.createdAt.formatted(format)
                if let task = log.taskTitle { detail += " · " + task }
                let rest = body.split(whereSeparator: \.isNewline).dropFirst().prefix(3).map { SpotlightText.plain(String($0)) }.joined(separator: " ")
                if !rest.isEmpty { detail += "\n" + rest }
                items.append(SpotlightItem(kind: .log, id: log.id, title: first, detail: detail, text: body,
                                           date: log.createdAt, tags: log.tags + log.taskTags))
            }
            for todo in day.todos {
                let title = String(TaskText.rendered(todo.title).characters)
                var detail = todo.number.map { "#\($0)" } ?? ""
                if let due = todo.dueDate {
                    detail += (detail.isEmpty ? "" : " · ") + due.formatted(Date.FormatStyle(date: .abbreviated, time: todo.dueHasTime ? .shortened : .omitted))
                }
                if !todo.tags.isEmpty { detail += (detail.isEmpty ? "" : " · ") + todo.tags.map { "#" + $0 }.joined(separator: " ") }
                items.append(SpotlightItem(kind: .task, id: todo.id, title: title, detail: detail, text: title,
                                           date: todo.dueDate, tags: todo.tags))
            }
        }
        for board in boards where !isBoardArchived(board) && board.hasContent {
            let outline = board.markdown.split(whereSeparator: \.isNewline).lazy.map { SpotlightText.plain(String($0)) }
                .filter { !$0.isEmpty }.prefix(3).joined(separator: " · ")
            items.append(SpotlightItem(kind: .board, id: board.id, title: boardTitle(board), detail: outline, text: board.markdown,
                                       date: board.updatedAt, tags: []))
        }
        return items
    }
}

enum SpotlightText {
    /// 去掉行首的 Markdown 记号和链接写法，Spotlight 里读起来像正文。
    static func plain(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        for pattern in [#"^#{1,6}\s+"#, #"^>\s*"#, #"^[-+*]\s+\[[ xX]\]\s+"#, #"^[-+*]\s+"#, #"^\d+[.)]\s+"#] {
            if let range = text.range(of: pattern, options: .regularExpression) { text.removeSubrange(range); break }
        }
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"</?(summary|details)[^>]*>"#, with: "", options: .regularExpression)
        return text.replacingOccurrences(of: #"[*_`]{1,3}"#, with: "", options: .regularExpression)
    }
}

/// 让日志、待办和工作板出现在系统 Spotlight 里。数据停下来几秒后，只把变了的项重新交给系统，删掉的也删掉。
/// 已经交过的指纹存在 `Spotlight.json`，重启后不用全部重来。
@MainActor
public final class SpotlightIndexer {
    private let store: JournalStore
    private let index: CSSearchableIndex
    private let stateURL: URL
    private let queue = DispatchQueue(label: "local.timeline.spotlight", qos: .utility)
    private var indexed: [String: UInt64]
    private var changes: AnyCancellable?

    public init(store: JournalStore, index: CSSearchableIndex = .default()) {
        self.store = store
        self.index = index
        stateURL = store.directory.appendingPathComponent("Spotlight.json")
        indexed = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode([String: UInt64].self, from: $0) } ?? [:]
    }

    /// 开始跟着数据更新；先做一次。
    public func start(delay: TimeInterval = 3) {
        changes = store.$days.map { _ in () }.merge(with: store.$boards.map { _ in () })
            .debounce(for: .seconds(delay), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
    }

    public func update() {
        guard !store.isReadOnly else { return }
        let items = store.spotlightItems()
        var current: [String: UInt64] = [:]
        var changed: [SpotlightItem] = []
        for item in items {
            let signature = item.signature
            current[item.identifier] = signature
            if indexed[item.identifier] != signature { changed.append(item) }
        }
        let removed = indexed.keys.filter { current[$0] == nil }
        guard !changed.isEmpty || !removed.isEmpty else { return }
        indexed = current
        let index = index, stateURL = stateURL
        queue.async {
            let log = Logger(subsystem: "local.timeline", category: "spotlight")
            if !removed.isEmpty {
                index.deleteSearchableItems(withIdentifiers: removed) { error in
                    if let error { log.error("删除失败：\(error.localizedDescription, privacy: .public)") }
                }
            }
            for start in stride(from: 0, to: changed.count, by: 200) {
                let batch = changed[start..<min(start + 200, changed.count)].map(\.searchableItem)
                index.indexSearchableItems(batch) { error in
                    if let error { log.error("索引失败：\(error.localizedDescription, privacy: .public)") }
                    else { log.info("已索引 \(batch.count) 项") }
                }
            }
            if let data = try? JSONEncoder().encode(current) { try? data.write(to: stateURL, options: .atomic) }
        }
    }

    /// 从头再来（比如恢复了备份）。
    public func reset() {
        indexed = [:]
        index.deleteAllSearchableItems { _ in }
        update()
    }
}
