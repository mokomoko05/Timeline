import AppKit
import Combine
import SwiftUI
import TimelineCore

/// 需要让用户在任何窗口都看得到的问题：日记只读、保存失败、同步连续失败。
/// 各窗口的提示条和菜单栏图标都读这一份，按钮做的事也一样。
@MainActor
final class AppIssues: ObservableObject {
    static let shared = AppIssues()

    enum Kind: Equatable {
        case readOnly(String)
        case saveFailed(String)
        case syncFailed(String)
    }

    @Published private(set) var current: Kind?
    private weak var store: JournalStore?
    private weak var cloudSync: CloudSyncController?
    private var cancellables: Set<AnyCancellable> = []

    func attach(store: JournalStore, cloudSync: CloudSyncController?) {
        self.store = store
        self.cloudSync = cloudSync
        cancellables = []
        // objectWillChange 在值改之前发出：下一轮主循环再读。
        let changes: [AnyPublisher<Void, Never>] = [
            store.$errorMessage.map { _ in () }.eraseToAnyPublisher(),
            store.$isReadOnly.map { _ in () }.eraseToAnyPublisher(),
            cloudSync?.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ].compactMap { $0 }
        Publishers.MergeMany(changes).receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }.store(in: &cancellables)
        refresh()
    }

    func refresh() {
        let next: Kind?
        if let store, let error = store.errorMessage {
            next = store.isReadOnly ? .readOnly(error) : .saveFailed(error)
        } else if let error = cloudSync?.sync?.persistentError {
            next = .syncFailed(error)
        } else {
            next = nil
        }
        if next != current { current = next }
    }

    var title: String {
        switch current {
        case .readOnly: return AppLocalized("日记处于只读状态")
        case .saveFailed: return AppLocalized("保存失败，正在自动重试")
        case .syncFailed: return AppLocalized("iCloud 同步出错")
        case nil: return ""
        }
    }

    var detail: String {
        switch current {
        case .readOnly(let text), .saveFailed(let text), .syncFailed(let text): return AppLocalizedLines(text)
        case nil: return ""
        }
    }

    func retrySave() { store?.save() }
    func syncNow() { cloudSync?.sync?.syncSoon() }
    func openDataFolder() { if let store { NSWorkspace.shared.open(store.directory) } }
    func openSettings() { AppRouter.showSettings() }
}

/// 窗口底部的问题提示条：说明出了什么事，并给出能直接点的处理办法。
struct AppIssueBanner: View {
    @Environment(\.typography) private var typography
    @ObservedObject private var issues = AppIssues.shared
    /// 只显示同步问题（保存问题由所在页面自己的提示处理时用）。
    var syncOnly = false

    var body: some View {
        if let issue = issues.current, !syncOnly || issue.isSync {
            HStack(spacing: 8) {
                Image(systemName: issue.isSync ? "icloud.slash" : "exclamationmark.triangle.fill")
                VStack(alignment: .leading, spacing: 1) {
                    Text(issues.title).fontWeight(.semibold)
                    Text(issues.detail).lineLimit(2).foregroundStyle(Palette.deadline.opacity(0.85))
                }
                .help(issues.detail)
                Spacer(minLength: 8)
                switch issue {
                case .saveFailed:
                    Button("重试保存", action: issues.retrySave).buttonStyle(HitAreaButtonStyle())
                    Button("打开数据文件夹", action: issues.openDataFolder).buttonStyle(HitAreaButtonStyle())
                case .readOnly:
                    Button("打开数据文件夹", action: issues.openDataFolder).buttonStyle(HitAreaButtonStyle())
                case .syncFailed:
                    Button("立即同步", action: issues.syncNow).buttonStyle(HitAreaButtonStyle())
                    Button("同步设置…", action: issues.openSettings).buttonStyle(HitAreaButtonStyle())
                }
            }
            .font(.system(size: typography.pt(11)))
            .foregroundStyle(Palette.deadline)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.deadline.opacity(0.08))
            .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(issues.title)
        }
    }
}

extension AppIssues.Kind {
    var isSync: Bool { if case .syncFailed = self { return true } else { return false } }
}
