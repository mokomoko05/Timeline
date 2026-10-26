import SwiftUI
import TimelineCore

/// 设置：界面语言；同步（选 iCloud 云盘里的「Timeline」文件夹，看同步状态）；本机数据。
struct SyncSettingsView: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var sync: SyncModel
    @EnvironmentObject private var languages: LanguageStore
    @EnvironmentObject private var reminders: ReminderScheduler
    @State private var choosing = false
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
                    if reminders.isEnabled, reminders.authorization == .denied {
                        Button("通知未开启，去设置里允许") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                } header: {
                    Text("提醒")
                } footer: {
                    Text("在 Mac 或 iPhone 上给待办设的提醒，都会在这台 iPhone 上响。应用在后台时会不定时同步一次，新设的提醒也能排上。")
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
            .navigationTitle("设置")
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
        if state.isSyncing {
            LabeledContent("状态") { ProgressView() }
        } else if let error = state.lastError {
            Text(error).foregroundStyle(.red)
        } else if let date = state.lastSync {
            LabeledContent("上次同步", value: DayText.timeWithSeconds(date))
        }
        if !state.devices.isEmpty {
            LabeledContent("其他设备", value: state.devices.map(\.name).joined(separator: "、"))
        }
        Button("立即同步", action: syncNow).disabled(state.isSyncing)
    }
}
