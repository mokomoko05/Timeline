import Foundation
import DayleafCore

/// 命令行里一条日志的展示用快照（和界面里看到的一致：任务编号、标题取最新的）。
public struct LogRow: Identifiable, Equatable {
    public let id: UUID
    public let dateKey: String
    public let date: Date
    public let createdAt: Date
    public let kind: DailyLogKind
    public let text: String
    public let taskNumber: Int?
    public let taskTitle: String?
    public let images: [String]
    public let imageText: [String: String]
    public let focus: Bool
    public var focusEvent: FocusLogEvent? = nil
    public var focusGoal: String? = nil

    /// 8 位短标识：命令行里引用一条日志（`sched show a1b2c3d4`），允许只写唯一的前缀。
    public var shortID: String { String(id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)) }
    public var marker: String {
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

    public var timeLabel: String {
        let parts = JournalDates.calendar.dateComponents([.hour, .minute], from: createdAt)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// 单行摘要：换行换成空格，用于列表和 fzf。
    public var singleLine: String {
        text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
    }

    /// 搜索用的全部文字：正文、任务标题、截图里识别出的文字。
    var searchable: String {
        ([text, taskTitle ?? "", focusGoal ?? ""] + imageText.values).joined(separator: "\n")
    }
}

public struct LogFilter: Equatable {
    public var tasks: Set<Int> = []
    /// 只要带这个标签（含子标签）的待办名下的日志。
    public var tag: String?
    public var since: Date?
    public var until: Date?
    public var kinds: Set<DailyLogKind> = []
    public var grep: String?
    public var includeFocus = false
    public var notebookOnly = false
    public var onlyWithImages = false
    /// 只要最后 N 条（时间最近的）。
    public var last: Int?
    public var reverse = false

    public init() {}

    public var isEmpty: Bool {
        tasks.isEmpty && tag == nil && since == nil && until == nil && kinds.isEmpty && (grep ?? "").isEmpty && !onlyWithImages
    }
}

public enum LogQuery {
    @MainActor
    public static func rows(in store: JournalStore, filter: LogFilter) -> [LogRow] {
        let tagged = filter.tag.map { tag in Set(store.logs(forTag: tag).map(\.id)) }
        var rows: [LogRow] = store.allLogs(includeFocus: filter.includeFocus).compactMap { item in
            let log = item.log
            if filter.notebookOnly && !log.isNotebookEntry { return nil }
            if let tagged, !tagged.contains(log.id) { return nil }
            let live = log.taskID.flatMap { store.locate($0) }
            let number = live?.task.number ?? log.taskNumber
            if !filter.tasks.isEmpty, number.map(filter.tasks.contains) != true { return nil }
            if let since = filter.since, item.date < JournalDates.calendar.startOfDay(for: since) { return nil }
            if let until = filter.until, item.date > JournalDates.calendar.startOfDay(for: until) { return nil }
            if !filter.kinds.isEmpty, !filter.kinds.contains(log.kind) { return nil }
            if filter.onlyWithImages, log.images.isEmpty { return nil }
            let title = live.map { String(TaskText.rendered($0.task.title).characters) } ?? log.taskTitle
            let row = LogRow(id: log.id, dateKey: item.key, date: item.date, createdAt: log.createdAt, kind: log.kind, text: log.text,
                             taskNumber: number, taskTitle: title, images: log.images, imageText: log.imageText, focus: log.focus,
                             focusEvent: log.focusEvent, focusGoal: log.focusGoal)
            if let needle = filter.grep, !needle.isEmpty, !row.searchable.localizedCaseInsensitiveContains(needle) { return nil }
            return row
        }
        if let last = filter.last, last >= 0, rows.count > last { rows = Array(rows.suffix(last)) }
        return filter.reverse ? rows.reversed() : rows
    }

    public enum Lookup: Equatable {
        case found(UUID)
        case notFound
        case ambiguous([String])
    }

    /// 按完整 UUID 或唯一的短标识前缀（至少 3 位）找日志。
    @MainActor
    public static func lookup(_ reference: String, in store: JournalStore) -> Lookup {
        let needle = reference.lowercased().replacingOccurrences(of: "-", with: "")
        guard needle.count >= 3 else { return .notFound }
        let matches = store.allLogs(includeFocus: true).filter {
            $0.log.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().hasPrefix(needle)
        }
        switch matches.count {
        case 0: return .notFound
        case 1: return .found(matches[0].log.id)
        default: return .ambiguous(matches.map { String($0.log.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)) })
        }
    }
}

/// 命令行里的日期参数：`2026-10-07`、`10-07`、`today`/`今天`、`yesterday`/`昨天`、`7d`（7 天前）。
public enum DateArgument {
    public static func parse(_ text: String, now: Date = Date()) -> Date? {
        let calendar = JournalDates.calendar
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        let today = calendar.startOfDay(for: now)
        switch value {
        case "today", "今天": return today
        case "yesterday", "昨天": return calendar.date(byAdding: .day, value: -1, to: today)
        case "tomorrow", "明天": return calendar.date(byAdding: .day, value: 1, to: today)
        default: break
        }
        if value.hasSuffix("d"), let days = Int(value.dropLast()), days >= 0 { return calendar.date(byAdding: .day, value: -days, to: today) }
        if let full = JournalDates.date(for: value) { return full }
        let parts = value.split(separator: "-")
        if parts.count == 2, let month = Int(parts[0]), let day = Int(parts[1]) {
            let year = calendar.component(.year, from: now)
            if let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
               calendar.component(.month, from: date) == month { return date }
        }
        return nil
    }
}
