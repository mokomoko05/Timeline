import SwiftUI
import TimelineCore

/// 最近删除：删掉的日志、待办和工作板保留 30 天，可以放回原处或永久删除。
struct RecentlyDeletedView: View {
    @ObservedObject var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<UUID>()
    @State private var confirmingEmpty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("最近删除").font(.title2)
                Spacer()
                Button("清空…") { confirmingEmpty = true }.disabled(store.recentlyDeleted.isEmpty || store.isReadOnly)
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("删除的日志、待办和工作板在本机保留 30 天，包括其他设备同步过来的删除。")
                .font(.caption).foregroundStyle(Palette.muted)
            if store.recentlyDeleted.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "trash").font(.system(size: 28)).foregroundStyle(Palette.muted)
                    Text("没有最近删除的内容").foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(store.recentlyDeleted) { item in
                        RecentlyDeletedRow(item: item)
                            .tag(item.id)
                            .contextMenu {
                                Button("恢复") { restore([item.id]) }
                                Button("永久删除", role: .destructive) { store.purgeDeleted([item.id]) }
                            }
                    }
                }
                .onDeleteCommand { store.purgeDeleted(selection); selection = [] }
            }
            HStack {
                Text(selection.isEmpty ? "" : AppLocalizedFormat("已选 %lld 项", selection.count))
                    .font(.caption).foregroundStyle(Palette.muted)
                Spacer()
                Button("永久删除") { store.purgeDeleted(selection); selection = [] }.disabled(selection.isEmpty)
                Button("恢复") { restore(selection) }.disabled(selection.isEmpty || store.isReadOnly)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 620, height: 480)
        .alert("清空最近删除？", isPresented: $confirmingEmpty) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { store.emptyRecentlyDeleted(); selection = [] }
        } message: { Text("清空后无法恢复。") }
    }

    private func restore(_ ids: Set<UUID>) {
        // 按删除的先后放回：后删的先恢复，撤销时一起撤回。
        for item in store.recentlyDeleted.reversed() where ids.contains(item.id) { store.restoreDeleted(item.id) }
        selection = []
    }
}

private struct RecentlyDeletedRow: View {
    let item: DeletedItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Palette.muted).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? AppLocalized("（无内容）") : item.title).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer()
            Text(item.deletedAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(Palette.muted)
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch item.content {
        case .log: return "text.bubble"
        case .task: return "checklist"
        case .board: return "doc.text"
        }
    }

    private var detail: String {
        switch item.content {
        case .log: return AppLocalizedFormat("日志 · %@", item.day.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "")
        case .task: return AppLocalizedFormat("待办 · %@", item.day.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "")
        case .board: return AppLocalized("工作板")
        }
    }
}

/// 工作板的版本历史：左边列出历史版本，右边预览，选中后换回（当前内容会先另存一版，可以撤销）。
struct BoardHistoryView: View {
    @ObservedObject var store: JournalStore
    let boardID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [BoardVersion] = []
    @State private var selected: BoardVersion.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("版本历史").font(.title2)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("开始一段编辑前、以及同步覆盖前，都会存下原来的内容。只保存在这台设备上。")
                .font(.caption).foregroundStyle(Palette.muted)
            if versions.isEmpty {
                Text("还没有历史版本").foregroundStyle(Palette.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(versions, selection: $selected) { version in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.savedAt, format: .dateTime.month().day().hour().minute())
                            Text(AppLocalizedFormat("%lld 字", version.markdown.count)).font(.caption).foregroundStyle(Palette.muted)
                        }
                        .tag(version.id)
                    }
                    .frame(minWidth: 170, idealWidth: 190, maxWidth: 240)
                    ScrollView {
                        Text(preview)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(10)
                    }
                    .background(Palette.background)
                }
            }
            HStack {
                Spacer()
                Button("换回这个版本") {
                    guard let version = versions.first(where: { $0.id == selected }) else { return }
                    store.restoreBoardVersion(version, for: boardID)
                    dismiss()
                }
                .disabled(selected == nil || store.isReadOnly)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 760, height: 520)
        .onAppear {
            versions = store.boardVersions(for: boardID)
            selected = versions.first?.id
        }
    }

    private var preview: String { versions.first { $0.id == selected }?.markdown ?? "" }
}
