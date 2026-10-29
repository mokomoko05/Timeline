import SwiftUI
import TimelineCore

/// 同步进度局限在按钮内，避免每次同步让整个页面重算。
struct SyncToolbarButton: View {
    @ObservedObject var sync: SyncModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let state = sync.sync {
            SyncProgressButton(state: state) { await sync.syncNow() }
        } else if let openSettings {
            Button { openSettings() } label: { Label("设置同步", systemImage: "icloud.slash") }
        }
    }
}

private struct SyncProgressButton: View {
    @ObservedObject var state: FolderSync
    var sync: () async -> Void
    @State private var working = false
    @State private var showingError = false

    var body: some View {
        Button {
            working = true
            Task { @MainActor in
                await sync()
                working = false
                showingError = state.lastError != nil
            }
        } label: {
            Label(working || state.isSyncing ? "正在同步…" : (state.waitingForDownload ? "等待下载" : "同步"),
                  systemImage: state.lastError == nil ? "arrow.triangle.2.circlepath.icloud" : "exclamationmark.icloud")
        }
        .disabled(working || state.isSyncing)
        .accessibilityLabel("立即同步")
        .accessibilityIdentifier("sync-now")
        .alert("同步失败", isPresented: $showingError) { Button("好", role: .cancel) {} } message: {
            Text(state.lastError ?? "")
        }
    }
}
