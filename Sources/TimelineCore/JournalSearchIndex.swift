import Foundation

/// 不可变值快照；只跨 actor 传递值类型，不跨线程共享 JournalStore。
public struct JournalSearchSnapshot: @unchecked Sendable {
    let days: [String: DayEntry]
    let boards: [Board]
    public init(days: [String: DayEntry], boards: [Board]) { self.days = days; self.boards = boards }
}

public struct JournalSearchMatches: @unchecked Sendable {
    public var tasks: [ScheduledTask] = []
    public var locatedLogs: [JournalStore.LoggedLog] = []
    public var logs: Set<UUID> = []
    public var images: Set<UUID> = []
    public var boardLines: [UUID: [Int]] = [:]
    public var boardText: [UUID: [Int: String]] = [:]
    public var summaries: Set<String> = []
}

/// 索引按日期/实体增量更新；全文匹配在后台 actor，前台仅组装最多 300 条结果。
public actor JournalSearchIndex {
    private struct Text {
        let value: DailyLogEntry
        let searchable: String
    }
    private var days: [String: DayEntry] = [:]
    private var logs: [String: [Text]] = [:]
    private var boards: [UUID: (source: String, lines: [String])] = [:]
    public init() {}

    public func search(_ snapshot: JournalSearchSnapshot, query: String, limit: Int = 300) throws -> JournalSearchMatches {
        try Task.checkCancellation()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return JournalSearchMatches() }
        for key in Set(days.keys).union(snapshot.days.keys) where days[key] != snapshot.days[key] {
            guard let day = snapshot.days[key] else { days.removeValue(forKey: key); logs.removeValue(forKey: key); continue }
            let previous = Dictionary((logs[key] ?? []).map { ($0.value.id, $0) }, uniquingKeysWith: { a, _ in a })
            try Task.checkCancellation()
            logs[key] = day.logs.sorted { $0.createdAt > $1.createdAt }.map { log in
                if let old = previous[log.id], old.value == log { return old }
                return Text(value: log, searchable: ([log.text, log.focusGoal ?? "", log.taskTitle ?? ""] + log.tags + log.taskTags).joined(separator: "\n"))
            }
            days[key] = day
        }
        let ids = Set(snapshot.boards.map(\.id))
        boards = boards.filter { ids.contains($0.key) }
        for board in snapshot.boards where !board.archived && board.mergedInto == nil {
            try Task.checkCancellation()
            if boards[board.id]?.source != board.markdown { boards[board.id] = (board.markdown, board.markdown.components(separatedBy: .newlines)) }
        }
        let liveTasks = Dictionary(snapshot.days.values.flatMap { $0.todos }.map { ($0.id, $0.tags) }, uniquingKeysWith: { a, _ in a })
        let tag = TagText.searchTag(query)
        let terms = LinkMatcher.terms(query)
        var result = JournalSearchMatches()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return result }
        var tasks = snapshot.days.flatMap { key, day -> [ScheduledTask] in
            guard let date = JournalDates.date(for: key) else { return [] }
            return day.todos.map { ScheduledTask(date: date, task: $0) }
        }
        tasks.sort { $0.date == $1.date ? $0.task.title < $1.task.title : $0.date < $1.date }
        if let tag { tasks = tasks.filter { $0.task.tags.contains { TagText.matches($0, query: tag) } } }
        // 拼音、Markdown 标题处理及质量排序均留在后台。
        result.tasks = Array(LinkMatcher.searchTasks(tasks, terms: tag == nil ? terms : []).prefix(80))
        for board in snapshot.boards where !board.archived && board.mergedInto == nil && tag == nil {
            try Task.checkCancellation()
            if case .task(let id) = board.owner, liveTasks[id] == nil { continue }
            var matches: [Int: String] = [:]
            for (index, line) in (boards[board.id]?.lines ?? []).enumerated() {
                try Task.checkCancellation()
                if LinkMatcher.containsAll(line, terms) { matches[index] = line }
                if matches.count == 4 { break }
            }
            if !matches.isEmpty { result.boardLines[board.id] = matches.keys.sorted(); result.boardText[board.id] = matches }
        }
        var count = 0
        for key in logs.keys.sorted(by: >) {
            try Task.checkCancellation()
            guard let date = JournalDates.date(for: key) else { continue }
            for text in logs[key] ?? [] {
                try Task.checkCancellation()
                let previousCount = count
                if let tag {
                    let inherited = text.value.taskID.flatMap { liveTasks[$0] } ?? text.value.taskTags
                    if (text.value.tags + inherited).contains(where: { TagText.matches($0, query: tag) }) { result.logs.insert(text.value.id); count += 1 }
                } else if LinkMatcher.containsAll(text.searchable, terms) { result.logs.insert(text.value.id); count += 1 }
                else if !text.value.images.isEmpty, LinkMatcher.containsAll(text.value.recognizedText, terms) { result.images.insert(text.value.id); count += 1 }
                if count > previousCount { result.locatedLogs.append(JournalStore.LoggedLog(key: key, date: date, log: text.value)) }
                if count >= limit { break }
            }
            if count >= limit { break }
        }
        if tag == nil {
            for (key, day) in days where !day.summary.isEmpty && LinkMatcher.containsAll(day.summary, terms) { result.summaries.insert(key) }
        }
        return result
    }
}
