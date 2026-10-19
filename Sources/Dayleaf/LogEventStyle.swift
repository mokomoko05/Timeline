import SwiftUI
import DayleafCore

enum LogEventStyle {
    static func color(_ log: DailyLogEntry) -> Color {
        switch log.focusMarker {
        case "FOCUS", "PLAN": return Palette.accent
        case "REVIEW", "DONE": return Palette.success
        case "END": return Palette.muted
        case "BLOCK": return Palette.deadline
        default: return Palette.muted
        }
    }

    static func time(_ date: Date) -> String {
        let parts = JournalDates.calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    @MainActor static func body(_ log: DailyLogEntry) -> String {
        if log.focusEvent == .start, log.text == "▶ 开始专注", let seconds = log.focusPlannedSeconds {
            return AppLocalizedFormat("计划 %@", FocusSession.brief(seconds))
        }
        if log.focusEvent == .end, log.text.hasPrefix("■ 结束专注 · "), let seconds = log.focusElapsedSeconds {
            let duration = AppLocalizedFormat("有效专注 %@", FocusSession.brief(seconds))
            return log.focusEndReason.map { duration + " · " + AppLocalized($0) } ?? duration
        }
        if log.focusEvent == nil, log.focusMarker == "REVIEW" {
            for prefix in ["阶段反馈 · ", "Session reflection · "] where log.text.hasPrefix(prefix) {
                return String(log.text.dropFirst(prefix.count))
            }
        }
        return log.text
    }
}

struct LogEventBadge: View {
    @Environment(\.typography) private var typography
    let log: DailyLogEntry

    var body: some View {
        Text(log.focusMarker)
            .font(.system(size: typography.pt(10), weight: .semibold, design: .monospaced))
            .tracking(0.3)
            .foregroundStyle(LogEventStyle.color(log))
            .frame(width: typography.pt(46), height: typography.pt(18), alignment: .leading)
            .fixedSize()
            .accessibilityLabel(log.focusMarker)
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

extension View {
    func logEventGutter(_ log: DailyLogEntry) -> some View {
        padding(.leading, 8)
            .overlay(alignment: .leading) {
                if log.isFocusMarker {
                    Rectangle().fill(LogEventStyle.color(log).opacity(0.25)).frame(width: 1)
                        .allowsHitTesting(false)
                }
            }
    }
}
