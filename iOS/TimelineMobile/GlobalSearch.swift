import CoreSpotlight
import SwiftUI
import TimelineCore

/// 从别处跳进应用里的某一项：通知、Spotlight、搜索结果。目标页面还没建好（那个标签页没打开过）时先存着，页面出现时再取。
@MainActor
final class Navigator: ObservableObject {
    enum Target: Equatable {
        case task(UUID)
        case log(UUID)
        case board(UUID)
        /// 日记的某一天（每日小结）。
        case day(String)
    }

    static let shared = Navigator()
    @Published var target: Target?

    func open(_ target: Target) { self.target = target }

    /// 页面取走属于自己的目标。
    func take<Value>(_ extract: (Target) -> Value?) -> Value? {
        guard let target, let value = extract(target) else { return nil }
        self.target = nil
        return value
    }

    /// Spotlight 结果点进来。
    @discardableResult
    func open(_ activity: NSUserActivity) -> Bool {
        guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let (kind, id) = SpotlightItem.parse(identifier) else { return false }
        switch kind {
        case .task: open(.task(id))
        case .log: open(.log(id))
        case .board: open(.board(id))
        }
        return true
    }
}

/// 全局搜索：待办、工作板正文、日志与笔记、每日小结一起搜。
struct GlobalSearchView: View {
    @ObservedObject var store: JournalStore
    @State private var query = ""
    @State private var results = SearchResults()
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !results.tasks.isEmpty {
                    Section(LF("待办 · %lld", results.tasks.count)) {
                        ForEach(results.tasks) { item in
                            NavigationLink(value: SearchDestination.task(item.id)) { TaskResultRow(item: item) }
                        }
                    }
                }
                if !results.boards.isEmpty {
                    Section(LF("工作板 · %lld", results.boards.count)) {
                        ForEach(results.boards) { hit in
                            NavigationLink(value: SearchDestination.board(hit.boardID)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(hit.line).foregroundStyle(Palette.ink).lineLimit(2)
                                    Text(hit.title).font(.caption).foregroundStyle(Palette.muted)
                                }
                            }
                        }
                    }
                }
                if !results.logs.isEmpty {
                    Section(LF("日志与笔记 · %lld", results.logs.count)) {
                        ForEach(results.logs) { hit in
                            Button { open(hit) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(hit.line).foregroundStyle(Palette.ink).lineLimit(3)
                                    Text(hit.detail).font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !results.summaries.isEmpty {
                    Section(LF("每日小结 · %lld", results.summaries.count)) {
                        ForEach(results.summaries) { hit in
                            Button { open(hit) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(hit.line).foregroundStyle(Palette.ink).lineLimit(2)
                                    Text(hit.detail).font(.caption).foregroundStyle(Palette.muted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .overlay {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView("搜索全部内容", systemImage: "magnifyingglass",
                                           description: Text("待办、工作板正文、日志与笔记、每日小结。输入 #标签 只看这个标签。"))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索待办、工作板、日志")
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SearchDestination.self) { destination in
                switch destination {
                case .task(let id): TaskPage(store: store, id: id)
                case .taskNote(let id, let reveal): TaskPage(store: store, id: id, reveal: reveal)
                case .board(let id): BoardPage(store: store, id: id)
                }
            }
            .notesDestinations(store)
            .task(id: query) {
                // 停顿一下再搜，打字时不每个字都扫一遍全部数据。
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                results = SearchResults(store: store, query: query)
            }
        }
    }

    /// 有关联待办的日志在那个待办的笔记里打开（滚到这一条）；没有的跳到日记那一天。
    private func open(_ hit: SearchResults.LogHit) {
        if let taskID = hit.taskID, store.locate(taskID) != nil, let logID = hit.logID {
            path.append(SearchDestination.taskNote(taskID, reveal: logID))
        } else if let logID = hit.logID {
            Navigator.shared.open(.log(logID))
        } else if let key = hit.dayKey {
            Navigator.shared.open(.day(key))
        }
    }
}

enum SearchDestination: Hashable {
    case task(UUID)
    case taskNote(UUID, reveal: UUID)
    case board(UUID)
}

private struct TaskResultRow: View {
    let item: ScheduledTask

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.task.isDone ? "checkmark.circle.fill" : item.task.isDropped ? "xmark.circle" : "circle")
                .foregroundStyle(item.task.completed ? Palette.muted : Palette.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(TaskText.rendered(item.task.title)).foregroundStyle(item.task.completed ? Palette.muted : Palette.ink)
                    .strikethrough(item.task.isDone).lineLimit(2)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(Palette.muted).lineLimit(1) }
            }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let number = item.task.number { parts.append("#\(number)") }
        if let due = item.task.dueDate { parts.append(LF("截止 %@", DayText.relative(due) ?? DayText.short(due))) }
        if !item.task.tags.isEmpty { parts.append(item.task.tags.map { "#" + $0 }.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }
}

/// 一次搜索的全部结果。和 Mac 的全局搜索同一套规则：每页工作板最多列 4 行；`#标签` 只看带这个标签的。
struct SearchResults {
    struct BoardHit: Identifiable {
        let id: String
        let boardID: UUID
        let title: String
        let line: String
    }

    struct LogHit: Identifiable {
        let id: String
        let logID: UUID?
        let taskID: UUID?
        let dayKey: String?
        let line: String
        let detail: String
    }

    static let boardLinesPerBoard = 4
    static let logLimit = 200

    var tasks: [ScheduledTask] = []
    var boards: [BoardHit] = []
    var logs: [LogHit] = []
    var summaries: [LogHit] = []

    var isEmpty: Bool { tasks.isEmpty && boards.isEmpty && logs.isEmpty && summaries.isEmpty }

    init() {}

    @MainActor
    init(store: JournalStore, query raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        tasks = Array(store.tasks(matching: query).sorted { lhs, rhs in
            lhs.task.completed != rhs.task.completed ? !lhs.task.completed : (lhs.task.dueDate ?? .distantFuture) < (rhs.task.dueDate ?? .distantFuture)
        }.prefix(80))
        let all = store.allLogs(includeFocus: true).reversed()
        if let tag = TagText.searchTag(query) {
            logs = store.logs(forTag: tag).reversed().prefix(Self.logLimit).map { Self.hit($0, query: nil) }
            return
        }
        for board in store.boards where !store.isBoardArchived(board) {
            var found = 0
            for (index, line) in board.markdown.components(separatedBy: .newlines).enumerated() where line.localizedStandardContains(query) {
                boards.append(BoardHit(id: "\(board.id)-\(index)", boardID: board.id, title: store.boardTitle(board), line: Self.readable(line)))
                found += 1
                if found == Self.boardLinesPerBoard { break }
            }
        }
        for item in all {
            let log = item.log
            guard log.searchableText.localizedStandardContains(query) || (log.taskTitle ?? "").localizedStandardContains(query)
                    || log.tags.contains(where: { $0.localizedStandardContains(query) }) else { continue }
            logs.append(Self.hit(item, query: query))
            if logs.count == Self.logLimit { break }
        }
        for key in store.days.keys.sorted(by: >) {
            guard let summary = store.days[key]?.summary, summary.localizedStandardContains(query) else { continue }
            let line = summary.components(separatedBy: .newlines).first { $0.localizedStandardContains(query) } ?? summary
            let day = JournalDates.date(for: key).map { DayText.relative($0) ?? DayText.short($0) } ?? key
            summaries.append(LogHit(id: "summary-" + key, logID: nil, taskID: nil, dayKey: key, line: Self.readable(line), detail: day))
        }
    }

    private static func hit(_ item: JournalStore.LoggedLog, query: String?) -> LogHit {
        let log = item.log
        let lines = log.searchableText.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let line = query.flatMap { query in lines.first { $0.localizedStandardContains(query) } } ?? lines.first ?? L("图片")
        var detail = (JournalDates.date(for: item.key).map { DayText.relative($0) ?? DayText.short($0) } ?? item.key)
            + " " + DayText.time(log.createdAt)
        if let title = log.taskTitle { detail += " · " + title }
        return LogHit(id: log.id.uuidString, logID: log.id, taskID: log.taskID, dayKey: item.key,
                      line: String(TaskText.rendered(readable(line)).characters), detail: detail)
    }

    /// 去掉缩进和行首的 Markdown 记号，读起来像正文。
    static func readable(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        for pattern in [#"^#{1,6}\s+"#, #"^>\s*"#, #"^[-+*]\s+\[[ xX]\]\s+"#, #"^[-+*]\s+"#, #"^\d+[.)]\s+"#] {
            if let range = text.range(of: pattern, options: .regularExpression) { text.removeSubrange(range); break }
        }
        return text.replacingOccurrences(of: #"</?(summary|details)[^>]*>"#, with: "", options: .regularExpression)
    }
}
