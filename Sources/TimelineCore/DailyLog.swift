import Foundation

public enum DailyLogKind: String, Codable, CaseIterable, Identifiable {
    case note, done, block, plan
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .note: return "INFO"
        case .done: return "DONE"
        case .block: return "BLOCK"
        case .plan: return "PLAN"
        }
    }
    public var title: String {
        switch self {
        case .note: return "随手记录"
        case .done: return "进展"
        case .block: return "卡点"
        case .plan: return "明日计划"
        }
    }
}

public enum FocusLogEvent: String, Codable, Equatable {
    case start, note, review, end
}

extension DayEntry {
    /// 当天的日志按记录时间从早到晚（补记、导入的日志不一定是按时间追加的）。
    public var logsInTimeOrder: [DailyLogEntry] { logs.sorted { $0.createdAt < $1.createdAt } }
}

public struct DailyLogEntry: Codable, Equatable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var kind: DailyLogKind
    public var text: String
    public var taskID: UUID?
    public var taskTitle: String?
    public var taskNumber: Int?
    /// 记录日志时所关联待办的标签（快照）：待办被删除后，按标签仍然能找到这条日志。
    public var taskTags: [String]
    /// 日志自己的标签（批量或单独加的），不依赖关联的待办；和待办的标签一起参与按标签汇总。
    public var tags: [String]
    /// 图片文件名（位于数据目录的 Images 文件夹）。
    public var images: [String]
    /// 图片名 → 识别出的文字。没有该键表示尚未识别，空字符串表示识别过但没有文字。
    public var imageText: [String: String]
    /// 专注计时产生的开始、结束记录，仅在日志中显示。
    public var focus: Bool
    public var focusEvent: FocusLogEvent?
    public var focusGoal: String?
    public var focusPlannedSeconds: TimeInterval?
    public var focusElapsedSeconds: TimeInterval?
    public var focusEndReason: String?
    /// 结束时的最低专注时长；历史记录未保存此值时按默认 5 分钟判断。
    public var focusMinimumSeconds: TimeInterval?

    public init(id: UUID = UUID(), createdAt: Date, kind: DailyLogKind, text: String, taskID: UUID? = nil, taskTitle: String? = nil, taskNumber: Int? = nil, taskTags: [String] = [], tags: [String] = [],
                images: [String] = [], imageText: [String: String] = [:], focus: Bool = false,
                focusEvent: FocusLogEvent? = nil, focusGoal: String? = nil, focusPlannedSeconds: TimeInterval? = nil,
                focusElapsedSeconds: TimeInterval? = nil, focusEndReason: String? = nil, focusMinimumSeconds: TimeInterval? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.text = text
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.taskNumber = taskNumber
        self.taskTags = taskTags
        self.tags = tags
        self.images = images
        self.imageText = imageText
        self.focus = focus
        self.focusEvent = focusEvent
        self.focusGoal = focusGoal
        self.focusPlannedSeconds = focusPlannedSeconds
        self.focusElapsedSeconds = focusElapsedSeconds
        self.focusEndReason = focusEndReason
        self.focusMinimumSeconds = focusMinimumSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, kind, text, taskID, taskTitle, taskNumber, taskTags, tags, images, imageText, focus, focusEvent, focusGoal, focusPlannedSeconds, focusElapsedSeconds, focusEndReason, focusMinimumSeconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        kind = try values.decode(DailyLogKind.self, forKey: .kind)
        text = try values.decode(String.self, forKey: .text)
        taskID = try values.decodeIfPresent(UUID.self, forKey: .taskID)
        taskTitle = try values.decodeIfPresent(String.self, forKey: .taskTitle)
        taskNumber = try values.decodeIfPresent(Int.self, forKey: .taskNumber)
        taskTags = try values.decodeIfPresent([String].self, forKey: .taskTags) ?? []
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        images = try values.decodeIfPresent([String].self, forKey: .images) ?? []
        imageText = try values.decodeIfPresent([String: String].self, forKey: .imageText) ?? [:]
        focus = try values.decodeIfPresent(Bool.self, forKey: .focus) ?? false
        focusEvent = (try values.decodeIfPresent(String.self, forKey: .focusEvent)).flatMap(FocusLogEvent.init(rawValue:))
        focusGoal = try values.decodeIfPresent(String.self, forKey: .focusGoal)
        focusPlannedSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .focusPlannedSeconds)
        focusElapsedSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .focusElapsedSeconds)
        focusEndReason = try values.decodeIfPresent(String.self, forKey: .focusEndReason)
        focusMinimumSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .focusMinimumSeconds)
    }

    /// 没有图片时不写入新字段，旧数据的 JSON 保持原样。
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(kind, forKey: .kind)
        try values.encode(text, forKey: .text)
        try values.encodeIfPresent(taskID, forKey: .taskID)
        try values.encodeIfPresent(taskTitle, forKey: .taskTitle)
        try values.encodeIfPresent(taskNumber, forKey: .taskNumber)
        if !taskTags.isEmpty { try values.encode(taskTags, forKey: .taskTags) }
        if !tags.isEmpty { try values.encode(tags, forKey: .tags) }
        if !images.isEmpty { try values.encode(images, forKey: .images) }
        if !imageText.isEmpty { try values.encode(imageText, forKey: .imageText) }
        if focus { try values.encode(true, forKey: .focus) }
        try values.encodeIfPresent(focusEvent, forKey: .focusEvent)
        try values.encodeIfPresent(focusGoal, forKey: .focusGoal)
        try values.encodeIfPresent(focusPlannedSeconds, forKey: .focusPlannedSeconds)
        try values.encodeIfPresent(focusElapsedSeconds, forKey: .focusElapsedSeconds)
        try values.encodeIfPresent(focusEndReason, forKey: .focusEndReason)
        try values.encodeIfPresent(focusMinimumSeconds, forKey: .focusMinimumSeconds)
    }

    public var command: String { "/\(kind.rawValue) \(text)" }

    /// 搜索时用到的全部图片文字。
    public var recognizedText: String { images.compactMap { imageText[$0] }.filter { !$0.isEmpty }.joined(separator: "\n") }

    public var focusMarker: String {
        switch focusEvent {
        case .start: return "FOCUS"
        case .note: return kind == .note ? "NOTE" : kind.label
        case .review: return "REVIEW"
        case .end: return "END"
        case nil:
            if focus && text.hasPrefix("▶") { return "FOCUS" }
            if focus && text.hasPrefix("■") { return "END" }
            if kind == .note && (text.hasPrefix("阶段反馈 · ") || text.hasPrefix("Session reflection · ")) { return "REVIEW" }
            return kind.label
        }
    }

    /// nil 表示不是结束记录，或旧记录没有可用的结构化时长。
    public var focusMetMinimum: Bool? {
        guard focusMarker == "END", let elapsed = focusElapsedSeconds else { return nil }
        return elapsed >= max(0, focusMinimumSeconds ?? 300)
    }

    public var isFocusMarker: Bool { focusEvent != nil || ["FOCUS", "REVIEW", "END"].contains(focusMarker) }
    public var isNotebookEntry: Bool { !focus && !["FOCUS", "REVIEW", "END"].contains(focusMarker) }
    public var showsTimelineContext: Bool { !isFocusMarker || focusMarker == "FOCUS" }
    public var showsTimelineTags: Bool { !isFocusMarker }
    public var searchableText: String { [text, focusGoal ?? "", recognizedText].joined(separator: "\n") }
}

public enum LogCommand: Equatable {
    case entry(DailyLogKind, String), help, summary
    /// `/link #1` 关联任务；`/link` 或 `/unlink`（nil）取消关联。
    case link(Int?)
    /// `/filter #1 #3` 只看这些任务相关的日志；`/filter`（空）清除筛选。
    case filter([Int])
    public static let commands = ["/note", "/done", "/block", "/plan", "/link", "/unlink", "/filter", "/summary", "/help"]

    public static func parse(_ input: String) throws -> LogCommand {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw LogInputError.empty }
        let parts = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        let command = String(parts[0]).lowercased()
        let body = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if let kind = DailyLogKind(rawValue: String(command.dropFirst())), command.hasPrefix("/") { return .entry(kind, body) }
        if command == "/help", body.isEmpty { return .help }
        if command == "/summary", body.isEmpty { return .summary }
        if command == "/unlink", body.isEmpty { return .link(nil) }
        if command == "/link" {
            if body.isEmpty { return .link(nil) }
            guard let number = taskNumber(body) else { throw LogInputError.badTaskReference(body) }
            return .link(number)
        }
        if command == "/filter" {
            let tokens = body.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" }).map(String.init)
            let numbers = try tokens.map { token -> Int in
                guard let number = taskNumber(token) else { throw LogInputError.badTaskReference(token) }
                return number
            }
            return .filter(numbers)
        }
        if command.hasPrefix("/"), !command.dropFirst().contains("/") {
            throw LogInputError.unknownCommand(command)
        }
        return .entry(.note, input)
    }

    /// 「#3」或「3」→ 3。
    public static func taskNumber(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard !digits.isEmpty, digits.count <= 4, digits.allSatisfy(\.isASCII), let number = Int(digits), number > 0 else { return nil }
        return number
    }

    /// 日志正文开头的「#1」引用：`/done #1 完成了方法部分`、`#2 卡在配置`。
    public static func splitTaskReference(_ body: String) -> (number: Int?, rest: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return (nil, trimmed) }
        let token = trimmed.prefix { !$0.isWhitespace }
        guard let number = taskNumber(String(token)) else { return (nil, trimmed) }
        return (number, String(trimmed.dropFirst(token.count)).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public enum LogInputError: LocalizedError {
    case empty, unknownCommand(String), missingTask, readOnly, badTaskReference(String), unknownTask(Int)
    public var errorDescription: String? {
        switch self {
        case .empty: return "请输入记录内容，或先关联一条任务。"
        case .unknownCommand(let command): return "未知命令 \(command)，输入 /help 查看用法。"
        case .missingTask: return "关联任务已删除，请重新选择任务或取消关联。"
        case .readOnly: return "当前数据只读，无法保存日志。"
        case .badTaskReference(let text): return "无法识别任务编号「\(text)」，请写成 #1。"
        case .unknownTask(let number): return "没有 #\(number) 号任务。编号显示在任务行左边，创建后不会变。"
        }
    }
}

public enum DailyReview {
    public static func render(_ entry: DayEntry) -> String {
        var sections: [String] = []
        for kind in [DailyLogKind.done, .block, .plan, .note] {
            let logs = entry.logs.filter { $0.kind == kind }
            var lines = logs.map { log -> String in
                let message = log.text.isEmpty && !log.images.isEmpty ? "[图片 \(log.images.count) 张]" : String(TaskText.rendered(log.text).characters)
                guard let task = log.taskTitle, !message.contains(task) else { return "- \(message)" }
                return "- \(message)（\(task)）"
            }
            if kind == .done {
                let logged = Set(logs.compactMap(\.taskID))
                lines += entry.todos.filter { $0.isDone && !logged.contains($0.id) }
                    .map { "- " + String(TaskText.rendered($0.title).characters) }
            }
            if !lines.isEmpty || kind != .note { sections.append("## \(kind.title)\n" + lines.joined(separator: "\n")) }
        }
        return sections.joined(separator: "\n\n")
    }
}
