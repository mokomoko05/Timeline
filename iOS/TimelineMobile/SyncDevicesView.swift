import SwiftUI
import TimelineCore

struct SyncDevicesView: View {
    @ObservedObject var state: FolderSync
    @State private var selection: FolderSync.Device?
    @State private var error: String?
    var body: some View {
        List {
            ForEach(state.devices) { device in
                VStack(alignment: .leading, spacing: 6) {
                    Text(device.name)
                    Text(device.exportedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                    if device.isRetired { Text("已停用").font(.caption).foregroundStyle(.secondary) }
                    else if device.supportsRetirement { Button("停用此设备", role: .destructive) { selection = device } }
                    else { Text("升级此设备后可停用").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Text("停用前请确认旧设备没有未同步内容。停用不删除已有数据；旧设备再次上线时会以新身份重新接入。")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("同步设备")
        .confirmationDialog("停用这台同步设备？", isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            Button("停用", role: .destructive) {
                guard let device = selection else { return }
                Task { do { try await state.retireDevice(device.id) } catch { self.error = error.localizedDescription } }
            }
            Button("取消", role: .cancel) { selection = nil }
        }
    }
}
