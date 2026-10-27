import SwiftUI
import TimelineCore
import UIKit

/// 和 Mac 版「默认 · 墨蓝」同一套配色，随系统深浅色切换。
/// 系统设置里打开「减弱动态效果」时：不做位移、缩放和弹簧动画，换成直接变化或淡入淡出。
enum Motion {
    static var reduced: Bool { UIAccessibility.isReduceMotionEnabled }

    /// 动画本身：减弱动态效果时不播（直接变到结果）。
    static func adapt(_ animation: Animation?) -> Animation? { reduced ? nil : animation }

    /// 只是淡入淡出、闪一下的变化：减弱动态效果时换成很短的淡变，不至于生硬地跳出来。
    static func fading(_ animation: Animation) -> Animation { reduced ? .easeOut(duration: 0.15) : animation }

    /// 出现 / 消失的过渡：减弱动态效果时只淡入淡出。
    static func transition(_ transition: AnyTransition) -> AnyTransition { reduced ? .opacity : transition }
}

enum Palette {
    static let background = color(light: 0xF6F8FA, dark: 0x0D1117)
    static let card = color(light: 0xFFFFFF, dark: 0x161B22)
    static let ink = color(light: 0x1F2328, dark: 0xF0F6FC)
    static let muted = color(light: 0x59636E, dark: 0x9198A1)
    static let accent = color(light: 0x0969DA, dark: 0x4493F8)
    static let soft = color(light: 0xDDF4FF, dark: 0x121D2F)
    static let line = color(light: 0xD1D9E0, dark: 0x3D444D)
    static let success = color(light: 0x1A7F37, dark: 0x3FB950)
    static let deadline = color(light: 0xBC4C00, dark: 0xD29922)
    static let danger = color(light: 0xCF222E, dark: 0xF85149)
    static let attention = color(light: 0x9A6700, dark: 0xDB6D28)
    static let done = color(light: 0x8250DF, dark: 0xAB7DF8)
    static let note = color(light: 0x1B7C83, dark: 0x39C5CF)

    /// Markdown 标题按级别着色，和 Mac 一致。
    static func heading(_ level: Int) -> Color {
        let light: [UInt32] = [0xA84D33, 0x846000, 0x327455, 0x296D91, 0x7658A4, 0x984D77]
        let dark: [UInt32] = [0xDD9179, 0xD4AE62, 0x79B898, 0x73AFCF, 0xA596D1, 0xC68FAE]
        let index = max(0, min(level - 1, 5))
        return color(light: light[index], dark: dark[index])
    }

    static func color(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? uiColor(dark) : uiColor(light) })
    }

    private static func uiColor(_ value: UInt32) -> UIColor {
        UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

extension TaskPriority {
    var color: Color {
        switch self {
        case .urgent: return Palette.danger
        case .high: return Palette.attention
        case .normal: return Palette.accent
        case .lower: return Palette.note
        case .low: return Palette.muted
        }
    }
}

/// 日志类型的颜色和名称（和 Mac 的日志时间线一致）。
enum LogStyle {
    static func color(_ log: DailyLogEntry) -> Color {
        switch log.focusMarker {
        case "FOCUS", "PLAN": return Palette.accent
        case "NOTE": return Palette.note
        case "REVIEW": return Palette.done
        case "END": return log.focusMetMinimum == false ? Palette.danger : Palette.success
        case "DONE": return Palette.success
        case "BLOCK": return Palette.deadline
        default: return Palette.muted
        }
    }

    /// 类型名：普通记录不显示。
    static func label(_ log: DailyLogEntry) -> String? {
        switch log.focusMarker {
        case "FOCUS": return L("开始专注")
        case "NOTE": return L("专注笔记")
        case "REVIEW": return L("阶段反馈")
        case "END": return L(log.focusMetMinimum == false ? "未达到最低专注时长" : "结束专注")
        case "DONE": return L("完成")
        case "BLOCK": return L("卡点")
        case "PLAN": return L("计划")
        default: return nil
        }
    }

    /// 正文：去掉旧格式里重复的类型前缀，结束记录显示用时。
    static func body(_ log: DailyLogEntry) -> String {
        if log.focusMarker == "FOCUS" {
            if log.text == "▶ 开始专注" { return log.focusPlannedSeconds.map { LF("计划 %@", Duration.brief($0)) } ?? "" }
            if log.text.hasPrefix("▶ 开始专注 · ") { return String(log.text.dropFirst("▶ 开始专注 · ".count)) }
        }
        if log.focusMarker == "END", log.text.hasPrefix("■ 结束专注") {
            let parts = log.text.components(separatedBy: " · ")
            let duration = log.focusElapsedSeconds.map(Duration.full) ?? parts.first { $0.hasPrefix("用时 ") }.map { String($0.dropFirst(3)) }
            let reason = (log.focusEndReason ?? (parts.count > 3 ? parts.last : nil)).map(L)
            let summary = duration.map { LF("有效专注 %@", $0) } ?? L("结束专注")
            return reason.map { summary + " · " + $0 } ?? summary
        }
        if log.focusEvent == nil, log.focusMarker == "REVIEW" {
            for prefix in ["阶段反馈 · ", "Session reflection · "] where log.text.hasPrefix(prefix) { return String(log.text.dropFirst(prefix.count)) }
        }
        return log.text
    }
}

enum Duration {
    static func brief(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : LF("%lld 分钟", minutes)
    }

    static func full(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 { return LF("%lld 小时 %lld 分", total / 3600, total % 3600 / 60) }
        return total % 60 == 0 ? LF("%lld 分钟", total / 60) : LF("%lld 分 %lld 秒", total / 60, total % 60)
    }
}

enum DayText {
    /// 「今天」「明天」「昨天」，其余为 nil。
    static func relative(_ date: Date) -> String? {
        let calendar = JournalDates.calendar
        if calendar.isDateInToday(date) { return L("今天") }
        if calendar.isDateInTomorrow(date) { return L("明天") }
        if calendar.isDateInYesterday(date) { return L("昨天") }
        return nil
    }

    static func short(_ date: Date) -> String {
        date.formatted(.dateTime.month(.defaultDigits).day())
    }

    static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide))
    }

    /// 时刻一律 24 小时制（13:05），不跟系统的 12 小时制设置走。
    static func time(_ date: Date) -> String { clock.string(from: date) }

    static func timeWithSeconds(_ date: Date) -> String { clockWithSeconds.string(from: date) }

    private static let clock = fixedFormatter("HH:mm")
    private static let clockWithSeconds = fixedFormatter("HH:mm:ss")

    private static func fixedFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}

/// 一行时间轴：左边是时间（或日期），中间一根竖线和节点，右边是内容。
/// 竖线贯穿整行，首尾两行在节点处断开，所以一组节点连成一条线。
struct RailRow<Node: View, Content: View>: View {
    var label: String = ""
    var labelColor: Color = Palette.muted
    var hasPrevious = true
    var hasNext = true
    var lineColor: Color = Palette.line
    var nodeY: CGFloat = 10
    /// 竖线上用强调色的一段（专注中）：从 `top` 到 `bottom`（nil 是到行底）。画在节点下面，不穿过节点。
    var accent: (top: CGFloat, bottom: CGFloat?)?
    /// false：竖线由外面一次画在整列后面（待办页），行里只在首尾两行用底色把线头盖掉。
    /// 这样行可以上下挪（拖动排序时）而线不跟着走。
    var drawsLine = true
    /// 行内容（时间、节点、卡片）相对原位的位移；竖线留在原地。
    var shift: CGFloat = 0
    var shiftAnimation: Animation?
    @ViewBuilder var node: () -> Node
    @ViewBuilder var content: () -> Content

    static var labelWidth: CGFloat { 46 }
    static var railWidth: CGFloat { 20 }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(labelColor)
                .lineLimit(1)
                // 只有可能放不下的（日期）才允许缩小：带缩放的文字要多量几遍，时刻「05:21」总放得下。
                .minimumScaleFactor(label.count > 5 ? 0.7 : 1)
                .frame(width: Self.labelWidth, alignment: .trailing)
                .padding(.top, nodeY - 8)
            // 节点放在固定大小的占位上：没有节点（`EmptyView`）的行也留出这一格，右边的内容和别的行对齐。
            Color.clear.frame(width: Self.railWidth, height: 20)
                .overlay { node() }
                .offset(y: nodeY - 10)
                .padding(.horizontal, 6)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .offset(y: shift)
        .animation(Motion.adapt(shiftAnimation), value: shift)
        // 竖线画在整行的背景里，跟着行高走，不用每行一个 GeometryReader。
        .background(alignment: .topLeading) {
            if drawsLine {
                Self.segment(from: hasPrevious ? 0 : nodeY, to: hasNext ? nil : nodeY)
                    .fill(lineColor)
            } else {
                if !hasPrevious { RailSegment(x: Self.labelWidth + 6 + 10, top: 0, bottom: nodeY, width: 4).fill(Palette.background) }
                if !hasNext { RailSegment(x: Self.labelWidth + 6 + 10, top: nodeY, bottom: nil, width: 4).fill(Palette.background) }
            }
            if let accent {
                RailSegment(x: Self.labelWidth + 6 + 10, top: accent.top, bottom: accent.bottom, width: 2)
                    .fill(Palette.accent.opacity(0.8))
            }
        }
    }

    /// 竖线上从 `top` 到 `bottom`（nil 是到行底）的一段，x 在节点中心。
    static func segment(from top: CGFloat, to bottom: CGFloat?) -> some Shape {
        RailSegment(x: labelWidth + 6 + 10, top: top, bottom: bottom)
    }
}

/// 竖线的一段：1.5 宽的矩形，按所在的整行高度裁出。
struct RailSegment: Shape {
    var x: CGFloat
    var top: CGFloat
    var bottom: CGFloat?
    var width: CGFloat = 1.5

    func path(in rect: CGRect) -> Path {
        let end = min(bottom ?? rect.height, rect.height)
        guard end > top else { return Path() }
        return Path(CGRect(x: x - width / 2, y: top, width: width, height: end - top))
    }
}

/// 小圆点节点。盖在竖线上面；底色只垫在圆环里面，不比节点大，线一直接到节点边上，看不出断开。
struct Dot: View {
    var color: Color
    var size: CGFloat = 9
    var ring = false

    var body: some View {
        ZStack {
            if ring {
                Circle().fill(Palette.background).frame(width: size + 7, height: size + 7)
                Circle().stroke(color, lineWidth: 1.5).frame(width: size + 7, height: size + 7)
            }
            Circle().fill(color).frame(width: size, height: size)
        }
    }
}

/// 标签、计数一类的小胶囊。
struct Chip: View {
    let text: String
    var color: Color = Palette.accent
    var filled = true

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(filled ? color.opacity(0.12) : .clear, in: Capsule())
            .overlay { if !filled { Capsule().stroke(color.opacity(0.4), lineWidth: 1) } }
    }
}

/// 卡片底。
struct CardBackground: ViewModifier {
    var highlighted = false
    func body(content: Content) -> some View {
        content
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(highlighted ? Palette.accent.opacity(0.5) : Palette.line.opacity(0.6), lineWidth: 1))
    }
}

extension View {
    func card(highlighted: Bool = false) -> some View { modifier(CardBackground(highlighted: highlighted)) }
}

extension String {
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
