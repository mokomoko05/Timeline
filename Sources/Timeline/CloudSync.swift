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
    @Published private(set) var toolbar: SyncToolbarPresentation?
    private let store: JournalStore
    private let defaults: UserDefaults
    private let syncFolder: URL
    private var activeObserver: NSObjectProtocol?
    private var forward: AnyCancellable?

    var isEnabled: Bool { sync != nil }
    var iCloudDriveAvailable: Bool { FileManager.default.fileExists(atPath: syncFolder.deletingLastPathComponent().path) }

    init(store: JournalStore, defaults: UserDefaults = .standard, syncFolder: URL? = nil) {
        self.store = store
        self.defaults = defaults
        self.syncFolder = syncFolder ?? Self.defaultFolder
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
        let sync = FolderSync(store: store, folder: syncFolder, deviceName: Host.current().localizedName ?? "Mac")
        sync.prepareForSync = {
            if let editor = BoardLiveEditorSession.active {
                await withCheckedContinuation { continuation in editor.commit(endingEditing: false) { continuation.resume() } }
            }
        }
        // 同步状态变了让设置界面跟着刷新。
        forward = sync.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        self.sync = sync
        toolbar = SyncToolbarPresentation(sync: sync)
        sync.startAutomaticSync()
    }

    private func stop() {
        sync?.stopAutomaticSync()
        forward = nil
        sync = nil
        toolbar = nil
    }

    func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([syncFolder])
    }

    func syncWithFeedback() async {
        guard let toolbar else { return }
        await toolbar.feedback.run { await syncNow() }
    }

    func syncNow() async {
        guard let sync else { AppRouter.showSettings(); return }
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        do { try await store.saveAndWait() } catch { return }
        await sync.syncUntilExported()
    }
}

/// 放在共用顶栏左端；同步状态只刷新这个控件。
struct WorkspaceSyncButton: View {
    var body: some View {
        if let controller = AppRouter.cloudSync {
            WorkspaceSyncControllerButton(controller: controller)
        }
    }
}

private struct WorkspaceSyncControllerButton: View {
    @ObservedObject var controller: CloudSyncController
    var body: some View {
        if let state = controller.sync, let presentation = controller.toolbar {
            WorkspaceSyncVisibility(controller: controller, state: state, presentation: presentation)
        }
    }
}

private struct WorkspaceSyncVisibility: View {
    let controller: CloudSyncController
    let state: FolderSync
    @ObservedObject var presentation: SyncToolbarPresentation

    var body: some View {
        if presentation.visible {
            WorkspaceCloudSyncButton(controller: controller, state: state, feedback: presentation.feedback)
                .transition(.opacity.combined(with: .move(edge: .leading)))
        }
    }
}

private struct WorkspaceCloudSyncButton: View {
    let controller: CloudSyncController
    @ObservedObject var state: FolderSync
    @ObservedObject var feedback: SyncButtonFeedback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View { button }

    private var button: some View {
        Button {
            Task { @MainActor in await controller.syncWithFeedback() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: feedback.phase.symbol)
                    .id(feedback.phase.symbol)
                    .transition(.scale(scale: reduceMotion ? 1 : 0.6).combined(with: .opacity))
                    .frame(width: 14)
                Text(AppLocalized(feedback.phase.title)).contentTransition(.opacity).lineLimit(1)
                if feedback.isWorking || feedback.phase.isRunning {
                    ProgressView().progressViewStyle(.circular).controlSize(.mini)
                        .frame(width: 12, height: 12).transition(.opacity)
                }
            }
            .font(.system(size: 11, weight: .medium)).frame(minHeight: 24)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.85), value: feedback.phase)
        }
        .buttonStyle(HitAreaButtonStyle(compact: true))
        .foregroundStyle(feedback.phase == .completed ? Color.green : (feedback.phase == .failed ? Palette.deadline : (state.waitingForUpload || state.waitingForDownload ? Color.orange : Palette.accent)))
        .disabled(feedback.isWorking)
        .help(state.lastError.map(AppLocalizedLines) ?? AppLocalized(feedback.phase == .idle ? "立即同步" : feedback.phase.title))
        .accessibilityLabel("立即同步")
        .accessibilityValue(AppLocalized(feedback.phase == .idle ? state.statusTitle : feedback.phase.title))
        .accessibilityIdentifier("workspace.sync")
        .contextMenu { Button("同步详情") { AppRouter.showSettings() } }
    }
}

struct CloudSyncSettings: View {
    @ObservedObject var controller: CloudSyncController
    @State private var retiring: FolderSync.Device?
    @State private var retirementError: String?

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
                Button("立即同步") { Task { await controller.syncNow() } }.disabled(sync.isSyncing)
                Button("在访达中显示") { controller.revealFolder() }
            }
            if let retirementError { Text(retirementError).foregroundStyle(Palette.deadline) }
            Text("停用旧设备不会删除已有数据；再次上线时以新身份接入。请先确认旧设备没有未同步内容。")
                .font(.caption).foregroundStyle(Palette.muted)
                .confirmationDialog("停用这台同步设备？", isPresented: Binding(get: { retiring != nil }, set: { if !$0 { retiring = nil } })) {
                    Button("停用", role: .destructive) {
                        guard let device = retiring else { return }
                        Task { do { try await sync.retireDevice(device.id) } catch { retirementError = error.localizedDescription } }
                    }
                    Button("取消", role: .cancel) { retiring = nil }
                }
            if sync.waitingForUpload {
                Text("本机更新已写入共享文件夹，正在等待 iCloud 确认上传。应用不能强制系统立即上传。")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            if sync.waitingForDownload {
                Text("已请求下载其他设备的更新，下载完成后会自动合并。")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            DisclosureGroup("同步详情") {
                VStack(alignment: .leading, spacing: 6) {
                    if let date = sync.localSavedAt { detail("本机已保存", date: date) }
                    ForEach(sync.fileErrors.keys.sorted(), id: \.self) { path in
                        Text(path + ": " + (sync.fileErrors[path] ?? "")).foregroundStyle(Palette.deadline).textSelection(.enabled)
                    }
                    ForEach(sync.stageDurations.keys.sorted(), id: \.self) { phase in
                        HStack { Text(AppLocalized(SyncPhase(rawValue: phase)?.title ?? phase)); Spacer(); Text("\(Int((sync.stageDurations[phase] ?? 0) * 1000)) ms") }
                    }
                    ForEach(sync.blockingFiles, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                    Text("本机同步完成表示本机本轮工作完成；对方是否收到，请查看下方设备接收确认。")
                    if let since = sync.uploadWaitingSince { detail("本次上传等待开始", date: since) }
                    if let date = sync.lastCheck { detail("最近检查", date: date) }
                    if let date = sync.lastExport { detail("已写入共享文件夹", date: date) }
                    if let date = sync.lastUpload { detail("iCloud 确认上传", date: date) }
                    HStack {
                        Text("本轮读取 / 写入")
                        Spacer()
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(sync.lastReadBytes), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(sync.lastWrittenBytes), countStyle: .file))")
                    }
                    if sync.pendingUploadFiles > 0 {
                        HStack {
                            Text("待上传文件")
                            Spacer()
                            Text("\(sync.pendingUploadFiles) · \(ByteCountFormatter.string(fromByteCount: Int64(sync.pendingUploadBytes), countStyle: .file))")
                        }
                    }
                    ForEach(sync.devices) { device in
                        HStack {
                            Text(device.name)
                            if device.isRetired { Text("已停用").foregroundStyle(Palette.muted) }
                            else if device.supportsRetirement { Button("停用此设备") { retiring = device } }
                            else { Text("升级此设备后可停用").foregroundStyle(Palette.muted) }
                            Spacer()
                            Text(device.exportedAt.formatted(date: .abbreviated, time: .standard))
                            Text("对方最近导出的数据").foregroundStyle(Palette.muted)
                            if let received = device.hasReceivedLocalChanges {
                                Text(AppLocalized(received ? "已接收本机最新修改" : "尚未确认接收本机最新修改"))
                                    .foregroundStyle(received ? Palette.muted : Palette.deadline)
                            }
                        }
                    }
                    Text("上传完成表示 iCloud 已接收；设备接收确认表示对方已合并本机最新修改。原图保留质量，查看时下载。")
                        .foregroundStyle(Palette.muted)
                    if let code = sync.lastErrorCode { Text(code).font(.caption.monospaced()).textSelection(.enabled) }
                }.font(.caption).padding(.vertical, 5)
            }
        }
        Text("数据放在 iCloud 云盘的「Timeline」文件夹，日常只传变更，草稿不同步。增量同步需要各设备更新到最新版。")
            .font(.caption).foregroundStyle(Palette.muted)
    }

    private func detail(_ title: String, date: Date) -> some View {
        HStack {
            Text(AppLocalized(title))
            Spacer()
            Text(date.formatted(date: .abbreviated, time: .standard)).foregroundStyle(Palette.muted)
        }
    }

    @ViewBuilder private func status(_ sync: FolderSync) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AppLocalized(sync.statusTitle)).font(.caption)
                .foregroundStyle(sync.lastError == nil ? Palette.muted : Palette.deadline)
            if let error = sync.lastError { Text(AppLocalizedLines(error)).font(.caption).foregroundStyle(Palette.deadline).lineLimit(2) }
        }
    }
}
