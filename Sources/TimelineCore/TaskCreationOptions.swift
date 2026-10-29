import Foundation

/// 新建任务时的显式选择；未选择日期时沿用正文中的自然语言解析。
public struct TaskCreationOptions: Equatable {
    public var priority: TaskPriority = .normal
    public var overridesDeadline = false
    public var dueDate: Date?
    public var dueHasTime = false
    public var startDate: Date?

    public init() {}

    public func applying(to parsed: Todo) -> Todo {
        var task = parsed
        task.priority = priority
        if overridesDeadline {
            task.dueDate = dueDate.map { dueHasTime ? $0 : JournalDates.calendar.startOfDay(for: $0) }
            task.dueHasTime = dueDate != nil && dueHasTime
            task.startDate = task.dueHasTime && startDate != nil && startDate! < task.dueDate! ? startDate : nil
            if dueDate == nil { task.reminderMinutes = nil }
            if task.repeatRule == .monthly, let dueDate {
                task.repeatMonthDay = JournalDates.calendar.component(.day, from: dueDate)
            }
        }
        return task
    }
}
