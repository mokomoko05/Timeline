import Foundation

/// 普通与推迟通知共用任务生命周期；不触碰专注计时等其他通知。
public enum ReminderLifecycle {
    public static func isManaged(_ identifier: String) -> Bool {
        identifier.hasPrefix("timeline.") || identifier.hasPrefix("timeline-snooze.")
    }

    public static func shouldRemove(_ identifier: String, taskID: UUID?, desired: Set<String>, activeTasks: Set<UUID>, enabled: Bool) -> Bool {
        guard isManaged(identifier) else { return false }
        guard enabled else { return true }
        if identifier.hasPrefix("timeline-snooze.") {
            return taskID.map { !activeTasks.contains($0) } ?? true
        }
        return !desired.contains(identifier)
    }
}

public struct ReminderLifecycleSnapshot: Equatable {
    public let plans: [ReminderPlan]
    public let activeTasks: Set<UUID>
    public init(days: [String: DayEntry], now: Date = Date()) {
        plans = ReminderPlan.pending(days: days, now: now)
        activeTasks = Set(days.values.flatMap { $0.todos.filter { !$0.completed }.map(\.id) })
    }
}
