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

/// 沿用原来的圆角标签多选浮窗；保存后才写回，取消不改变草稿或条目。
struct TagSelectionPopover: View {
    @ObservedObject var store: JournalStore
    @Binding var tags: [String]
    var title: String?
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [String]
    @State private var added: [String] = []
    @State private var draft = ""
    @State private var message: String?
    @FocusState private var typing: Bool

    init(store: JournalStore, tags: Binding<[String]>, title: String? = nil) {
        self.store = store
        self._tags = tags
        self.title = title
        _selected = State(initialValue: tags.wrappedValue)
    }

    /// 可选的标签：库里已有的（最近用过的在前）、这个待办自己的，以及刚输入的新标签。
    private var choices: [String] {
        TagText.merge(TagText.merge(tags, store.allTags().map(\.name)), added)
    }

    private func isSelected(_ tag: String) -> Bool { selected.contains { TagText.key($0) == TagText.key(tag) } }

    private func toggle(_ tag: String) {
        if isSelected(tag) { selected.removeAll { TagText.key($0) == TagText.key(tag) } } else { selected.append(tag) }
        message = nil
    }

    @discardableResult
    private func commitDraft() -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        let tags = TagText.parseList(text)
        guard !tags.isEmpty else {
            message = "标签不能含空格，也不能是纯数字（#3 表示任务编号）"
            return false
        }
        for tag in tags {
            // 和已有标签只差大小写时，沿用已有写法。
            let existing = choices.first { TagText.key($0) == TagText.key(tag) } ?? tag
            if !choices.contains(existing) { added.append(existing) }
            if !isSelected(existing) { selected.append(existing) }
        }
        draft = ""
        message = nil
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("标签").font(.headline)
                if let title { Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            if choices.isEmpty {
                Text("还没有标签").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    FlowLayout(spacing: 6) {
                        ForEach(choices, id: \.self) { tag in
                            Button { toggle(tag) } label: { TagChip(name: tag, highlighted: isSelected(tag)) }
                                .buttonStyle(.plain).raisedOnHover(radius: 7)
                                .accessibilityLabel("#\(tag)").accessibilityValue(Text(isSelected(tag) ? "已选中" : "未选中"))
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 190)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "plus").foregroundStyle(Palette.muted)
                    TextField("新标签…", text: $draft)
                        .textFieldStyle(.plain).focused($typing).onSubmit { commitDraft() }
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 7))
                if let message { Text(LocalizedStringKey(message)).font(.caption).foregroundStyle(.orange) }
            }
            HStack {
                Text(selected.isEmpty ? AppLocalized("未选标签") : AppLocalizedFormat("已选 %lld 个", selected.count)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    guard commitDraft() else { return }
                    tags = selected
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(store.isReadOnly)
            }
        }
        .padding(18).frame(width: 360)
        .disabled(store.isReadOnly)
        .onAppear { typing = false }
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
