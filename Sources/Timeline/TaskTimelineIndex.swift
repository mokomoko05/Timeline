import Foundation
import TimelineCore

/// 日期归一化、排序和分组只随任务数据变化；展开和滚动复用这份索引。
struct TaskTimelineIndex {
    let calendar: Calendar
    let ordered: [ScheduledTask]
    let byDay: [Date: [ScheduledTask]]
    let undated: [ScheduledTask]

    init(tasks: [ScheduledTask], calendar: Calendar = JournalDates.calendar) {
        self.calendar = calendar
        TextLayoutProbe.count("taskIndexBuilds")
        var days: [Date: Date] = [:]
        let dated = tasks.map { task -> (ScheduledTask, Date?) in
            guard let date = task.task.timelineDate else { return (task, nil) }
            let day = days[date] ?? calendar.startOfDay(for: date)
            days[date] = day
            return (task, day)
        }.sorted {
            let lhs = $0.1 ?? .distantFuture, rhs = $1.1 ?? .distantFuture
            return lhs != rhs ? lhs < rhs : ScheduledTask.listOrder($0.0, $1.0)
        }
        ordered = dated.map(\.0)
        var grouped: [Date: [ScheduledTask]] = [:]
        var noDate: [ScheduledTask] = []
        for (task, day) in dated {
            if let day { grouped[day, default: []].append(task) }
            else { noDate.append(task) }
        }
        byDay = grouped
        undated = noDate
    }
}

/// 引用缓存本身不发布界面更新，也不会在布局过程中修改 SwiftUI 状态。
final class TaskTimelineIndexCache {
    private var source: [ScheduledTask]?
    private var index: TaskTimelineIndex?
    private var sectionDay: Date?
    private var sectionDates: Set<Date> = []
    private var projected: [TaskTimelineSection] = []

    func index(for tasks: [ScheduledTask]) -> TaskTimelineIndex {
        let calendar = JournalDates.calendar
        if let index, source == tasks, index.calendar == calendar { return index }
        let updated = TaskTimelineIndex(tasks: tasks, calendar: calendar)
        source = tasks
        index = updated
        sectionDay = nil
        return updated
    }

    func sections(for tasks: [ScheduledTask], today: Date, revealedDates: Set<Date>) -> [TaskTimelineSection] {
        let index = index(for: tasks)
        let day = index.calendar.startOfDay(for: today)
        if sectionDay != day || sectionDates != revealedDates {
            TextLayoutProbe.count("taskSectionBuilds")
            projected = TaskTimelineSection.sections(index: index, today: day, revealedDates: revealedDates)
            sectionDay = day
            sectionDates = revealedDates
        }
        return projected
    }
}
