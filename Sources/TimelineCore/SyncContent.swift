import Foundation

/// 参与同步的全部内容。输入草稿（`logDraft`、`deadlineDraft` 等）各台设备自己留着，不同步。
struct SyncContent: Equatable {
    var days: [String: DayEntry]
    var boards: [Board]
    var tags: [String]
    var pinnedTask: UUID?
    var nextTaskNumber: Int

    /// 每天里放在 `days[日期]` 下的字段，存成记录里的一个普通字段。
    static let dayField = "_day"

    /// 拆成一条条同步记录：键是「类型/编号」，值是模型自己编码出来的字段。
    func records() throws -> [String: [String: SyncValue]] {
        var records: [String: [String: SyncValue]] = [:]
        for (day, entry) in days {
            for todo in entry.todos {
                var fields = try SyncValue.encoding(todo).fields
                fields[Self.dayField] = .string(day)
                records["todo/" + todo.id.uuidString] = fields
            }
            for log in entry.logs {
                var fields = try SyncValue.encoding(log).fields
                fields[Self.dayField] = .string(day)
                records["log/" + log.id.uuidString] = fields
            }
            if !entry.summary.isEmpty { records["summary/" + day] = ["text": .string(entry.summary)] }
        }
        for board in boards { records["board/" + board.id.uuidString] = try SyncValue.encoding(board).fields }
        for tag in tags { records["tag/" + TagText.key(tag)] = ["name": .string(tag)] }
        if let pinnedTask { records["meta/pinned"] = ["task": .string(pinnedTask.uuidString)] }
        return records
    }

    /// 由合并后的记录还原内容。已有的待办、日志、工作板和标签保持本机原来的顺序，新来的排在后面；
    /// 草稿取自本机。解不开的记录（比如更新版本的应用写的新格式）跳过，本机原有的那份保留。
    func applying(_ state: [String: SyncRecord]) -> SyncContent {
        var todos: [String: [Todo]] = [:], logs: [String: [DailyLogEntry]] = [:], summaries: [String: String] = [:]
        var boardsByID: [UUID: Board] = [:], tagNames: [String: String] = [:]
        var pinned: UUID?
        var numberStamps: [UUID: SyncStamp] = [:]
        let localTodos = Dictionary(days.flatMap { day, entry in entry.todos.map { ($0.id, (day, $0)) } }, uniquingKeysWith: { first, _ in first })
        let localLogs = Dictionary(days.flatMap { day, entry in entry.logs.map { ($0.id, (day, $0)) } }, uniquingKeysWith: { first, _ in first })
        for (key, record) in state where record.isAlive {
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            var values = record.values
            let day = values.removeValue(forKey: Self.dayField)?.string
            switch parts[0] {
            case "todo":
                if let day, JournalDates.date(for: day) != nil, let todo = try? SyncValue.object(values).decoded(Todo.self) {
                    todos[day, default: []].append(todo)
                    numberStamps[todo.id] = record.fields["number"]?.stamp
                } else if let id = UUID(uuidString: parts[1]), let (day, todo) = localTodos[id] {
                    todos[day, default: []].append(todo)
                }
            case "log":
                if let day, JournalDates.date(for: day) != nil, let log = try? SyncValue.object(values).decoded(DailyLogEntry.self) {
                    logs[day, default: []].append(log)
                } else if let id = UUID(uuidString: parts[1]), let (day, log) = localLogs[id] {
                    logs[day, default: []].append(log)
                }
            case "summary":
                if JournalDates.date(for: parts[1]) != nil, let text = values["text"]?.string, !text.isEmpty { summaries[parts[1]] = text }
            case "board":
                if let board = try? SyncValue.object(values).decoded(Board.self) { boardsByID[board.id] = board }
                else if let id = UUID(uuidString: parts[1]), let board = boards.first(where: { $0.id == id }) { boardsByID[id] = board }
            case "tag":
                if let name = values["name"]?.string.flatMap(TagText.normalize) { tagNames[TagText.key(name)] = name }
            case "meta":
                if parts[1] == "pinned" { pinned = values["task"]?.string.flatMap(UUID.init(uuidString:)) }
            default: break
            }
        }

        var result = self
        var updatedDays: [String: DayEntry] = [:]
        for day in Set(days.keys).union(todos.keys).union(logs.keys).union(summaries.keys) {
            var entry = days[day] ?? DayEntry()
            entry.todos = Self.ordered(todos[day] ?? [], like: entry.todos.map(\.id), id: \.id) { ($0.number ?? .max, $0.id.uuidString) < ($1.number ?? .max, $1.id.uuidString) }
            entry.logs = Self.ordered(logs[day] ?? [], like: entry.logs.map(\.id), id: \.id) { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            entry.summary = summaries[day] ?? ""
            if entry.hasContent { updatedDays[day] = entry }
        }
        result.days = updatedDays
        result.boards = Self.ordered(Array(boardsByID.values), like: boards.map(\.id), id: \.id) { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        let localTagOrder = tags.map(TagText.key)
        result.tags = localTagOrder.compactMap { tagNames[$0] } + tagNames.filter { !localTagOrder.contains($0.key) }.sorted { $0.key < $1.key }.map(\.value)
        result.pinnedTask = pinned
        result.renumberDuplicates(stamps: numberStamps)
        return result
    }

    /// 已有的按本机原来的顺序，新来的按 `newOrder` 排在后面。
    private static func ordered<Item>(_ items: [Item], like existing: [UUID], id: KeyPath<Item, UUID>, newOrder: (Item, Item) -> Bool) -> [Item] {
        let position = Dictionary(existing.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let known = items.filter { position[$0[keyPath: id]] != nil }.sorted { position[$0[keyPath: id]]! < position[$1[keyPath: id]]! }
        return known + items.filter { position[$0[keyPath: id]] == nil }.sorted(by: newOrder)
    }

    /// 两台设备离线时各建了任务，可能拿到同一个编号：最先拿到这个编号的保留，其余的改用新编号，
    /// 记在它名下的日志一起改。
    private mutating func renumberDuplicates(stamps: [UUID: SyncStamp]) {
        let all = days.values.flatMap(\.todos)
        let highest = all.compactMap(\.number).max() ?? 0
        nextTaskNumber = max(nextTaskNumber, highest + 1)
        var holders: [Int: [Todo]] = [:]
        for todo in all { if let number = todo.number { holders[number, default: []].append(todo) } }
        var renumbered: [UUID: Int] = [:]
        for number in holders.keys.sorted() {
            guard let group = holders[number], group.count > 1 else { continue }
            let order = group.sorted { (stamps[$0.id] ?? SyncStamp(time: .infinity, device: ""), $0.id.uuidString) < (stamps[$1.id] ?? SyncStamp(time: .infinity, device: ""), $1.id.uuidString) }
            for todo in order.dropFirst() {
                renumbered[todo.id] = nextTaskNumber
                nextTaskNumber += 1
            }
        }
        guard !renumbered.isEmpty else { return }
        for day in Array(days.keys) {
            guard var entry = days[day] else { continue }
            for index in entry.todos.indices {
                if let number = renumbered[entry.todos[index].id] { entry.todos[index].number = number }
            }
            for index in entry.logs.indices {
                if let id = entry.logs[index].taskID, let number = renumbered[id] { entry.logs[index].taskNumber = number }
            }
            days[day] = entry
        }
    }

    /// 内容里引用到的图片文件名。
    var imageNames: Set<String> {
        Set(days.values.flatMap { $0.logs.flatMap(\.images) + $0.logDraftImages })
    }
}
