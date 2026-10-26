import AppKit
import Combine
import SwiftUI
import TimelineCore

/// 通过 iCloud Drive 里的「Timeline」文件夹和 iPhone 同步。只是读写一个普通文件夹，由系统的 iCloud Drive 负责上传下载，
/// 不需要开发者账号或 iCloud 权限。
@MainActor
final class CloudSyncController: ObservableObject {
    static let enabledKey = "iCloudSyncEnabled"
    /// iCloud Drive 在本机的位置；没开 iCloud Drive 时不存在。
    static var iCloudDrive: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }
    static var defaultFolder: URL { iCloudDrive.appendingPathComponent("Timeline", isDirectory: true) }

    @Published private(set) var sync: FolderSync?
    private let store: JournalStore
    private let defaults: UserDefaults
    private var activeObserver: NSObjectProtocol?
    private var forward: AnyCancellable?

    var isEnabled: Bool { sync != nil }
    var iCloudDriveAvailable: Bool { FileManager.default.fileExists(atPath: Self.iCloudDrive.path) }

    init(store: JournalStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        if defaults.bool(forKey: Self.enabledKey) { start() }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync?.syncSoon() }
        }
    }

    deinit { if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) } }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled { start() } else { stop() }
    }

    private func start() {
        guard sync == nil, !store.isReadOnly, iCloudDriveAvailable else { return }
        let sync = FolderSync(store: store, folder: Self.defaultFolder, deviceName: Host.current().localizedName ?? "Mac")
        // 同步状态变了让设置界面跟着刷新。
        forward = sync.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        self.sync = sync
        sync.startAutomaticSync()
    }

    private func stop() {
        sync?.stopAutomaticSync()
        forward = nil
        sync = nil
    }

    func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.defaultFolder])
    }
}

struct CloudSyncSettings: View {
    @ObservedObject var controller: CloudSyncController

    var body: some View {
        Toggle("通过 iCloud Drive 与 iPhone 同步", isOn: Binding(get: { controller.isEnabled }, set: controller.setEnabled))
            .disabled(!controller.iCloudDriveAvailable)
        if !controller.iCloudDriveAvailable {
            Text("请先在系统设置的 Apple 账户 › iCloud 中打开 iCloud 云盘。")
                .font(.caption).foregroundStyle(Palette.deadline)
        } else if let sync = controller.sync {
            HStack {
                status(sync)
                Spacer()
                Button("立即同步") { sync.syncSoon() }.disabled(sync.isSyncing)
                Button("在访达中显示") { controller.revealFolder() }
            }
            if !sync.devices.isEmpty {
                Text(AppLocalizedFormat("已连接：%@", sync.devices.map(\.name).joined(separator: ", ")))
                    .font(.caption).foregroundStyle(Palette.muted)
            }
        }
        Text("数据放在 iCloud 云盘的「Timeline」文件夹，每台设备只写自己的文件，草稿不同步。")
            .font(.caption).foregroundStyle(Palette.muted)
    }

    @ViewBuilder private func status(_ sync: FolderSync) -> some View {
        if sync.isSyncing {
            Text("正在同步…").font(.caption).foregroundStyle(Palette.muted)
        } else if let error = sync.lastError {
            Text(AppLocalizedLines(error)).font(.caption).foregroundStyle(Palette.deadline)
        } else if let date = sync.lastSync {
            Text(AppLocalizedFormat("上次同步：%@", date.formatted(date: .omitted, time: .standard)))
                .font(.caption).foregroundStyle(Palette.muted)
        }
    }
}
