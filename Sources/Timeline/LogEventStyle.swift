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

struct LogEventBadge: View {
    @Environment(\.typography) private var typography
    let log: DailyLogEntry

    var body: some View {
        HStack(spacing: 3) {
            if let symbol = LogEventStyle.symbol(log) { Image(systemName: symbol) }
            Text(log.focusMarker).tracking(0.3)
        }
            .font(.system(size: typography.pt(10), weight: .semibold, design: .monospaced))
            .foregroundStyle(LogEventStyle.color(log))
            .frame(width: typography.pt(46), height: typography.pt(18), alignment: .leading)
            .fixedSize()
            .help(LocalizedStringKey(LogEventStyle.status(log)))
            .accessibilityLabel(log.focusMarker == "END" ? AppLocalized(LogEventStyle.status(log)) : log.focusMarker)
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

struct LogTimelineRail: Shape {
    let hasPrevious: Bool
    let hasNext: Bool
    let nodeY: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 8, y: hasPrevious ? rect.minY : nodeY))
        path.addLine(to: CGPoint(x: 8, y: hasNext ? rect.maxY : nodeY))
        return path
    }
}

struct LogTimelineRow<Content: View>: View {
    @Environment(\.typography) private var typography
    let log: DailyLogEntry
    let hasPrevious: Bool
    let hasNext: Bool
    var segment: LogTimelineSegment?
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(LogEventStyle.time(log.createdAt))
                .font(.system(size: typography.pt(11), design: .monospaced))
                .foregroundStyle(Palette.muted).padding(.top, 3).fixedSize()
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 24).padding(.bottom, 14)
                .overlay(alignment: .leading) {
                    LogTimelineRail(hasPrevious: hasPrevious, hasNext: hasNext, nodeY: typography.pt(9))
                        .stroke(Palette.line, lineWidth: 1)
                        .overlay {
                            GeometryReader { geometry in
                                Path { path in
                                    let nodeY = typography.pt(9)
                                    if hasPrevious, segment?.focusBefore == true {
                                        path.move(to: CGPoint(x: 8, y: 0))
                                        path.addLine(to: CGPoint(x: 8, y: nodeY))
                                    }
                                    if hasNext, segment?.focusAfter == true {
                                        path.move(to: CGPoint(x: 8, y: nodeY))
                                        path.addLine(to: CGPoint(x: 8, y: geometry.size.height))
                                    }
                                }.stroke(Palette.accent.opacity(0.8), lineWidth: 1.5)
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            Group {
                                if let symbol = LogEventStyle.symbol(log) {
                                    Image(systemName: symbol)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(LogEventStyle.color(log))
                                        .frame(width: 12, height: 12)
                                        .background(Palette.background)
                                } else {
                                    Circle().fill(LogEventStyle.color(log))
                                        .frame(width: log.isFocusMarker ? 7 : 5, height: log.isFocusMarker ? 7 : 5)
                                }
                            }
                                .position(x: 8, y: typography.pt(9))
                        }
                        .frame(width: 16).allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
    }
}
