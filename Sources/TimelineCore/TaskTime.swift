import Foundation

public enum TaskTimeMode: String, CaseIterable, Identifiable {
    case allDay, deadline, interval
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .allDay: return "全天"
        case .deadline: return "截止时刻"
        case .interval: return "时间段"
        }
    }
}

public enum TaskTimeEndpoint: String, CaseIterable, Identifiable {
    case start, end
    public var id: String { rawValue }
    public var title: String { self == .start ? "开始时间" : "结束时间" }
}

/// 编辑中的值仅在保存时写回任务，取消不改变原有安排。
public struct TaskTimeDraft: Equatable {
    public var mode: TaskTimeMode
    public var start: Date
    public var end: Date
    public var hasTime: Bool { mode != .allDay }
    public var startDate: Date? { mode == .interval ? start : nil }
    public var isValid: Bool { mode != .interval || start < end }

    public func date(for endpoint: TaskTimeEndpoint) -> Date { endpoint == .start ? start : end }
    public mutating func setDate(_ date: Date, for endpoint: TaskTimeEndpoint) {
        if endpoint == .start { start = date } else { end = date }
    }

    public init(task: Todo, defaultDate: Date = Date()) {
        mode = task.timeRange != nil ? .interval : (task.dueHasTime ? .deadline : .allDay)
        let date = task.dueDate ?? defaultDate
        end = task.dueHasTime ? date : (JournalDates.calendar.date(bySettingHour: 10, minute: 0, second: 0, of: date) ?? date)
        start = task.timeRange?.start ?? end.addingTimeInterval(-3600)
    }
}

extension Todo {
    /// 窄时间轴使用上下两行，不缩小或截断时刻。跨天时明确给出结束日期。
    public var timelineTimeLabel: String? {
        guard let dueDate, dueHasTime else { return nil }
        guard let range = timeRange else { return Self.clockLabel(dueDate) }
        let sameDay = JournalDates.calendar.isDate(range.start, inSameDayAs: range.end)
        let parts = JournalDates.calendar.dateComponents([.month, .day], from: range.end)
        let end = sameDay ? Self.clockLabel(range.end) : "\(parts.month ?? 0)/\(parts.day ?? 0)\n" + Self.clockLabel(range.end)
        return Self.clockLabel(range.start) + "\n" + end
    }

    public var timeRangeLabel: String? {
        guard let range = timeRange else { return nil }
        return Self.clockLabel(range.start) + "–" + (JournalDates.calendar.isDate(range.start, inSameDayAs: range.end) ? Self.clockLabel(range.end) : Self.dayTimeLabel(range.end))
    }

    private static func clockLabel(_ date: Date) -> String {
        let parts = JournalDates.calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    private static func dayTimeLabel(_ date: Date) -> String {
        let parts = JournalDates.calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)/\(parts.month ?? 0)/\(parts.day ?? 0) " + clockLabel(date)
    }
}
