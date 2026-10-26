import AppIntents
import SwiftUI
import WidgetKit

/// 快速记录：主屏和锁屏上一点就进到「写日志」或「新待办」。内容是固定的，不读数据。
struct QuickCaptureWidget: Widget {
    static let accent = Color(red: 0x44 / 255, green: 0x93 / 255, blue: 0xF8 / 255)

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QuickCapture", provider: QuickCaptureProvider()) { _ in
            QuickCaptureView()
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("快速记录")
        .description("一点就写日志或添加待办。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct QuickCaptureProvider: TimelineProvider {
    struct Entry: TimelineEntry { let date: Date }
    func placeholder(in context: Context) -> Entry { Entry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: Date())], policy: .never))
    }
}

enum QuickCaptureLink {
    static let log = URL(string: "timeline://new/log")!
    static let task = URL(string: "timeline://new/task")!
}

private struct QuickCaptureView: View {
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
            VStack(alignment: .leading, spacing: 2) {
                Label("写日志", systemImage: "square.and.pencil").font(.headline)
                Text("Timeline").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(QuickCaptureLink.log)
        case .systemSmall:
            VStack(spacing: 8) {
                button("写日志", "square.and.pencil", QuickCaptureLink.log)
                button("新待办", "checklist", QuickCaptureLink.task)
            }
        default:
            HStack(spacing: 10) {
                button("写日志", "square.and.pencil", QuickCaptureLink.log)
                button("新待办", "checklist", QuickCaptureLink.task)
            }
        }
    }

    private func button(_ title: LocalizedStringKey, _ symbol: String, _ url: URL) -> some View {
        Link(destination: url) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title3.weight(.semibold))
                Text(title).font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(QuickCaptureWidget.accent.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
