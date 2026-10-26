import SwiftUI
import TimelineCore

/// 笔记和日记共用的「线」：左侧一根细线贯穿同一天的记录，每条记录是线上的一颗小珠子。
/// 时间只作为一行很淡的说明放在正文上方，正文才是主角；操作按钮悬停时才出现。
enum NoteThread {
    static let gutter: CGFloat = 18
    static let axisX: CGFloat = 6

    /// 记录类型的中文名，比全大写的标记更安静。
    static func kindLabel(_ log: DailyLogEntry) -> String? {
        switch log.focusMarker {
        case "FOCUS": return AppLocalized("开始专注")
        case "REVIEW": return AppLocalized("阶段反馈")
        case "END": return AppLocalized(LogEventStyle.status(log))
        case "PLAN": return AppLocalized("计划")
        case "DONE": return AppLocalized("完成")
        case "BLOCK": return AppLocalized("受阻")
        default: return nil
        }
    }

    /// 两条记录之间隔得够久时，返回「3 小时后」这样的说明；同一天里才显示。
    static func gapLabel(from previous: Date, to next: Date) -> String? {
        let minutes = Int(next.timeIntervalSince(previous) / 60)
        guard minutes >= 90, JournalDates.calendar.isDate(previous, inSameDayAs: next) else { return nil }
        let hours = Double(minutes) / 60
        return hours < 2 ? AppLocalized("1 小时后") : AppLocalizedFormat("%lld 小时后", Int(hours.rounded()))
    }

    static func shortTime(_ date: Date) -> String {
        let parts = JournalDates.calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

/// 一条记录：线 + 珠子 + 内容。`focusBefore` / `focusAfter` 为 true 时这段线染成专注色，一轮专注读起来是一段连续的彩线。
struct NoteThreadRow<Meta: View, Content: View, Actions: View>: View {
    @Environment(\.typography) private var typography
    let log: DailyLogEntry
    var hasPrevious = true
    var hasNext = true
    var focusBefore = false
    var focusAfter = false
    /// 刚写下或刚跳到的那条：短暂铺一层强调色底。
    var highlighted = false
    @ViewBuilder let meta: () -> Meta
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions
    @State private var hovered = false
    /// 按钮弹出的浮窗还开着：鼠标移进浮窗时按钮不能收起。
    @State private var holding = false

    private var beadY: CGFloat { typography.pt(8) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Color.clear.frame(width: NoteThread.gutter)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: 6) {
                    meta()
                    Spacer(minLength: 8)
                    // 悬停时才构建：每行常驻四五个透明按钮，长笔记页会多占几十 MB。行高按按钮高度预留，出现时不跳动。
                    if hovered || holding { actions().environment(\.holdHoverActions) { holding = $0 } }
                }
                .font(.system(size: typography.pt(11))).monospacedDigit()
                .foregroundStyle(Palette.muted)
                .frame(minHeight: max(typography.pt(16), 22))
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 8).padding(.top, 6)
        .background {
            RoundedRectangle(cornerRadius: Metrics.radiusMedium, style: .continuous)
                .fill(highlighted ? Palette.accent.opacity(0.12) : Palette.soft.opacity(hovered ? 0.35 : 0))
                .padding(.bottom, 8)
        }
        .overlay(alignment: .topLeading) { rail.padding(.leading, 8).padding(.top, 6) }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(Motion.quick, value: hovered)
    }

    private var rail: some View {
        GeometryReader { geometry in
            let x = NoteThread.axisX
            let top = hasPrevious ? -6 : beadY
            let bottom = hasNext ? geometry.size.height + 6 : beadY
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: x, y: top))
                    path.addLine(to: CGPoint(x: x, y: bottom))
                }.stroke(Palette.line.opacity(0.7), lineWidth: 1)
                Path { path in
                    if hasPrevious, focusBefore { path.move(to: CGPoint(x: x, y: top)); path.addLine(to: CGPoint(x: x, y: beadY)) }
                    if hasNext, focusAfter { path.move(to: CGPoint(x: x, y: beadY)); path.addLine(to: CGPoint(x: x, y: bottom)) }
                }.stroke(Palette.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
                bead.position(x: x, y: beadY)
            }
        }
        .frame(width: NoteThread.gutter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var bead: some View {
        let color = LogEventStyle.color(log)
        if let symbol = LogEventStyle.symbol(log) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(color)
                .frame(width: 13, height: 13)
                .background(Palette.background, in: Circle())
                .overlay(Circle().strokeBorder(color.opacity(0.8), lineWidth: 1.1))
        } else if log.isFocusMarker {
            Circle().fill(Palette.background).frame(width: 11, height: 11)
                .overlay(Circle().strokeBorder(color, lineWidth: 1.3))
                .overlay(Circle().fill(color).frame(width: 4, height: 4))
        } else {
            Circle().fill(color.opacity(0.9)).frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(Palette.background, lineWidth: 1.5))
        }
    }
}

/// 一天的开头：线上的一个「结」，后面是相对日期和条数，日期本身很淡。
struct NoteDayKnot: View {
    @Environment(\.typography) private var typography
    let date: Date
    let key: String
    var count: Int?
    let open: () -> Void

    private var today: Bool { JournalDates.calendar.isDateInToday(date) }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ZStack {
                    if today { Circle().fill(Palette.accent.opacity(0.18)).frame(width: 18, height: 18) }
                    Circle().fill(today ? Palette.accent : Palette.background).frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(today ? Palette.background : Palette.muted.opacity(0.8), lineWidth: today ? 1.5 : 1.25))
                }
                .frame(width: NoteThread.gutter)
                Text(date.relativeLabel)
                    .font(.system(size: typography.pt(13), weight: .semibold))
                    .foregroundStyle(today ? Palette.accent : Palette.ink)
                Text(key).font(.system(size: typography.pt(11))).monospacedDigit().foregroundStyle(Palette.muted.opacity(0.8))
                if let count { Text("· \(count) 条").font(.system(size: typography.pt(11))).foregroundStyle(Palette.muted.opacity(0.8)) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 18).padding(.bottom, 2)
        .help("跳到这一天的日志")
    }
}

/// 一天的节奏：0–24 点的细条，每条记录一个刻度，专注时段是一段实心的彩条。点击刻度跳到那条记录。
struct DayRhythmStrip: View {
    let logs: [DailyLogEntry]
    let date: Date
    let select: (UUID) -> Void

    private func fraction(_ time: Date) -> CGFloat {
        let start = JournalDates.calendar.startOfDay(for: date)
        return CGFloat(min(1, max(0, time.timeIntervalSince(start) / 86400)))
    }

    /// 由「开始专注」到「结束」配对出的时段；还没结束的那一段画到当前时间。
    private var focusSpans: [(CGFloat, CGFloat)] {
        var spans: [(CGFloat, CGFloat)] = []
        var start: Date?
        for log in logs {
            if log.focusMarker == "FOCUS" { start = log.createdAt }
            if log.focusMarker == "END", let begin = start { spans.append((fraction(begin), fraction(log.createdAt))); start = nil }
        }
        if let start, JournalDates.calendar.isDateInToday(date) { spans.append((fraction(start), fraction(Date()))) }
        return spans
    }

    var body: some View {
        // 轨道、专注时段和记录点都画得醒目一些：记录点用带底色描边的圆点，挨得近也分得开。
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.line.opacity(0.6)).frame(height: 6)
                ForEach(Array(focusSpans.enumerated()), id: \.offset) { _, span in
                    Capsule().fill(Palette.accent.opacity(0.7))
                        .frame(width: max(6, (span.1 - span.0) * width), height: 6)
                        .offset(x: span.0 * width)
                }
                ForEach(logs) { log in
                    Button { select(log.id) } label: {
                        Circle().fill(LogEventStyle.color(log)).frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(Palette.background, lineWidth: 1.5))
                            .frame(width: 14, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(NoteThread.shortTime(log.createdAt) + " · " + String(TaskText.rendered(LogEventStyle.body(log)).characters.prefix(40)))
                    .offset(x: fraction(log.createdAt) * width - 7)
                }
                if JournalDates.calendar.isDateInToday(date) {
                    Capsule().fill(Palette.accent).frame(width: 3, height: 18)
                        .overlay(Capsule().strokeBorder(Palette.background, lineWidth: 1))
                        .offset(x: fraction(Date()) * width - 1.5)
                        .help("现在")
                }
            }
            .frame(height: 22)
        }
        .frame(height: 22)
        .overlay(alignment: .bottom) {
            HStack {
                ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                    Text("\(hour)").font(.system(size: 10)).monospacedDigit().foregroundStyle(Palette.muted)
                    if hour < 24 { Spacer(minLength: 0) }
                }
            }
            .offset(y: 14)
        }
        .padding(.bottom, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("这一天的记录分布")
    }
}

/// 两条记录之间隔了很久：线变成一段虚线，旁边一行很淡的「几小时后」。
struct NoteThreadGap: View {
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Path { path in
                path.move(to: CGPoint(x: NoteThread.axisX, y: 0))
                path.addLine(to: CGPoint(x: NoteThread.axisX, y: 18))
            }
            .stroke(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            .frame(width: NoteThread.gutter, height: 18)
            Text(label).font(.system(size: 10)).foregroundStyle(Palette.muted.opacity(0.75))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, -4).padding(.bottom, 2)
        .accessibilityHidden(true)
    }
}

/// 还没有记录：一段向下延伸、逐渐淡出的线，线头一颗空心珠子，提示从这里开始。
struct NoteThreadEmpty: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle().strokeBorder(Palette.accent.opacity(0.7), lineWidth: 1.3).frame(width: 11, height: 11)
                LinearGradient(colors: [Palette.accent.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(width: 1.5, height: 46)
            }
            .frame(width: NoteThread.gutter)
            Text(LocalizedStringKey(text)).font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, -2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.top, 18)
    }
}


/// 日记里的一轮专注：从「开始专注」到「结束」之间的记录。
struct FocusRun: Identifiable {
    let start: DailyLogEntry
    let end: DailyLogEntry
    /// 中间的笔记、反馈（不含开始和结束本身）。
    let inner: [DailyLogEntry]
    var id: UUID { start.id }

    var noteCount: Int { inner.filter { !$0.isFocusMarker || $0.focusMarker == "NOTE" }.count }
    var reviewed: Bool { inner.contains { $0.focusMarker == "REVIEW" } }
    var seconds: TimeInterval { end.focusElapsedSeconds ?? end.createdAt.timeIntervalSince(start.createdAt) }

    /// 按时间顺序配对开始和结束；还没结束的一轮不算（仍在进行，不折叠）。
    static func runs(in logs: [DailyLogEntry]) -> [FocusRun] {
        var result: [FocusRun] = []
        var open: (start: DailyLogEntry, inner: [DailyLogEntry])?
        for log in logs {
            switch log.focusMarker {
            case "FOCUS": open = (log, [])
            case "END":
                if let current = open { result.append(FocusRun(start: current.start, end: log, inner: current.inner)) }
                open = nil
            default: open?.inner.append(log)
            }
        }
        return result
    }
}

/// 一轮专注结束后的小结：用时、目标、记了几条、是否写了反馈；可以把这一轮折叠成一行。
struct FocusRunSummary: View {
    @Environment(\.typography) private var typography
    let run: FocusRun
    let folded: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Color.clear.frame(width: NoteThread.gutter)
            HStack(spacing: 10) {
                Image(systemName: run.end.focusMetMinimum == false ? "xmark.circle" : "checkmark.seal")
                    .foregroundStyle(run.end.focusMetMinimum == false ? Palette.danger : Palette.success)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(AppLocalizedFormat("专注 %@", FocusSession.brief(run.seconds))).fontWeight(.semibold)
                        Text(NoteThread.shortTime(run.start.createdAt) + "–" + NoteThread.shortTime(run.end.createdAt))
                            .foregroundStyle(Palette.muted)
                        if run.noteCount > 0 { Text(AppLocalizedFormat("%lld 条笔记", run.noteCount)).foregroundStyle(Palette.muted) }
                        if run.reviewed { Text("已反馈").foregroundStyle(Palette.done) }
                    }
                    if let goal = run.start.focusGoal, !goal.isEmpty {
                        Label(goal, systemImage: "flag").foregroundStyle(Palette.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button(action: toggle) {
                    Label(folded ? "展开这一轮" : "收起这一轮", systemImage: folded ? "chevron.down" : "chevron.up")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: typography.pt(10), weight: .medium))
                        .padding(.horizontal, 7).frame(height: 20)
                }
                .buttonStyle(.plain).foregroundStyle(Palette.accent).raisedOnHover(radius: 10)
            }
            .font(.system(size: typography.pt(11))).monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: Metrics.radiusMedium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radiusMedium, style: .continuous)
                .strokeBorder(Palette.accent.opacity(0.18), lineWidth: Metrics.hairline))
        }
        .padding(.horizontal, 8).padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }
}
