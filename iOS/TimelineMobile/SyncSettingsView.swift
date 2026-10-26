import SwiftUI
import TimelineCore

/// 同步设置：选 iCloud 云盘里的「Timeline」文件夹，看同步状态。
struct SyncSettingsView: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var sync: SyncModel
    @State private var choosing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let folder = sync.folderName, let state = sync.sync {
                        LabeledContent("同步文件夹", value: folder)
                        if state.isSyncing {
                            LabeledContent("状态") { ProgressView() }
                        } else if let error = state.lastError {
                            Text(error).foregroundStyle(.red)
                        } else if let date = state.lastSync {
                            LabeledContent("上次同步", value: date.formatted(date: .omitted, time: .standard))
                        }
                        if !state.devices.isEmpty {
                            LabeledContent("其他设备", value: state.devices.map(\.name).joined(separator: "、"))
                        }
                        Button("立即同步") { Task { await sync.syncNow() } }.disabled(state.isSyncing)
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
                if let message = store.errorMessage {
                    Section("数据") { Text(message).foregroundStyle(.red) }
                }
                Section("本机数据") {
                    LabeledContent("待办", value: "\(store.tasks().count)")
                    LabeledContent("日志", value: "\(store.allLogs(includeFocus: true).count)")
                    LabeledContent("工作板", value: "\(store.boards.count)")
                }
            }
            .navigationTitle("同步")
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { sync.choose(url) }
            }
        }
    }
}
