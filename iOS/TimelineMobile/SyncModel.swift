import Combine
import SwiftUI
import TimelineCore
import UIKit

/// iPhone 端的同步：用户在文件选择器里选中 iCloud 云盘里的「Timeline」文件夹，应用保存书签，以后一直能读写。
/// 这和普通应用用「文件」打开文档是同一套机制，不需要 iCloud 权限，所以免费的开发者签名就能用。
@MainActor
final class SyncModel: ObservableObject {
    static let bookmarkKey = "syncFolderBookmark"

    @Published private(set) var sync: FolderSync?
    @Published private(set) var folderName: String?
    @Published var setupError: String?
    let store: JournalStore
    private let defaults: UserDefaults
    private var active = false

    var isConfigured: Bool { sync != nil }

    init(store: JournalStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        if let path = defaults.string(forKey: "debugSyncFolder") {
            // 模拟器测试用：直接指定一个同步文件夹（真机上用文件选择器）。
            start(URL(fileURLWithPath: path))
        } else if let folder = resolveBookmark() {
            start(folder)
        }
    }

    /// 文件选择器选中的文件夹：先声明访问再存书签，之后每次读写由 `FolderSync` 自己声明访问。
    func choose(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(bookmark, forKey: Self.bookmarkKey)
            setupError = nil
            stop()
            start(url)
        } catch {
            setupError = LF("无法记住这个文件夹：%@", error.localizedDescription)
        }
    }

    func disconnect() {
        defaults.removeObject(forKey: Self.bookmarkKey)
        stop()
    }

    private func resolveBookmark() -> URL? {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            setupError = L("找不到之前选的同步文件夹，请重新选择。")
            return nil
        }
        if stale {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(fresh, forKey: Self.bookmarkKey)
            }
        }
        return url
    }

    private func start(_ folder: URL) {
        // 同步状态（进行中、上次时间）只有同步设置页关心：它直接观察 `FolderSync`。
        // 这里不转发，否则每同步一轮，待办、日记、笔记几个页面都要整个重算一遍。
        let sync = FolderSync(store: store, folder: folder, deviceName: UIDevice.current.model)
        self.sync = sync
        folderName = folder.lastPathComponent
        if active { sync.startAutomaticSync(interval: 15) } else { sync.syncSoon() }
    }

    private func stop() {
        sync?.stopAutomaticSync()
        sync = nil
        folderName = nil
    }

    /// 回到前台：马上同步，之后每 15 秒看一次；进后台前把本机的修改导出去。
    func setActive(_ active: Bool) {
        self.active = active
        guard let sync else { return }
        if active {
            sync.startAutomaticSync(interval: 15)
        } else {
            sync.stopAutomaticSync()
            let background = BackgroundTask()
            Task {
                _ = try? await sync.sync()
                background.end()
            }
        }
    }

    func syncNow() async {
        _ = try? await sync?.sync()
    }
}

/// 进后台后向系统多要一点时间把同步做完；做完或系统收回时间时结束，只结束一次。
@MainActor
private final class BackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Timeline sync") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
