import SwiftUI
import TimelineCore

/// 设置：界面语言；同步（选 iCloud 云盘里的「Timeline」文件夹，看同步状态）；本机数据。
struct SyncSettingsView: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var sync: SyncModel
    @EnvironmentObject private var languages: LanguageStore
    @EnvironmentObject private var reminders: ReminderScheduler
    @State private var choosing = false
    @State private var openingBackup = false
    /// 作为弹出的页面显示（iOS 18 起设置不在标签栏里）：右上角有「完成」。
    var presented = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("语言") {
                    Picker("界面语言", selection: Binding(get: { languages.language }, set: { languages.set($0) })) {
                        ForEach(AppLanguage.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                    }
                }
                Section {
                    if let folder = sync.folderName, let state = sync.sync {
                        LabeledContent("同步文件夹", value: folder)
                        SyncStatusRows(state: state) { Task { await sync.syncNow() } }
                        NavigationLink("同步设备") { SyncDevicesView(state: state) }
                        Button("更换文件夹") { choosing = true }
                        Button("停止同步", role: .destructive) { sync.disconnect() }
                    } else {
                        Button("选择 iCloud 云盘里的 Timeline 文件夹") { choosing = true }
                    }
                    if let error = sync.setupError { Text(error).foregroundStyle(.red) }
                } header: {
                    Text("iCloud 同步")
                } footer: {
                    Text("先在 Mac 版 Timeline 的设置里打开「通过 iCloud Drive 与 iPhone 同步」，iCloud 云盘里会出现「Timeline」文件夹；再在这里选中它。草稿不同步。")
                }
                Section {
                    Toggle("在 iPhone 上提醒待办", isOn: Binding(get: { reminders.isEnabled }, set: { reminders.isEnabled = $0 }))
                    if let error = reminders.schedulingError { Text(error).font(.caption).foregroundStyle(.red) }
                    if reminders.isEnabled, reminders.authorization == .denied {
                        Button("通知未开启，去设置里允许") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                } header: {
                    Text("提醒")
                } footer: {
                    Text("提醒在这台设备收到任务更新后安排。后台刷新由系统决定；临近提醒时间时，请打开应用确认同步及提醒权限。")
                }
                Section {
                    Label("主屏 / 锁屏小组件「快速记录」", systemImage: "square.grid.2x2")
                    Label("控制中心按钮「Timeline 写日志」", systemImage: "switch.2")
                    Label("快捷指令与 Siri：「写日志」「添加待办」", systemImage: "square.stack.3d.up")
                } header: {
                    Text("应用外快速记录")
                } footer: {
                    Text("想从其他应用分享到日记：在「快捷指令」里新建一个快捷指令，加入 Timeline 的「写日志」动作，把内容设为「快捷指令输入」，再在详细信息里打开「在共享表单中显示」。文字、链接和图片都能分享进来。")
                }
                if let message = store.errorMessage {
                    Section("数据") { Text(message).foregroundStyle(.red) }
                }
                Section("本机数据") {
                    NavigationLink("备份与恢复", value: "backup")
                    LabeledContent("待办", value: "\(store.tasks().count)")
                    LabeledContent("日志", value: "\(store.allLogs(includeFocus: true).count)")
                    LabeledContent("工作板", value: "\(store.boards.count)")
                    NavigationLink {
                        RecentlyDeletedView(store: store)
                    } label: {
                        LabeledContent("最近删除", value: store.recentlyDeleted.isEmpty ? "" : "\(store.recentlyDeleted.count)")
                    }
                }
            }
            .navigationDestination(for: String.self) { _ in BackupRestoreView(store: store) }
            .navigationDestination(isPresented: $openingBackup) { BackupRestoreView(store: store) }
            .navigationTitle("设置")
            .onReceive(NotificationCenter.default.publisher(for: PerfProbe.action)) { note in
                if note.object as? String == "openBackup" { openingBackup = true }
            }
            .toolbar {
                if presented { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { sync.choose(url) }
            }
        }
    }
}

/// 同步状态：单独观察 `FolderSync`，同步进行时只有这几行跟着刷新。
private struct SyncStatusRows: View {
    @ObservedObject var state: FolderSync
    let syncNow: () -> Void

    var body: some View {
        Label(LocalizedStringKey(state.statusTitle), systemImage: state.lastError == nil && state.fileErrors.isEmpty ? "icloud" : "exclamationmark.icloud")
            .foregroundStyle(state.lastError == nil && state.fileErrors.isEmpty ? Color.primary : .red)
        if let error = state.lastError { Text(LocalizedStringKey(error)).font(.caption).foregroundStyle(.red) }
        if state.waitingForUpload {
            Text("本机更新已写入共享文件夹，正在等待 iCloud 确认上传。应用不能强制系统立即上传。")
                .font(.caption).foregroundStyle(.secondary)
            if let since = state.uploadWaitingSince {
                LabeledContent("本次上传等待开始", value: since.formatted(date: .abbreviated, time: .standard))
            }
        }
        if state.waitingForDownload {
            Text("已请求下载其他设备的更新，下载完成后会自动合并。")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let date = state.localSavedAt { LabeledContent("本机已保存", value: date.formatted(date: .omitted, time: .standard)) }
        ForEach(state.fileErrors.keys.sorted(), id: \.self) { path in
            VStack(alignment: .leading) { Text(path).font(.caption.monospaced()); Text(state.fileErrors[path] ?? "").font(.caption).foregroundStyle(.red) }
        }
        DisclosureGroup("阶段耗时与等待文件") {
            ForEach(state.stageDurations.keys.sorted(), id: \.self) { phase in
                LabeledContent(LocalizedStringKey(SyncPhase(rawValue: phase)?.title ?? phase), value: "\(Int((state.stageDurations[phase] ?? 0) * 1000)) ms")
            }
            ForEach(state.blockingFiles, id: \.self) { Text($0).font(.caption.monospaced()) }
        }
        Text("本机同步完成表示本机本轮工作完成；对方是否收到，请查看下方设备接收确认。")
            .font(.caption).foregroundStyle(.secondary)
        if let date = state.lastCheck { LabeledContent("最近检查", value: date.formatted(date: .abbreviated, time: .standard)) }
        if let date = state.lastExport { LabeledContent("已写入共享文件夹", value: date.formatted(date: .abbreviated, time: .standard)) }
        if let date = state.lastUpload { LabeledContent("iCloud 确认上传", value: date.formatted(date: .abbreviated, time: .standard)) }
        LabeledContent("本轮读取 / 写入", value: "\(ByteCountFormatter.string(fromByteCount: Int64(state.lastReadBytes), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(state.lastWrittenBytes), countStyle: .file))")
        if state.pendingUploadFiles > 0 {
            LabeledContent("待上传文件", value: "\(state.pendingUploadFiles) · \(ByteCountFormatter.string(fromByteCount: Int64(state.pendingUploadBytes), countStyle: .file))")
        }
        ForEach(state.devices) { device in
            LabeledContent(device.name) {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(device.exportedAt.formatted(date: .abbreviated, time: .standard))
                    Text("对方最近导出的数据").font(.caption2).foregroundStyle(.secondary)
                    if let received = device.hasReceivedLocalChanges {
                        Text(LocalizedStringKey(received ? "已接收本机最新修改" : "尚未确认接收本机最新修改"))
                            .font(.caption2).foregroundStyle(received ? Color.secondary : .orange)
                    }
                }
            }
        }
        Text("上传完成表示 iCloud 已接收；设备接收确认表示对方已合并本机最新修改。原图保留质量，查看时下载。")
            .font(.caption).foregroundStyle(.secondary)
        Text("数据放在 iCloud 云盘的「Timeline」文件夹，日常只传变更，草稿不同步。增量同步需要各设备更新到最新版。")
            .font(.caption).foregroundStyle(.secondary)
        if let code = state.lastErrorCode { Text(code).font(.caption.monospaced()).textSelection(.enabled) }
        Button("重新检查并重试", action: syncNow)
    }
}
