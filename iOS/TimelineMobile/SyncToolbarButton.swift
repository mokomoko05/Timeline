import SwiftUI
import TimelineCore

/// 条件放在 ToolbarItem 外层，隐藏时释放原生工具栏项目及其胶囊空间。
struct SyncToolbarItems: ToolbarContent {
    @ObservedObject var sync: SyncModel

    var body: some ToolbarContent {
        if let state = sync.sync, let presentation = sync.toolbar {
            ConfiguredSyncToolbarItems(sync: sync, state: state, presentation: presentation)
        }
    }
}

private struct ConfiguredSyncToolbarItems: ToolbarContent {
    let sync: SyncModel
    let state: FolderSync
    @ObservedObject var presentation: SyncToolbarPresentation

    var body: some ToolbarContent {
        if presentation.visible {
            ToolbarItem(placement: .topBarLeading) {
                SyncProgressButton(state: state, sync: sync, feedback: presentation.feedback)
            }
        }
    }
}

private struct SyncProgressButton: View {
    @ObservedObject var state: FolderSync
    let sync: SyncModel
    @ObservedObject var feedback: SyncButtonFeedback
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingError = false

    var body: some View { button }
    private func showDetails() { openSettings?() }

    private var button: some View {
        Button {
            performSync()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: feedback.phase.symbol)
                    .id(feedback.phase.symbol)
                    .transition(.scale(scale: reduceMotion ? 1 : 0.6).combined(with: .opacity))
                    .frame(width: 18)
                Text(LocalizedStringKey(feedback.phase.title))
                    .contentTransition(.opacity)
                    .lineLimit(1)
                if feedback.isWorking || feedback.phase.isRunning {
                    ProgressView().controlSize(.mini).transition(.opacity)
                }
            }
            .font(.subheadline)
            .foregroundStyle(feedback.phase == .completed ? Color.green : (feedback.phase == .failed ? Color.red : (state.waitingForUpload || state.waitingForDownload ? Color.orange : Color.accentColor)))
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.85), value: feedback.phase)
        }
        .disabled(feedback.isWorking)
        .accessibilityLabel("立即同步")
        .accessibilityIdentifier("sync-now")
        .accessibilityValue(LocalizedStringKey(feedback.phase == .idle ? state.statusTitle : feedback.phase.title))
        .contextMenu { Button("同步详情", systemImage: "info.circle", action: showDetails) }
        .alert("同步未完成", isPresented: $showingError) {
            Button("同步详情", action: showDetails)
            Button("好", role: .cancel) {}
        } message: {
            Text(state.lastError ?? "")
        }
    }

    private func performSync() {
        Task { @MainActor in
            await sync.syncWithFeedback()
            showingError = state.lastError != nil && state.lastErrorCode != "Timeline.SyncTimeout"
            if PerfProbe.enabled { print("[perf] SYNC_FEEDBACK result=\(feedback.phase.rawValue)") }
        }
    }
}
