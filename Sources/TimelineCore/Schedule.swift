import Foundation

public enum TaskPriority: String, Codable, CaseIterable, Identifiable {
    case urgent, high, normal, lower, low
    public var id: String { rawValue }
    public var rank: Int { Self.allCases.firstIndex(of: self)! }
    public var title: String { switch self { case .urgent: return "最高优先级"; case .high: return "高优先级"; case .normal: return "普通优先级"; case .lower: return "较低优先级"; case .low: return "低优先级" } }
}

public enum TaskSortMode: String, CaseIterable, Identifiable {
    case deadline, priority, manual
    public var id: String { rawValue }
    public var title: String { switch self { case .deadline: return "截止时间排序"; case .priority: return "优先级排序"; case .manual: return "手动排序" } }

    /// 用于日期分组内部；月历始终使用 deadline，手动位置只在 manual 下生效。
    public func precedes(_ lhs: ScheduledTask, _ rhs: ScheduledTask) -> Bool {
        if self == .manual { return ScheduledTask.listOrder(lhs, rhs) }
        if self == .priority, lhs.task.priority != rhs.task.priority {
            return lhs.task.priority.rank < rhs.task.priority.rank
        }
        let calendar = JournalDates.calendar
        let dayA = lhs.task.dueDate.map { calendar.startOfDay(for: $0) } ?? .distantFuture
        let dayB = rhs.task.dueDate.map { calendar.startOfDay(for: $0) } ?? .distantFuture
        if dayA != dayB { return dayA < dayB }
        if lhs.task.dueHasTime != rhs.task.dueHasTime { return lhs.task.dueHasTime }
        let a = lhs.task.effectiveDeadline ?? .distantFuture
        let b = rhs.task.effectiveDeadline ?? .distantFuture
        if a != b { return a < b }
        if lhs.task.priority != rhs.task.priority { return lhs.task.priority.rank < rhs.task.priority.rank }
        let x = lhs.task.number ?? .max, y = rhs.task.number ?? .max
        return x != y ? x < y : lhs.id.uuidString < rhs.id.uuidString
    }

    public static func group(for task: Todo, now: Date) -> Int {
        if task.isDropped { return 7 }
        guard let due = task.dueDate else { return 5 }
        if task.effectiveDeadline.map({ $0 < now }) == true { return 0 }
        let calendar = JournalDates.calendar
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        return days <= 0 ? 1 : (days == 1 ? 2 : (days <= 7 ? 3 : 4))
    }

    public func sorted(_ tasks: [ScheduledTask], now: Date = Date()) -> [ScheduledTask] {
        tasks.sorted {
            let a = Self.group(for: $0.task, now: now), b = Self.group(for: $1.task, now: now)
            return a != b ? a < b : precedes($0, $1)
        }
    }
}

public enum RepeatRule: String, Codable, CaseIterable, Identifiable {
    case none, daily, weekdays, weekly, monthly
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return "不重复"
        case .daily: return "每天"
        case .weekdays: return "工作日"
        case .weekly: return "每周"
        case .monthly: return "每月"
        }
    }

    public func nextDate(after date: Date, monthDay: Int? = nil) -> Date? {
        let calendar = JournalDates.calendar
        switch self {
        case .none: return nil
        case .daily: return calendar.date(byAdding: .day, value: 1, to: date)
        case .weekly: return calendar.date(byAdding: .day, value: 7, to: date)
        case .weekdays:
            var next = calendar.date(byAdding: .day, value: 1, to: date)!
            while calendar.isDateInWeekend(next) { next = calendar.date(byAdding: .day, value: 1, to: next)! }
            return next
        case .monthly:
            let month = calendar.date(byAdding: .month, value: 1, to: JournalDates.monthStart(date))!
            let day = min(monthDay ?? calendar.component(.day, from: date), calendar.range(of: .day, in: .month, for: month)!.count)
            return calendar.date(byAdding: .day, value: day - 1, to: month)
        }
    }
}

public struct ScheduledTask: Identifiable {
    public let date: Date
    public let task: Todo
    public var id: UUID { task.id }

    public init(date: Date, task: Todo) {
        self.date = date
        self.task = task
    }

    /// 手动排序：手动位置优先，否则按截止时间，再按编号和 ID 决胜。
    public static func listOrder(_ lhs: ScheduledTask, _ rhs: ScheduledTask) -> Bool {
        let (a, b) = (lhs.task.sortKey, rhs.task.sortKey)
        if a != b { return a < b }
        let (x, y) = (lhs.task.number ?? .max, rhs.task.number ?? .max)
        return x != y ? x < y : lhs.task.id.uuidString < rhs.task.id.uuidString
    }
}

public enum AgendaFilter: String, CaseIterable, Identifiable {
    case unfinished, upcoming, overdue, all
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .unfinished: return "未完成"
        case .upcoming: return "即将截止"
        case .overdue: return "已逾期"
        case .all: return "全部"
        }
    }

    public func includes(_ task: Todo, now: Date) -> Bool {
        switch self {
        case .all: return true
        case .unfinished: return !task.completed
        case .overdue: return !task.completed && task.effectiveDeadline.map { $0 < now } == true
        case .upcoming:
            guard !task.completed, let deadline = task.effectiveDeadline else { return false }
            let end = JournalDates.calendar.date(byAdding: .day, value: 7, to: now)!
            return deadline >= now && deadline <= end
        }
    }
}

public struct ReminderPlan: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let fireDate: Date
    public let dayKey: String
    public let taskID: UUID

    public static func pending(days: [String: DayEntry], now: Date = Date()) -> [ReminderPlan] {
        days.flatMap { key, entry in
            entry.todos.compactMap { task -> ReminderPlan? in
                guard !task.completed, let due = task.dueDate, let minutes = task.reminderMinutes else { return nil }
                let base = task.dueHasTime ? due : JournalDates.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: due)!
                let fire = base.addingTimeInterval(-Double(minutes) * 60)
                guard fire > now else { return nil }
                return ReminderPlan(id: "timeline.\(task.id.uuidString)", title: String(TaskText.rendered(task.title).characters), fireDate: fire, dayKey: JournalDates.key(due), taskID: task.id)
            }
        }.sorted { $0.fireDate == $1.fireDate ? $0.id < $1.id : $0.fireDate < $1.fireDate }
    }
}

public struct BackupRecord: Identifiable {
    public let url: URL
    public let date: Date
    public var id: String { url.path }
}

public struct BackupPreview {
    public let dayCount: Int
    public let taskCount: Int
    public let summaryCount: Int
    public let logCount: Int
}
