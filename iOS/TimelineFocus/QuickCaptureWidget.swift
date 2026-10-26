import AppIntents
import SwiftUI
import UIKit
import WidgetKit

/// 快速记录：主屏和锁屏上一点就进到「写日志」或「新待办」。不读数据，只显示今天的日期。
/// 样子和 App 一致：同一套配色，左边一根时间线、圆点是节点，两个入口是挂在线上的卡片。
struct QuickCaptureWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QuickCapture", provider: QuickCaptureProvider()) { entry in
            QuickCaptureView(date: entry.date)
                .containerBackground(for: .widget) { WidgetPalette.background }
        }
        .configurationDisplayName("快速记录")
        .description("一点就写日志或添加待办。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

/// 和 App 的 `Palette`（「默认 · 墨蓝」）同一套颜色，随系统深浅色切换。
enum WidgetPalette {
    static let background = color(light: 0xF6F8FA, dark: 0x0D1117)
    static let card = color(light: 0xFFFFFF, dark: 0x161B22)
    static let ink = color(light: 0x1F2328, dark: 0xF0F6FC)
    static let muted = color(light: 0x59636E, dark: 0x9198A1)
    static let accent = color(light: 0x0969DA, dark: 0x4493F8)
    static let soft = color(light: 0xDDF4FF, dark: 0x121D2F)
    static let line = color(light: 0xD1D9E0, dark: 0x3D444D)

    private static func color(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? uiColor(dark) : uiColor(light) })
    }

    private static func uiColor(_ value: UInt32) -> UIColor {
        UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

/// 每天零点换一次日期，先排好一周。
struct QuickCaptureProvider: TimelineProvider {
    struct Entry: TimelineEntry { let date: Date }
    func placeholder(in context: Context) -> Entry { Entry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days = (1..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        completion(Timeline(entries: [Entry(date: Date())] + days.map(Entry.init), policy: .atEnd))
    }
}

enum QuickCaptureLink {
    static let log = URL(string: "timeline://new/log")!
    static let task = URL(string: "timeline://new/task")!
}

private struct QuickCaptureView: View {
    let date: Date
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "square.and.pencil").font(.title2.weight(.semibold))
            }
            .widgetURL(QuickCaptureLink.log)
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Capsule().frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(date, format: .dateTime.month(.defaultDigits).day().weekday(.abbreviated))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Label("写日志", systemImage: "square.and.pencil").font(.headline)
                }
                Spacer(minLength: 0)
            }
            .widgetURL(QuickCaptureLink.log)
        case .systemSmall:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(date, format: .dateTime.month(.defaultDigits).day())
                        .font(.system(size: 20, weight: .bold)).foregroundStyle(WidgetPalette.ink)
                    Text(date, format: .dateTime.weekday(.abbreviated))
                        .font(.caption.weight(.medium)).foregroundStyle(WidgetPalette.muted)
                }
                actions(compact: true)
            }
        default:
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(date, format: .dateTime.month(.defaultDigits).day())
                        .font(.system(size: 30, weight: .bold)).foregroundStyle(WidgetPalette.ink)
                        .minimumScaleFactor(0.7).lineLimit(1)
                    Text(date, format: .dateTime.weekday(.wide))
                        .font(.subheadline).foregroundStyle(WidgetPalette.muted)
                    Text("今天")
                        .font(.caption2.weight(.semibold)).foregroundStyle(WidgetPalette.accent)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(WidgetPalette.accent.opacity(0.12), in: Capsule())
                        .padding(.top, 2)
                    Spacer(minLength: 0)
                    HStack(spacing: 5) {
                        Circle().fill(WidgetPalette.accent).frame(width: 6, height: 6)
                        Text(verbatim: "Timeline").font(.caption2.weight(.semibold)).foregroundStyle(WidgetPalette.muted)
                    }
                }
                .frame(width: 104, alignment: .leading)
                actions(compact: false)
            }
        }
    }

    /// 两个入口挂在一根竖线上：写日志是实心节点，新待办是空心节点（和 App 里日志、待办的节点一样）。
    private func actions(compact: Bool) -> some View {
        VStack(spacing: 0) {
            RailAction(title: "写日志", symbol: "square.and.pencil", url: QuickCaptureLink.log, filled: true, first: true, last: false, compact: compact)
            RailAction(title: "新待办", symbol: "checklist", url: QuickCaptureLink.task, filled: false, first: false, last: true, compact: compact)
        }
    }
}

/// 时间线上的一行：左边竖线和节点，右边一张卡片。
private struct RailAction: View {
    let title: LocalizedStringKey
    let symbol: String
    let url: URL
    let filled: Bool
    let first: Bool
    let last: Bool
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 7 : 9) {
            ZStack {
                VStack(spacing: 0) {
                    Rectangle().fill(first ? .clear : WidgetPalette.line).frame(width: 1.5)
                    Rectangle().fill(last ? .clear : WidgetPalette.line).frame(width: 1.5)
                }
                node
            }
            .frame(width: 12)
            Link(destination: url) {
                HStack(spacing: compact ? 7 : 10) {
                    Image(systemName: symbol)
                        .font(.system(size: compact ? 13 : 15, weight: .semibold))
                        .foregroundStyle(WidgetPalette.accent)
                        .frame(width: compact ? 26 : 30, height: compact ? 26 : 30)
                        .background(WidgetPalette.soft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(title)
                        .font(.system(size: compact ? 14 : 15, weight: .semibold))
                        .foregroundStyle(WidgetPalette.ink)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    if !compact {
                        Image(systemName: "plus").font(.caption.weight(.bold)).foregroundStyle(WidgetPalette.muted)
                    }
                }
                .padding(.horizontal, compact ? 8 : 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(WidgetPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(WidgetPalette.line.opacity(0.6), lineWidth: 1))
            }
            .padding(.vertical, 3)
        }
    }

    @ViewBuilder private var node: some View {
        ZStack {
            Circle().fill(WidgetPalette.background).frame(width: 12, height: 12)
            if filled {
                Circle().stroke(WidgetPalette.accent, lineWidth: 1.5).frame(width: 11, height: 11)
                Circle().fill(WidgetPalette.accent).frame(width: 5, height: 5)
            } else {
                Circle().stroke(WidgetPalette.muted, lineWidth: 1.5).frame(width: 8, height: 8)
            }
        }
    }
}

/// 控制中心、锁屏和操作按钮上的「写日志」。
@available(iOS 18.0, *)
struct QuickLogControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "QuickLogControl") {
            ControlWidgetButton(action: OpenURLIntent(QuickCaptureLink.log)) {
                Label("写日志", systemImage: "square.and.pencil")
            }
        }
        .displayName("Timeline 写日志")
    }
}

@available(iOS 18.0, *)
struct QuickTaskControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "QuickTaskControl") {
            ControlWidgetButton(action: OpenURLIntent(QuickCaptureLink.task)) {
                Label("新待办", systemImage: "checklist")
            }
        }
        .displayName("Timeline 新待办")
    }
}
