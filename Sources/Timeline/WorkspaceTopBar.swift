import AppKit
import Combine
import SwiftUI

/// 快捷键只让顶栏订阅；设置改变后即刻更新提示，不刷新整个工作区。
@MainActor
final class WorkspaceShortcutLabels: ObservableObject {
    @Published private(set) var bindings: [HotKeyAction: HotKeyBinding] = [:]
    private let defaults: UserDefaults
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refresh()
        for name in [Notification.Name.timelineHotKeysChanged, UserDefaults.didChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func refresh() {
        let latest = Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.map { ($0, HotKeyStore.binding(for: $0, defaults: defaults)) })
        if latest != bindings { bindings = latest }
    }

    func help(_ title: String, action: HotKeyAction) -> String {
        AppLocalized(title) + " · " + (bindings[action] ?? action.defaultBinding).label
    }
}

struct WorkspacePanelShortcut: Identifiable {
    let action: HotKeyAction
    let title: String
    let symbol: String
    var id: HotKeyAction { action }

    static let all: [WorkspacePanelShortcut] = [
        .init(action: .focusPanel, title: "专注计时", symbol: "timer"),
        .init(action: .notes, title: "笔记与日记", symbol: "note.text"),
        .init(action: .board, title: "工作板", symbol: "list.bullet.rectangle"),
        .init(action: .shell, title: "内置终端", symbol: "terminal"),
        .init(action: .log, title: "快速写日志", symbol: "square.and.pencil"),
        .init(action: .search, title: "搜索", symbol: "magnifyingglass"),
    ]
}

/// 顶部操作使用相同的图标尺寸、点击范围和悬停效果。
struct WorkspaceIconButton: View {
    let symbol: String
    let title: String
    let help: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 24)
        }
        .buttonStyle(HitAreaButtonStyle(compact: true))
        .foregroundStyle(Palette.muted)
        .help(help)
        .accessibilityLabel(AppLocalized(title))
        .accessibilityIdentifier(identifier)
    }
}

struct WorkspacePanelButtons: View {
    @StateObject private var shortcuts = WorkspaceShortcutLabels()

    var body: some View {
        HStack(spacing: 6) {
            ForEach(WorkspacePanelShortcut.all) { panel in
                WorkspaceIconButton(symbol: panel.symbol, title: panel.title,
                                    help: shortcuts.help(panel.title, action: panel.action),
                                    identifier: "workspace.panel.\(panel.action.rawValue)") {
                    AppRouter.togglePanel(panel.action)
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("面板")
    }
}

/// 主界面和笔记 / 日记共用顶栏，关闭按钮始终处在同一位置。
struct WorkspaceTopBar<Leading: View>: View {
    let closeAction: HotKeyAction
    let close: () -> Void
    @ViewBuilder let leading: () -> Leading
    @StateObject private var shortcuts = WorkspaceShortcutLabels()

    var body: some View {
        HStack(spacing: 8) {
            leading()
            Spacer(minLength: 8)
            WorkspaceIconButton(symbol: "xmark", title: "隐藏", help: shortcuts.help("隐藏", action: closeAction),
                                identifier: "workspace.close", action: close)
        }
        .frame(height: 28)
        .padding(.horizontal, 16).padding(.vertical, 2)
    }
}
