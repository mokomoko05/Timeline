import Foundation

/// 待办的标签：写成 `#标签`，纯数字的 `#3` 仍然表示任务编号，不算标签。
/// 标签不区分大小写；用 `/` 分层（`项目/子项`），查「项目」会包含它名下的子标签。
public enum TagText {
    public static let maxLength = 40

    /// 把用户输入整理成标签：去掉开头的 `#`、首尾空白和结尾标点，不允许空白、纯数字或空串。
    public static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("#") { text.removeFirst() }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ",，.。;；:：!！?？、"))
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !text.isEmpty, text.count <= maxLength, !text.contains("#"),
              !text.contains(where: \.isWhitespace), !text.allSatisfy(\.isNumber) else { return nil }
        return text
    }

    /// 比较用的键：不区分大小写和音调。
    public static func key(_ tag: String) -> String {
        tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// 用空白或逗号分隔的一串标签（`#a #b`、`a,b`），去重并保持顺序。
    public static func parseList(_ text: String) -> [String] {
        merge([], text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" }).compactMap { normalize(String($0)) })
    }

    /// 在已有标签后追加新标签，已存在（不区分大小写）的不重复。
    public static func merge(_ existing: [String], _ added: [String]) -> [String] {
        var seen = Set(existing.map(key))
        var result = existing
        for tag in added where seen.insert(key(tag)).inserted { result.append(tag) }
        return result
    }

    /// `tag` 就是 `query`，或者是 `query` 名下的子标签（`项目/子项` 属于 `项目`）。
    public static func matches(_ tag: String, query: String) -> Bool {
        let tag = key(tag), query = key(query)
        return tag == query || tag.hasPrefix(query + "/")
    }

    /// 查询词是不是在找标签：以 `#` 开头，后面是合法标签。返回标签名。
    public static func searchTag(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("#") ? normalize(trimmed) : nil
    }

    /// 从一行文字里取出 `#标签`（必须在开头或空白之后），返回去掉标签后的文字。
    /// Markdown 链接和网址里的 `#` 不算；整行只剩标签时原样保留，不生成空标题。
    public static func extract(from text: String) -> (title: String, tags: [String]) {
        var (work, links) = QuickAdd.mask(text)
        let tags = take(from: &work)
        guard !tags.isEmpty else { return (text, []) }
        let title = QuickAdd.unmask(work, links: links)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        links.removeAll()
        return title.isEmpty ? (text, []) : (title, tags)
    }

    /// 已经遮住链接的文字：取出所有标签并从原文里删掉。
    static func take(from work: inout String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\S)#([^\s#]+)"#) else { return [] }
        let source = work as NSString
        var tags: [String] = []
        var output = source
        for match in regex.matches(in: work, range: NSRange(location: 0, length: source.length)).reversed() {
            guard let tag = normalize(source.substring(with: match.range(at: 1))) else { continue }
            tags.insert(tag, at: 0)
            output = output.replacingCharacters(in: match.range, with: " ") as NSString
        }
        work = output as String
        return merge([], tags)
    }
}

extension JournalStore {
    public struct TagSummary: Identifiable, Equatable {
        public var id: String { TagText.key(name) }
        public let name: String
        /// 带这个标签（含子标签）的待办数 / 其中未完成的。
        public let taskCount: Int
        public let openCount: Int
        /// 这些待办名下的笔记条数（含结构化专注流水）。
        public let noteCount: Int
        public let lastActivity: Date
    }

    /// 所有出现过的标签（不区分大小写合并）：待办上的，以及已删除待办的日志里留下的。
    /// `论文/方法` 也会让上级 `论文` 出现，数量按「含子标签」统计，和点进去看到的内容一致。有笔记的、最近有动静的排前面。
    public func allTags() -> [TagSummary] {
        var names: [String: String] = [:]
        var taskCounts: [String: (all: Int, open: Int)] = [:]
        var noteCounts: [String: (count: Int, latest: Date)] = [:]
        let live = liveTags()

        /// 一组标签涉及的所有层级（`a/b` 包含 `a` 和 `a/b`），每层只算一次。
        func levels(_ tags: [String]) -> [String] {
            var seen = Set<String>()
            var result: [String] = []
            for tag in tags {
                let parts = tag.split(separator: "/").map(String.init)
                for count in parts.indices {
                    let name = parts.prefix(count + 1).joined(separator: "/")
                    let key = TagText.key(name)
                    guard seen.insert(key).inserted else { continue }
                    names[key] = names[key] ?? name
                    result.append(key)
                }
            }
            return result
        }

        _ = levels(tagRegistry)
        for item in tasks() {
            for key in levels(item.task.tags) {
                let previous = taskCounts[key] ?? (0, 0)
                taskCounts[key] = (previous.all + 1, previous.open + (item.task.completed ? 0 : 1))
            }
        }
        for day in days.values {
            for log in day.logs where log.isNotebookEntry {
                for key in levels(effectiveTags(of: log, live: live)) {
                    let previous = noteCounts[key]
                    noteCounts[key] = ((previous?.count ?? 0) + 1, max(previous?.latest ?? .distantPast, log.createdAt))
                }
            }
        }
        return names.map { key, name in
            TagSummary(name: name, taskCount: taskCounts[key]?.all ?? 0, openCount: taskCounts[key]?.open ?? 0,
                       noteCount: noteCounts[key]?.count ?? 0, lastActivity: noteCounts[key]?.latest ?? .distantPast)
        }.sorted {
            if $0.lastActivity != $1.lastActivity { return $0.lastActivity > $1.lastActivity }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func liveTags() -> [UUID: [String]] {
        Dictionary(tasks().map { ($0.id, $0.task.tags) }, uniquingKeysWith: { first, _ in first })
    }

    /// 日志的标签 = 关联待办的标签（待办还在用现在的，已删除用记录时的快照）+ 日志自己的标签。
    private func effectiveTags(of log: DailyLogEntry, live: [UUID: [String]]) -> [String] {
        let inherited: [String]
        if let id = log.taskID, let tags = live[id] { inherited = tags } else { inherited = log.taskTags }
        return log.tags.isEmpty ? inherited : TagText.merge(inherited, log.tags)
    }

    /// 带这个标签（或它的子标签）的待办，按清单顺序。
    public func tasks(taggedWith tag: String) -> [ScheduledTask] {
        tasks().filter { $0.task.tags.contains { TagText.matches($0, query: tag) } }.sorted(by: ScheduledTask.listOrder)
    }

    /// 一条日志现在带的标签：关联的待办还在就用它当前的标签（之后改标签会跟着变），已删除就用记录时的快照，再加上日志自己的标签。
    public func tags(of log: DailyLogEntry) -> [String] {
        effectiveTags(of: log, live: liveTags())
    }

    /// 这个标签（含子标签）名下的笔记和结构化专注流水，按时间从早到晚。已删除待办的笔记靠记录时的标签快照仍然找得到。
    public func notes(forTag tag: String) -> [LoggedLog] {
        let live = liveTags()
        return allLogs(includeFocus: true).filter { item in item.log.isNotebookEntry && effectiveTags(of: item.log, live: live).contains { TagText.matches($0, query: tag) } }
    }

    /// 同上，但包含专注计时的开始、结束记录。
    public func logs(forTag tag: String) -> [LoggedLog] {
        let live = liveTags()
        return allLogs(includeFocus: true).filter { item in effectiveTags(of: item.log, live: live).contains { TagText.matches($0, query: tag) } }
    }

    /// 整个替换一个待办的标签，作为一次可撤销的操作。
    public func setTags(_ id: UUID, _ tags: [String]) {
        guard !isReadOnly, let located = locate(id) else { return }
        let normalized = TagText.merge([], tags.compactMap(TagText.normalize))
        guard located.task.tags != normalized else { return }
        change(located.date, action: "标签") { entry in
            guard let index = entry.todos.firstIndex(where: { $0.id == id }) else { return }
            entry.todos[index].tags = normalized
        }
    }
}

// MARK: - 标签注册表

extension JournalStore {
    /// 创建一个标签（可以是还没有任何内容的空标签）。已经存在（不区分大小写）就返回已有的写法。名字不合法返回 nil。
    @discardableResult
    public func createTag(_ raw: String) -> String? {
        guard !isReadOnly, let name = TagText.normalize(raw) else { return nil }
        if let existing = allTags().first(where: { $0.id == TagText.key(name) }) { return existing.name }
        tagRegistry.append(name)
        registryChanged()
        return name
    }

    /// 只有注册表里的、没有任何待办和日志在用的标签才能删除；用着的标签要先去掉它的使用处。
    @discardableResult
    public func removeEmptyTag(_ name: String) -> Bool {
        guard !isReadOnly, let summary = allTags().first(where: { $0.id == TagText.key(name) }),
              summary.taskCount == 0, summary.noteCount == 0 else { return false }
        let key = TagText.key(name)
        // 空的上级标签（`论文`）可能只是被子标签带出来的：有子标签在用时不删。
        guard !allTags().contains(where: { $0.id != key && $0.id.hasPrefix(key + "/") && ($0.taskCount > 0 || $0.noteCount > 0) }) else { return false }
        let before = tagRegistry.count
        tagRegistry.removeAll { TagText.key($0) == key || TagText.key($0).hasPrefix(key + "/") }
        guard tagRegistry.count != before else { return false }
        registryChanged()
        return true
    }
}

// MARK: - 复制日志文字

extension DailyLogEntry {
    /// 复制到剪贴板的内容：只有文字（保留原文，包括 Markdown 链接写法），图片不算。没有文字时为 nil。
    public var copyText: String? {
        let content = focusEvent == .start && focusGoal?.isEmpty == false ? text + "\n" + (focusGoal ?? "") : text
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension JournalStore {
    /// 把选中的日志按时间从早到晚拼成一段文字，每条一行（多行日志保持原样）；都没有文字时为 nil。
    public func copyText(forLogs ids: Set<UUID>) -> String? {
        let parts = allLogs(includeFocus: true).filter { ids.contains($0.log.id) }.compactMap(\.log.copyText)
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// 「关联待办」的候选（`@` 补全和选择器共用）。`query` 可以是标题里的字、编号（`3` / `#3`）、`#标签`、拼音（`lunwen`）或拼音首字母（`lw`），
    /// 也容忍中间漏字（`读文` 能找到「读论文」）。排序是「猜你要写哪个」：编号精确命中最前；然后专注中的、固定关联的、
    /// 带 `contextTags`（比如正在写的标签）的、最近记过的；其余按清单顺序。字面匹配好的排在只能模糊匹配的前面。
    public func linkCandidates(query: String = "", includeCompleted: Bool = false, recentLimit: Int = 8, contextTags: [String] = []) -> [ScheduledTask] {
        let pool = sortedTasks().filter { includeCompleted || !$0.task.completed }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        let number = Int(digits)
        // 每个任务的匹配质量；nil 表示不匹配。
        var quality: [UUID: Int] = [:]
        for item in pool {
            if trimmed.isEmpty { quality[item.id] = 1; continue }
            if let value = LinkMatcher.quality(of: item, query: trimmed, number: number) { quality[item.id] = value }
        }
        let matched = pool.filter { quality[$0.id] != nil }
        var latest: [UUID: Date] = [:]
        for day in days.values { for log in day.logs where !log.focus { if let id = log.taskID { latest[id] = max(latest[id] ?? .distantPast, log.createdAt) } } }
        let recent = Set(latest.sorted { $0.value > $1.value }.prefix(recentLimit).map(\.key))
        let order = Dictionary(uniqueKeysWithValues: pool.enumerated().map { ($1.id, $0) })
        let pinned = pinnedTask?.id
        func bucket(_ item: ScheduledTask) -> Int {
            if item.id == focusTaskID { return 0 }
            if item.id == pinned { return 1 }
            if !contextTags.isEmpty, item.task.tags.contains(where: { tag in contextTags.contains { TagText.matches(tag, query: $0) } }) { return 2 }
            return recent.contains(item.id) ? 3 : 4
        }
        // 已完成 / 已放弃的排在所有未完成的后面（编号精确命中除外：你明确点了号，就该排第一）。
        func rank(_ item: ScheduledTask) -> (Int, Int, Int, Int) {
            let value = quality[item.id] ?? 9
            if value == 0 { return (0, 0, 0, 0) }
            return (item.task.completed ? 1 : 0, value >= LinkMatcher.fuzzy ? 2 : 1, bucket(item), value)
        }
        return matched.sorted {
            let (a, b) = (rank($0), rank($1))
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1 != b.1 { return a.1 < b.1 }
            if a.2 != b.2 { return a.2 < b.2 }
            if a.2 == 3, latest[$0.id] != latest[$1.id] { return (latest[$0.id] ?? .distantPast) > (latest[$1.id] ?? .distantPast) }
            if a.3 != b.3 { return a.3 < b.3 }
            return (order[$0.id] ?? 0) < (order[$1.id] ?? 0)
        }
    }
}

/// 待办标题与查询词的匹配：字面、拼音、拼音首字母、漏字模糊。
@MainActor
enum LinkMatcher {
    /// 质量：0 编号精确；1 标题开头或某个词开头；2 标题 / 标签包含；3 拼音或首字母；4 漏字模糊（最差）。
    static let fuzzy = 4

    private struct Pinyin { let full: String; let initials: String }
    private static var cache: [String: Pinyin] = [:]

    private static func pinyin(_ title: String) -> Pinyin {
        if let hit = cache[title] { return hit }
        let latin = (title.applyingTransform(.mandarinToLatin, reverse: false) ?? title).applyingTransform(.stripDiacritics, reverse: false) ?? title
        let words = latin.lowercased().split(whereSeparator: { $0.isWhitespace })
        let entry = Pinyin(full: words.joined(), initials: String(words.compactMap(\.first)))
        if cache.count > 4000 { cache.removeAll() }
        cache[title] = entry
        return entry
    }

    static func quality(of item: ScheduledTask, query: String, number: Int?) -> Int? {
        let task = item.task
        if let number, task.number == number { return 0 }
        if let tag = TagText.searchTag(query) {
            return task.tags.contains { TagText.matches($0, query: tag) } ? 2 : nil
        }
        let title = String(TaskText.rendered(task.title, alias: task.calendarName).characters)
        return textQuality(title, rawTitle: task.title, tags: task.tags, query: query)
    }

    /// 文字与查询词的匹配质量（1 开头 / 词开头；2 包含；3 拼音或首字母；4 漏字模糊），不匹配为 nil。
    static func textQuality(_ title: String, rawTitle: String? = nil, tags: [String] = [], query: String) -> Int? {
        let needle = query.lowercased()
        let lower = title.lowercased()
        if lower.hasPrefix(needle) { return 1 }
        if lower.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).contains(where: { $0.hasPrefix(needle) }) { return 1 }
        if title.localizedStandardContains(query) || (rawTitle?.localizedStandardContains(query) ?? false)
            || tags.contains(where: { $0.localizedStandardContains(query) }) { return 2 }
        let compact = needle.filter { !$0.isWhitespace }
        if !compact.isEmpty, compact.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            let py = pinyin(title)
            if py.full.contains(compact) || py.initials.contains(compact) { return 3 }
        }
        if compact.count >= 2, isSubsequence(compact, of: lower) { return fuzzy }
        return nil
    }

    private static func isSubsequence(_ needle: String, of text: String) -> Bool {
        var iterator = text.makeIterator()
        for character in needle {
            var found = false
            while let next = iterator.next() { if next == character { found = true; break } }
            if !found { return false }
        }
        return true
    }
}

// MARK: - 清单摘要

public struct TaskSummary: Equatable {
    /// 已逾期（未完成、截止时间已过）。
    public let overdue: Int
    /// 今天截止、还没完成的（不含已逾期的）。
    public let dueToday: Int
    /// 所有没完成的（含逾期、含没有截止日期的）。
    public let open: Int
    /// 今天截止的待办里：做完了几个 / 一共几个。放弃的不算在内，已逾期的也不算（它们的截止日是以前）。
    public let doneToday: Int
    public let totalToday: Int
    public var todayFraction: Double { totalToday == 0 ? 0 : Double(doneToday) / Double(totalToday) }
}

extension JournalStore {
    /// 清单顶部的摘要：「3 逾期 · 5 今天 · 12 未完成」和今天的进度。
    public func taskSummary(now: Date = Date()) -> TaskSummary {
        let calendar = JournalDates.calendar
        var overdue = 0, dueToday = 0, open = 0, doneToday = 0, totalToday = 0
        for item in tasks() {
            let task = item.task
            let isToday = task.dueDate.map { calendar.isDate($0, inSameDayAs: now) } == true
            if isToday, !task.isDropped {
                totalToday += 1
                if task.isDone { doneToday += 1 }
            }
            guard !task.completed else { continue }
            open += 1
            if task.effectiveDeadline.map({ $0 < now }) == true { overdue += 1 } else if isToday { dueToday += 1 }
        }
        return TaskSummary(overdue: overdue, dueToday: dueToday, open: open, doneToday: doneToday, totalToday: totalToday)
    }
}

// MARK: - 标签候选（输入框里的 # 补全）

public struct TagCandidate: Identifiable, Equatable {
    public let name: String
    /// 还不存在，选中就是新建。
    public let isNew: Bool
    public let taskCount: Int
    public let noteCount: Int
    public var id: String { (isNew ? "new:" : "tag:") + TagText.key(name) }
}

extension JournalStore {
    /// `#` 补全的候选：已有标签按匹配质量（开头 > 包含 > 拼音 > 漏字）和最近使用排序；`query` 是合法的新标签名时，最后加一项「新建」。
    /// `excluding` 是已经选了的标签。查询词是纯数字（任务编号）时没有候选。
    public func tagCandidates(query: String, excluding: [String] = [], limit: Int = 6) -> [TagCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) { return [] }
        let chosen = Set(excluding.map(TagText.key))
        let all = allTags().filter { !chosen.contains($0.id) }
        var matched: [(TagSummary, Int, Int)] = []
        for (index, summary) in all.enumerated() {
            if trimmed.isEmpty { matched.append((summary, 1, index)); continue }
            if let quality = LinkMatcher.textQuality(summary.name, query: trimmed) { matched.append((summary, quality, index)) }
        }
        matched.sort { ($0.1, $0.2) < ($1.1, $1.2) }
        var result = matched.prefix(limit).map { TagCandidate(name: $0.0.name, isNew: false, taskCount: $0.0.taskCount, noteCount: $0.0.noteCount) }
        if let name = TagText.normalize(trimmed), !trimmed.hasSuffix("/"),
           !allTags().contains(where: { $0.id == TagText.key(name) }), !chosen.contains(TagText.key(name)) {
            if result.count >= limit { result.removeLast() }
            result.append(TagCandidate(name: name, isNew: true, taskCount: 0, noteCount: 0))
        }
        return result
    }
}

// MARK: - 笔记本（标签）与章节（待办）

public struct NotebookChapter: Identifiable {
    /// nil 表示「直接记录」：没有关联待办、直接记在标签下的内容。
    public let taskID: UUID?
    public let number: Int?
    public let title: String
    public let completed: Bool
    public var dropped = false
    public let notes: [JournalStore.LoggedLog]
    public var id: String { taskID?.uuidString ?? "direct" }
}

extension JournalStore {
    /// 把一个标签（笔记本）的内容按待办（章节）分组：先是「直接记录」，然后是带这个标签的待办（即使还没有笔记），
    /// 最后是日志自己带这个标签、但关联的待办没有这个标签的那些待办。章节里的笔记按时间从早到晚。
    public func chapters(forTag tag: String) -> [NotebookChapter] {
        let notes = notes(forTag: tag)
        let grouped = Dictionary(grouping: notes) { $0.log.taskID }
        var result: [NotebookChapter] = []
        if let direct = grouped[nil], !direct.isEmpty {
            result.append(NotebookChapter(taskID: nil, number: nil, title: "直接记录", completed: false, notes: direct))
        }
        var used = Set<UUID>()
        for item in tasks(taggedWith: tag) {
            used.insert(item.id)
            result.append(NotebookChapter(taskID: item.id, number: item.task.number,
                                          title: String(TaskText.rendered(item.task.title).characters),
                                          completed: item.task.completed, dropped: item.task.isDropped, notes: grouped[item.id] ?? []))
        }
        let others = grouped.compactMap { key, value -> (UUID, [LoggedLog])? in key.map { ($0, value) } }
            .filter { !used.contains($0.0) }
            .sorted { ($0.1.first?.log.createdAt ?? .distantPast) < ($1.1.first?.log.createdAt ?? .distantPast) }
        for (id, items) in others {
            let live = locate(id)
            result.append(NotebookChapter(taskID: id, number: live?.task.number ?? items.first?.log.taskNumber,
                                          title: live.map { String(TaskText.rendered($0.task.title).characters) } ?? items.first?.log.taskTitle ?? "（任务已删除）",
                                          completed: live?.task.completed ?? false, dropped: live?.task.isDropped ?? false, notes: items))
        }
        return result
    }
}
