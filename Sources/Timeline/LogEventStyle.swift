import SwiftUI
import TimelineCore

enum LogEventStyle {
    static func color(_ log: DailyLogEntry) -> Color {
        switch log.focusMarker {
        case "FOCUS": return Palette.accent
        case "NOTE": return Palette.note
        case "REVIEW": return Palette.done
        case "END": return log.focusMetMinimum == false ? Palette.danger : Palette.success
        case "PLAN": return Palette.accent
        case "DONE": return Palette.success
        case "BLOCK": return Palette.deadline
        default: return Palette.muted
        }
    }

    /// 专注的开始、结束这类自动写的记录用小一号的淡色；专注期间自己记的笔记、反馈和普通日志一样。
    static func quiet(_ log: DailyLogEntry) -> Bool { log.isFocusMarker && !log.hasEditableText }

    static func symbol(_ log: DailyLogEntry) -> String? {
        guard log.focusMarker == "END" else { return nil }
        return log.focusMetMinimum == false ? "xmark" : "checkmark"
    }

    static func status(_ log: DailyLogEntry) -> String {
        guard log.focusMarker == "END" else { return log.focusMarker }
        return log.focusMetMinimum == false ? "未达到最低专注时长" : "结束专注"
    }

    static func time(_ date: Date) -> String {
        let parts = JournalDates.calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    @MainActor static func body(_ log: DailyLogEntry) -> String {
        if log.focusMarker == "FOCUS", log.text == "▶ 开始专注" {
            return log.focusPlannedSeconds.map { AppLocalizedFormat("计划 %@", FocusSession.brief($0)) } ?? ""
        }
        // 旧记录「▶ 开始专注 · 计划 25 min」：类型已经写在说明行里，正文只留计划。
        if log.focusMarker == "FOCUS", log.text.hasPrefix("▶ 开始专注 · ") {
            return String(log.text.dropFirst("▶ 开始专注 · ".count))
        }
        if log.focusMarker == "END", log.text.hasPrefix("■ 结束专注") {
            let parts = log.text.components(separatedBy: " · ")
            let duration = log.focusElapsedSeconds.map(FocusSession.duration)
                ?? parts.first(where: { $0.hasPrefix("用时 ") }).map { String($0.dropFirst(3)) }
            let reason = log.focusEndReason ?? (parts.count > 3 ? parts.last : nil)
            let summary = duration.map {
                let duration = AppLocalizedFormat("有效专注 %@", $0)
                return log.focusMetMinimum == false ? duration + " · " + AppLocalized(status(log)) : duration
            } ?? AppLocalized("结束专注")
            return reason.map { summary + " · " + AppLocalized($0) } ?? summary
        }
        if log.focusEvent == nil, log.focusMarker == "REVIEW" {
            for prefix in ["阶段反馈 · ", "Session reflection · "] where log.text.hasPrefix(prefix) {
                return String(log.text.dropFirst(prefix.count))
            }
        }
        return log.text
    }

    static func detail(_ log: DailyLogEntry) -> String? {
        guard log.focusMarker == "END", log.text.hasPrefix("■ 结束专注 · ") else { return nil }
        return log.text.components(separatedBy: " · ").first(where: { $0.hasPrefix("累计 ") })
            .map { AppLocalizedFormat("累计 %@", String($0.dropFirst(3))) }
    }
}

struct LogFocusGoal: View {
    let log: DailyLogEntry

    var body: some View {
        if log.focusEvent == .start, let goal = log.focusGoal, !goal.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "flag").font(.system(size: 10)).foregroundStyle(Palette.accent).padding(.top, 3)
                TaskLinkText(source: goal, completed: false, color: Palette.ink, fontSize: 13,
                             edit: {}, open: SafariLinks.open, maxLines: 0, markdown: true, compactLines: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

@MainActor
enum LogTaskLabel {
    static func current(_ task: ScheduledTask, store: JournalStore, logDate: Date) -> String {
        let number = task.task.number.map { "#\($0)" } ?? "任务"
        let title = String(TaskText.rendered(task.task.title, alias: task.task.calendarName).characters)
        return "\(number) \(title)"
    }

    static func saved(_ log: DailyLogEntry, store: JournalStore, logDate: Date) -> String? {
        if let id = log.taskID, let task = store.locate(id) { return current(task, store: store, logDate: logDate) }
        guard let title = log.taskTitle else { return nil }
        let number = log.taskNumber.map { "#\($0) " } ?? ""
        return number + AppLocalizedFormat("%@（已删除）", title)
    }
}
