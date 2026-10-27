import Combine
import SwiftUI
import TimelineCore

/// 保存失败、日记只读、同步连续失败时，屏幕顶部浮一颗小胶囊，点开看原因和处理办法。
/// 自己单独观察数据和同步状态，平时不让根视图跟着刷新。
struct IssueBanner: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var sync: SyncModel
    let openSettings: () -> Void

    var body: some View {
        IssueBannerContent(store: store, folder: sync.sync, openSettings: openSettings)
    }
}

private struct IssueBannerContent: View {
    @ObservedObject var store: JournalStore
    var folder: FolderSync?
    let openSettings: () -> Void

    var body: some View {
        if let folder {
            Observed(folder: folder) { pill(syncError: folder.persistentError) }
        } else {
            pill(syncError: nil)
        }
    }

    private struct Observed<Content: View>: View {
        @ObservedObject var folder: FolderSync
        @ViewBuilder let content: () -> Content
        var body: some View { content() }
    }

    @ViewBuilder private func pill(syncError: String?) -> some View {
        if let error = store.errorMessage {
            menu(title: store.isReadOnly ? "日记处于只读状态" : "保存失败，正在自动重试", symbol: "exclamationmark.triangle.fill", detail: error) {
                if !store.isReadOnly { Button("重试保存", systemImage: "arrow.clockwise") { store.save() } }
            }
        } else if let syncError {
            menu(title: "iCloud 同步出错", symbol: "icloud.slash", detail: syncError) {
                Button("立即同步", systemImage: "arrow.clockwise") { folder?.syncSoon() }
                Button("同步设置", systemImage: "gearshape", action: openSettings)
            }
        }
    }

    private func menu<Actions: View>(title: LocalizedStringKey, symbol: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        Menu {
            Section(detail.components(separatedBy: "\n").map(L).joined(separator: "\n")) { actions() }
        } label: {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Palette.danger.opacity(0.35)))
                .foregroundStyle(Palette.danger)
        }
        .padding(.top, 4)
        .transition(Motion.transition(.move(edge: .top).combined(with: .opacity)))
    }
}
