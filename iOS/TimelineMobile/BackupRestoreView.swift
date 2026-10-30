import SwiftUI
import TimelineCore
import UniformTypeIdentifiers

struct BackupRestoreView: View {
    @ObservedObject var store: JournalStore
    @State private var working = false
    @State private var error: String?
    @State private var importing = false
    @State private var source: URL?
    @State private var scoped = false
    @State private var preview: BackupPackagePreview?
    @State private var confirming = false
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var result: String?
    @State private var visible = true
    @State private var missingImages: [String] = []

    var body: some View {
        Form {
            Section {
                Button("导出完整备份") {
                    run { try await export(allowingMissingImages: false) }
                }.disabled(working || store.isReadOnly)
                Button("选择备份并预览") { importing = true }.disabled(working)
                if working { ProgressView("正在处理备份…") }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if let result { Text(result).foregroundStyle(.secondary) }
            } footer: {
                Text("备份包含当前任务、日志、工作板、草稿、恢复记录及其原图。缺少原图会暂停导出；同步设置与系统权限不会被备份覆盖。请将备份保存到独立位置。")
            }
            if let preview {
                Section("备份预览") {
                    LabeledContent("待办", value: "\(preview.tasks)")
                    LabeledContent("日志", value: "\(preview.logs)")
                    LabeledContent("工作板", value: "\(preview.boards)")
                    LabeledContent("原图", value: "\(preview.images)")
                    if preview.missingImages > 0 { LabeledContent("缺失的原图", value: "\(preview.missingImages)") }
                    LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: Int64(preview.bytes), countStyle: .file))
                    Text("内容及原图校验通过。恢复会替换当前内容，并向其他设备同步；恢复前自动保留本机快照。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("恢复此备份", role: .destructive) { confirming = true }.disabled(working)
                    Button("取消选择") { releaseSource() }.disabled(working)
                }
            }
        }
        .navigationTitle("备份与恢复")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder, .package]) { selection in
            switch selection {
            case .failure(let failure): error = failure.localizedDescription
            case .success(let url):
                releaseSource()
                source = url
                scoped = url.startAccessingSecurityScopedResource()
                run { preview = try await JournalStore.inspectBackupPackage(url) }
            }
        }
        .sheet(isPresented: $exporting, onDismiss: cleanupExport) {
            if let exportURL { BackupExportPicker(url: exportURL) { exporting = false } }
        }
        .confirmationDialog("用此备份恢复当前内容？", isPresented: $confirming) {
            Button("恢复", role: .destructive) {
                guard let source else { return }
                run {
                    try await store.restoreBackupPackage(source)
                    result = L("备份已恢复")
                    releaseSource()
                }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(LF("有 %lld 张原图找不到", missingImages.count), isPresented: Binding(get: { !missingImages.isEmpty }, set: { if !$0 { missingImages = [] } }), titleVisibility: .visible) {
            Button("仍然导出") { run { try await export(allowingMissingImages: true) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("联网后图片可能还能下载，可以稍后重试。仍然导出时，备份不含这些原图，其余内容不受影响。")
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; if !working { releaseSource() } }
        .onReceive(NotificationCenter.default.publisher(for: PerfProbe.action)) { note in
            if note.object as? String == "backupRestoreRoundTrip" {
                run {
                    let package = try await store.createBackupPackage(allowingMissingImages: true)
                    defer { Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: package) } }
                    try await store.restoreBackupPackage(package)
                    PerfProbe.lap("BACKUP_RESTORED logs=\(store.allLogs(includeFocus: true).count) error=\(store.errorMessage ?? "none")")
                }
                return
            }
            guard note.object as? String == "backupValidation" else { return }
            run {
                let package = try await store.createBackupPackage()
                defer { Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: package) } }
                let checked = try await JournalStore.inspectBackupPackage(package)
                result = LF("备份校验通过：%lld 条日志", checked.logs)
                PerfProbe.lap("BACKUP_VALIDATED logs=\(checked.logs) images=\(checked.images)")
            }
        }
    }

    private func export(allowingMissingImages: Bool) async throws {
        do {
            exportURL = try await store.createBackupPackage(allowingMissingImages: allowingMissingImages)
            exporting = true
        } catch BackupPackageError.missingImages(let names) {
            missingImages = names
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        working = true; error = nil; result = nil
        Task { @MainActor in
            defer { working = false; if !visible { releaseSource() } }
            do { try await operation() } catch { self.error = error.localizedDescription }
        }
    }
    private func releaseSource() {
        if scoped { source?.stopAccessingSecurityScopedResource() }
        scoped = false; source = nil; preview = nil
    }
    private func cleanupExport() {
        guard let url = exportURL else { return }
        exportURL = nil
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }
    }
}

/// 系统负责复制备份目录，避免 FileWrapper 把整座原图库载入内存。
private struct BackupExportPicker: UIViewControllerRepresentable {
    let url: URL
    let finished: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finished: () -> Void
        init(finished: @escaping () -> Void) { self.finished = finished }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finished() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finished() }
    }
}
