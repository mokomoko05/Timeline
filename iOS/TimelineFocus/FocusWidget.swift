import ActivityKit
import SwiftUI
import WidgetKit

@main
struct FocusWidgets: WidgetBundle {
    var body: some Widget {
        FocusLiveActivity()
        QuickCaptureWidget()
        if #available(iOS 18.0, *) {
            QuickLogControl()
            QuickTaskControl()
        }
    }
}

/// 专注倒计时：锁屏上一张卡片，灵动岛上左边图标、右边剩余时间，展开后是任务名和进度。
struct FocusLiveActivity: Widget {
    private let accent = Color(red: 0x44 / 255, green: 0x93 / 255, blue: 0xF8 / 255)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusActivityAttributes.self) { context in
            lockScreen(context)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.status, systemImage: symbol(context.state))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint(context.state))
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    timer(context.state)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(tint(context.state))
                        .frame(maxWidth: 90, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        title(context.attributes).font(.subheadline.weight(.medium)).lineLimit(1)
                        progress(context)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: symbol(context.state)).foregroundStyle(tint(context.state))
            } compactTrailing: {
                timer(context.state, compact: true)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tint(context.state))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 50, alignment: .trailing)
            } minimal: {
                Image(systemName: symbol(context.state)).foregroundStyle(tint(context.state))
            }
        }
    }

    private func lockScreen(_ context: ActivityViewContext<FocusActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(context.state.status, systemImage: symbol(context.state))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint(context.state))
                Spacer()
                timer(context.state)
                    .font(.system(size: 34, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 160, alignment: .trailing)
            }
            title(context.attributes).font(.body.weight(.medium)).foregroundStyle(.white).lineLimit(2)
            progress(context)
        }
    }

    private func title(_ attributes: FocusActivityAttributes) -> Text {
        Text((attributes.number.map { "#\($0) " } ?? "") + attributes.title)
    }

    /// `compact`：灵动岛右边地方小，不留小时位（专注不会超过 4 小时，超过 1 小时时显示为分钟数）。
    @ViewBuilder private func timer(_ state: FocusActivityAttributes.ContentState, compact: Bool = false) -> some View {
        if state.isRunning {
            Text(timerInterval: Date()...max(Date(), state.endsAt), countsDown: true, showsHours: !compact)
        } else {
            Text(state.frozenText)
        }
    }

    @ViewBuilder private func progress(_ context: ActivityViewContext<FocusActivityAttributes>) -> some View {
        let planned = max(1, context.attributes.plannedSeconds)
        if context.state.isRunning {
            ProgressView(timerInterval: context.state.endsAt.addingTimeInterval(-planned)...context.state.endsAt, countsDown: true) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(accent)
        } else {
            ProgressView(value: max(0, min(1, (context.state.frozenRemaining ?? 0) / planned)))
                .tint(tint(context.state))
        }
    }

    private func symbol(_ state: FocusActivityAttributes.ContentState) -> String {
        state.finished ? "bell.fill" : (state.isRunning ? "timer" : "pause.fill")
    }

    private func tint(_ state: FocusActivityAttributes.ContentState) -> Color {
        state.finished ? .orange : (state.isRunning ? accent : .gray)
    }
}
