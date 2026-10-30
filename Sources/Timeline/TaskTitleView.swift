import AppKit
import SwiftUI
import TimelineCore

extension Notification.Name {
    static let timelineCommitEditing = Notification.Name("TimelineCommitEditing")
    /// 编辑器的网页进程意外退出、已保存并重新载入：界面提示一句。`object` 是 "inline"（日志就地编辑）或 "board"。
    static let timelineEditorRecovered = Notification.Name("TimelineEditorRecovered")
}

/// 正在改、还没保存的任务标题。标题只有 ⌘↩ 才保存（失焦、提交通知都不算），退出应用或释放隐藏的界面时要先问过，不能悄悄丢掉。
@MainActor
final class TaskTitleEdits {
    enum Choice { case save, discard, cancel }

    static let shared = TaskTitleEdits()
    /// 测试里换掉，不弹窗。
    var prompt: (Int) -> Choice = TaskTitleEdits.askUser
    private var edits: [UUID: (dirty: () -> Bool, save: () -> Void)] = [:]

    var hasUnsaved: Bool { edits.values.contains { $0.dirty() } }

    func register(_ token: UUID, dirty: @escaping () -> Bool, save: @escaping () -> Void) { edits[token] = (dirty, save) }
    func remove(_ token: UUID) { edits[token] = nil }

    /// 退出前调用；返回 false 表示用户要回去接着改。
    func resolveBeforeTermination() -> Bool {
        let unsaved = edits.values.filter { $0.dirty() }
        guard !unsaved.isEmpty else { return true }
        switch prompt(unsaved.count) {
        case .cancel: return false
        case .discard: return true
        case .save:
            unsaved.forEach { $0.save() }
            return true
        }
    }

    private static func askUser(_ count: Int) -> Choice {
        let alert = NSAlert()
        alert.messageText = AppLocalizedFormat("有 %lld 个任务标题还没保存", count)
        alert.informativeText = AppLocalized("退出后没保存的修改会丢失。")
        alert.addButton(withTitle: AppLocalized("保存并退出"))
        alert.addButton(withTitle: AppLocalized("返回 Timeline"))
        alert.addButton(withTitle: AppLocalized("放弃修改"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .cancel
        default: return .discard
        }
    }
}

struct TaskTitleView: View {
    @Environment(\.typography) private var typography
    @Environment(\.isEnabled) private var enabled
    @Binding var title: String
    let completed: Bool
    let color: Color
    let fontSize: CGFloat
    let next: () -> Void
    var itemID: UUID = UUID()
    @Binding var requestedEdit: UUID?
    var prepare: () -> Void = {}
    /// 右键菜单（在标题文字上右键也用它）。
    var menuItems: [TextMenuItem] = []
    @State private var editing = false
    @State private var editText = ""
    @State private var focused = false
    @State private var editToken: UUID?
    @State private var originalText = ""

    var body: some View {
        HStack(spacing: 0) {
            if editing {
                TaskInput(text: $editText, focused: $focused, fontSize: fontSize,
                          submit: { finishEditing(); next() }, cancel: cancelEditing, commandReturnOnly: true)
                    .frame(height: typography.pt(fontSize) + 7)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(Palette.soft, in: RoundedRectangle(cornerRadius: 4))
                    .onAppear { focused = true }
                    .accessibilityLabel("编辑事项，支持 Markdown 链接")
            } else {
                TaskLinkText(source: title, completed: completed, color: color, fontSize: fontSize,
                             edit: startEditing, open: SafariLinks.open, dragTaskID: itemID, select: prepare, menuItems: menuItems)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: typography.pt(fontSize)))
        .foregroundStyle(completed ? Palette.muted : color)
        .tint(Palette.accent)
        .onChange(of: requestedEdit) { if $0 == itemID { requestedEdit = nil; startEditing() } }
        .onAppear {
            if requestedEdit == itemID { requestedEdit = nil; startEditing() }
            if editing { registerEdit() }
        }
        .onDisappear { unregisterEdit() }
    }

    private func registerEdit() {
        let token = editToken ?? UUID()
        editToken = token
        let text = $editText, original = originalText
        TaskTitleEdits.shared.register(token, dirty: { text.wrappedValue != original }, save: finishEditing)
    }

    private func unregisterEdit() {
        if let editToken { TaskTitleEdits.shared.remove(editToken) }
        editToken = nil
    }

    private func startEditing() {
        guard enabled, !editing else { return }
        prepare()
        editText = title
        originalText = title
        focused = false
        editing = true
        registerEdit()
    }

    private func cancelEditing() {
        focused = false
        editing = false
        unregisterEdit()
    }

    private func finishEditing() {
        guard editing else { return }
        focused = false
        editing = false
        unregisterEdit()
        title = editText
    }
}

@MainActor
enum SafariLinks {
    static func usesSafari(_ url: URL) -> Bool {
        !url.isFileURL || url.pathExtension.lowercased() == "pdf"
    }

    /// 页面已在 Safari 里开着时，切换到那个标签页（保留滚动位置，不重新加载）；测试里可替换。
    static var activateExistingTab: (URL) async -> Bool = { await FocusProbe.activateExistingTab(for: $0) }
    /// 实际打开链接；测试里可替换。
    static var launch: (URL) -> Void = { SafariLinks.launchInSafari($0) }

    static func open(_ url: URL) {
        guard let url = TaskText.linkURL(url.absoluteString) else { return }
        if !usesSafari(url) {
            if !NSWorkspace.shared.open(url) { showError(AppLocalizedFormat("无法打开本地文件：%@", url.path)) }
            return
        }
        // 先找已经开着的标签页，找不到（或没运行、没授权）才新打开。
        Task { @MainActor in
            if await activateExistingTab(url) { return }
            launch(url)
        }
    }

    private static func launchInSafari(_ url: URL) {
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            showError("未找到 Safari，请确认 Safari 已安装。")
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                DispatchQueue.main.async { showError(error.localizedDescription) }
            }
        }
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "无法打开链接"
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

struct LinkComposer: View {
    let insert: (String) -> Void
    var initialAddress = ""
    var initialLabel = ""
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("插入链接").font(.headline)
            TextField("网址或本地文件路径", text: $address).focused($addressFocused)
            TextField("显示名称（可选）", text: $label)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("插入") {
                    guard let url = TaskText.linkURL(address) else { return }
                    insert(TaskText.markdownLink(label: label, url: url))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(TaskText.linkURL(address) == nil)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 380)
        .onAppear { address = initialAddress; label = initialLabel; addressFocused = true }
    }
}
