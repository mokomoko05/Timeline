import SwiftUI
import DayleafCore

struct MetadataSymbol: View {
    @Environment(\.typography) private var typography
    let symbol: String
    var active = false

    var body: some View {
        Text(symbol).font(.system(size: typography.pt(13), weight: .semibold, design: .monospaced))
            .foregroundStyle(active ? Palette.accent : Palette.muted)
            .frame(width: 24, height: 22).contentShape(Rectangle())
    }
}

/// 草稿和已保存条目共用的标签选择器；点选即时生效，点击外部关闭。
struct TagSelectionPopover: View {
    @ObservedObject var store: JournalStore
    @Binding var tags: [String]
    @State private var query = ""
    @FocusState private var searching: Bool

    private var candidates: [TagCandidate] { store.tagCandidates(query: query, limit: 100) }
    private var choices: [TagCandidate] {
        let candidates = candidates
        let missing = tags.filter { tag in
            !candidates.contains { TagText.key($0.name) == TagText.key(tag) }
                && (query.isEmpty || tag.localizedStandardContains(query))
        }.map { TagCandidate(name: $0, isNew: false, taskCount: 0, noteCount: 0) }
        return missing + candidates
    }

    private func selected(_ tag: String) -> Bool { tags.contains { TagText.key($0) == TagText.key(tag) } }
    private func toggle(_ tag: String) {
        if selected(tag) { tags.removeAll { TagText.key($0) == TagText.key(tag) } }
        else { tags = TagText.merge(tags, [tag]); query = "" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("#").foregroundStyle(Palette.accent)
                TextField("搜索或创建标签", text: $query).textFieldStyle(.plain).focused($searching)
                    .onSubmit { if let first = choices.first { toggle(first.name) } }
            }
            .padding(8).background(Palette.card, in: RoundedRectangle(cornerRadius: 7))
            if choices.isEmpty {
                Text("还没有标签").font(.caption).foregroundStyle(Palette.muted).padding(8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(choices) { candidate in
                            Button { toggle(candidate.name) } label: {
                                HStack {
                                    if candidate.isNew { Text("创建").foregroundStyle(Palette.muted) }
                                    Text("#" + candidate.name).lineLimit(1)
                                    Spacer()
                                    if selected(candidate.name) { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
                                }
                                .font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).raisedOnHover(radius: 6)
                            .accessibilityValue(Text(selected(candidate.name) ? "已选中" : "未选中"))
                        }
                    }.padding(3)
                }.frame(height: min(CGFloat(choices.count) * 32 + 6, 250))
            }
        }
        .padding(12).frame(width: 280).disabled(store.isReadOnly)
        .onAppear { searching = true }
    }
}

struct TagSelectionButton: View {
    @ObservedObject var store: JournalStore
    @Binding var tags: [String]
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: { MetadataSymbol(symbol: "#", active: !tags.isEmpty) }
            .buttonStyle(.plain).raisedOnHover(radius: 5)
            .help("标签").accessibilityLabel("标签")
            .popover(isPresented: $showing, arrowEdge: .bottom) { TagSelectionPopover(store: store, tags: $tags) }
            .disabled(store.isReadOnly)
    }
}

struct TodoDraftTagButton: View {
    @ObservedObject var store: JournalStore
    @Binding var text: String

    var body: some View {
        TagSelectionButton(store: store, tags: Binding(get: { TagText.inlineTags(in: text) }, set: {
            text = TagText.replacingTags(in: text, with: $0)
        }))
    }
}

struct EntryMetadataButtons: View {
    @ObservedObject var store: JournalStore
    let log: DailyLogEntry
    let date: Date

    private var live: DailyLogEntry { store.entry(for: date).logs.first { $0.id == log.id } ?? log }

    var body: some View {
        HStack(spacing: 0) {
            TagSelectionButton(store: store, tags: Binding(get: { live.tags }, set: { tags in
                store.updateLogTags(add: tags, remove: live.tags.filter { old in !tags.contains { TagText.key($0) == TagText.key(old) } }, forLogs: [log.id])
            }))
            LinkPickerButton(store: store, current: live.taskID, allowsNone: !live.focus, contextTags: live.tags, pick: {
                store.setLogTask($0, forLog: log.id, on: date)
            }) { MetadataSymbol(symbol: "@", active: live.taskID != nil) }
                .raisedOnHover(radius: 5).help("选择关联的待办").accessibilityLabel("选择关联的待办")
        }.fixedSize().disabled(store.isReadOnly)
    }
}
