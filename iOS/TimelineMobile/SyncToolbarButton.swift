import SwiftUI
import TimelineCore

/// 条件放在 ToolbarItem 外层，隐藏时释放原生工具栏项目及其胶囊空间。
struct SyncToolbarItems: ToolbarContent {
    @ObservedObject var sync: SyncModel

    var body: some ToolbarContent {
        if let presentation = sync.toolbar {
            ConfiguredSyncToolbarItems(sync: sync, presentation: presentation)
        }
    }
}

private struct ConfiguredSyncToolbarItems: ToolbarContent {
    let sync: SyncModel
    @ObservedObject var presentation: SyncToolbarPresentation

    var body: some ToolbarContent {
        if presentation.visible {
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .topBarLeading) { SyncStatusButton(sync: sync, indicator: presentation.indicator) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarLeading) { SyncStatusButton(sync: sync, indicator: presentation.indicator) }
            }
        }
    }
}

/// 一个不带文字的小云图标：平时是淡灰色，只有真的需要处理时才有颜色。点一下立即同步，长按看详情。
private struct SyncStatusButton: View {
    let sync: SyncModel
    @ObservedObject var indicator: SyncIndicator
    @Environment(\.openSettings) private var openSettings
    @State private var outcome: SyncIndicatorOutcome?

    var body: some View {
        Button(action: performSync) {
            ZStack {
                if indicator.state == .working {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: indicator.state.symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(tint)
                        .id(indicator.state.symbol)
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .animation(Motion.adapt(.easeInOut(duration: 0.2)), value: indicator.state)
        }
        .buttonStyle(.plain)
        .disabled(indicator.state == .working)
        .accessibilityLabel(LocalizedStringKey(indicator.state.title))
        .accessibilityHint("立即同步")
        .accessibilityIdentifier("sync-now")
        .contextMenu { Button("同步详情", systemImage: "info.circle") { openSettings?() } }
        .alert(alertTitle, isPresented: showingOutcome) {
            if case .failed = outcome { Button("同步详情") { openSettings?() } }
            Button("好", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var tint: Color {
        switch indicator.state {
        case .attention: return Palette.danger
        case .confirmed: return Palette.success
        default: return Palette.muted
        }
    }

    private var showingOutcome: Binding<Bool> {
        Binding(get: { outcome != nil && outcome != .confirmed }, set: { if !$0 { outcome = nil } })
    }

    private var alertTitle: LocalizedStringKey {
        if case .failed = outcome { return "同步未完成" }
        return "还在等 iCloud"
    }

    private var alertMessage: String {
        if case .failed(let message) = outcome { return message.components(separatedBy: "\n").map(L).joined(separator: "\n") }
        return L("修改已存在本机。iCloud 的传输由系统安排，完成后图标会自动消失。")
    }

    private func performSync() {
        Task { @MainActor in
            outcome = await sync.syncWithFeedback()
            if PerfProbe.enabled { print("[perf] SYNC_INDICATOR result=\(indicator.state.rawValue)") }
        }
    }
}
