import SwiftUI
import TimelineCore

/// 最近删除：左滑恢复或永久删除；删掉的日志、待办和工作板在本机保留 30 天，包括其他设备同步过来的删除。
struct RecentlyDeletedView: View {
    @ObservedObject var store: JournalStore
    @State private var confirmingEmpty = false

    var body: some View {
        List {
            Section {
                ForEach(store.recentlyDeleted) { item in
                    DeletedRow(item: item)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { store.purgeDeleted([item.id]) } label: { Label("永久删除", systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading) {
                            Button { restore(item) } label: { Label("恢复", systemImage: "arrow.uturn.backward") }.tint(Palette.accent)
                        }
                        .contextMenu {
                            Button { restore(item) } label: { Label("恢复", systemImage: "arrow.uturn.backward") }
                            Button(role: .destructive) { store.purgeDeleted([item.id]) } label: { Label("永久删除", systemImage: "trash") }
                        }
                }
            } footer: {
                Text("删除的日志、待办和工作板在本机保留 30 天，包括其他设备同步过来的删除。左滑恢复。")
            }
        }
        .overlay {
            if store.recentlyDeleted.isEmpty {
                ContentUnavailableView("没有最近删除的内容", systemImage: "trash")
            }
        }
        .navigationTitle("最近删除")
        .toolbar {
            if !store.recentlyDeleted.isEmpty {
                Button("清空", role: .destructive) { confirmingEmpty = true }
            }
        }
        .confirmationDialog("清空最近删除？", isPresented: $confirmingEmpty, titleVisibility: .visible) {
            Button("清空", role: .destructive) { store.emptyRecentlyDeleted() }
        } message: { Text("清空后无法恢复。") }
    }

    private func restore(_ item: DeletedItem) {
        store.restoreDeleted(item.id)
        store.save()
    }
}

private struct DeletedRow: View {
    let item: DeletedItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Palette.muted).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title.isEmpty ? L("（无内容）") : item.title).foregroundStyle(Palette.ink).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(Palette.muted)
            }
        }
    }

    private var symbol: String {
        switch item.content {
        case .log: return "text.bubble"
        case .task: return "checklist"
        case .board: return "doc.text"
        }
    }

    private var detail: String {
        let deleted = LF("%@删除", item.deletedAt.formatted(.relative(presentation: .named)))
        guard let day = item.day else { return L("工作板") + " · " + deleted }
        let kind: String
        if case .log = item.content { kind = L("日志") } else { kind = L("待办") }
        return kind + " · " + day.formatted(date: .abbreviated, time: .omitted) + " · " + deleted
    }
}

/// 工作板的版本历史：点开一个版本先看内容，再决定换不换回去。
struct BoardHistoryView: View {
    @ObservedObject var store: JournalStore
    let boardID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [BoardVersion] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(versions) { version in
                        NavigationLink {
                            BoardVersionPreview(version: version) {
                                store.restoreBoardVersion(version, for: boardID)
                                store.save()
                                dismiss()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(version.savedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(Palette.ink)
                                Text(firstLine(version.markdown)).font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
                            }
                        }
                    }
                } footer: {
                    Text("开始一段编辑前、以及同步覆盖前，都会存下原来的内容。只保存在这台设备上。")
                }
            }
            .overlay { if versions.isEmpty { ContentUnavailableView("还没有历史版本", systemImage: "clock.arrow.circlepath") } }
            .navigationTitle("版本历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .onAppear { versions = store.boardVersions(for: boardID) }
    }

    private func firstLine(_ markdown: String) -> String {
        markdown.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } ?? ""
    }
}

private struct BoardVersionPreview: View {
    let version: BoardVersion
    let restore: () -> Void

    var body: some View {
        ScrollView {
            MarkdownView(source: version.markdown, foldScope: "board-version." + version.id.uuidString)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.background)
        .navigationTitle(version.savedAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("换回这个版本", action: restore) }
    }
}
