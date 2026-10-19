import SwiftUI
import DayleafCore

/// 自动换行的横向排列：标签一行放不下就折到下一行。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (positions, CGSize(width: widest, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = arrange(subviews, width: bounds.width)
        for (view, point) in zip(subviews, laid.positions) {
            view.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

/// 圆角矩形标签：`highlighted` 表示选中。
struct TagChip: View {
    @Environment(\.typography) private var typography
    let name: String
    var highlighted = false
    /// 批量时只有一部分日志带这个标签：描边但不填充。
    var partial = false
    var size: CGFloat = 12

    var body: some View {
        Text("#" + name)
            .font(.system(size: typography.pt(size), weight: highlighted ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(highlighted ? Palette.onAccent : (partial ? Palette.accent : Palette.ink))
            .background(highlighted ? Palette.accent : Palette.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(highlighted ? Color.clear : (partial ? Palette.accent : Palette.line), lineWidth: partial ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// 待办行里的一排标签（点一下打开这个标签名下的笔记）。
struct TaskTagLine: View {
    @Environment(\.typography) private var typography
    let tags: [String]
    var fontSize: CGFloat = 10

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                Button { NotificationCenter.default.post(name: .dayleafOpenTag, object: tag) } label: {
                    Text("#" + tag).font(.system(size: typography.pt(fontSize))).lineLimit(1)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Palette.soft, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain).foregroundStyle(Palette.accent)
                .help("查看 #\(tag) 名下的笔记")
            }
        }
    }
}

/// 给一个待办选标签：已有的标签是圆角矩形，选中的高亮，点一下切换；也可以输入新标签。
struct TagPickerView: View {
    @ObservedObject var store: JournalStore
    let task: Todo
    var body: some View {
        TagSelectionPopover(store: store, tags: Binding(
            get: { store.locate(task.id)?.task.tags ?? task.tags },
            set: { store.setTags(task.id, $0) }), title: String(TaskText.rendered(task.title).characters))
    }
}

/// 给选中的一批日志加、去标签。圆角矩形的三种状态：高亮 = 全部都有，描边 = 部分有，普通 = 都没有。点一下：都没有 / 部分有 → 全部加上；全部都有 → 全部去掉。
struct LogBatchTagView: View {
    @ObservedObject var store: JournalStore
    let logIDs: Set<UUID>
    @Environment(\.dismiss) private var dismiss
    @State private var toAdd: [String] = []
    @State private var toRemove: Set<String> = []
    @State private var draft = ""
    @State private var message: String?

    /// 选中日志自己的标签：key → (名字, 有多少条带它)。
    private var owned: [String: (name: String, count: Int)] {
        var result: [String: (name: String, count: Int)] = [:]
        for item in store.allLogs(includeFocus: true) where logIDs.contains(item.log.id) {
            for tag in item.log.tags {
                let key = TagText.key(tag)
                result[key] = (result[key]?.name ?? tag, (result[key]?.count ?? 0) + 1)
            }
        }
        return result
    }

    private var choices: [String] {
        let have = owned
        let own = have.values.sorted { $0.count > $1.count }.map(\.name)
        return TagText.merge(TagText.merge(own, toAdd), store.allTags().map(\.name))
    }

    private func state(_ tag: String) -> (full: Bool, partial: Bool) {
        let key = TagText.key(tag)
        if toAdd.contains(where: { TagText.key($0) == key }) { return (true, false) }
        if toRemove.contains(key) { return (false, false) }
        let count = owned[key]?.count ?? 0
        return (count == logIDs.count && count > 0, count > 0 && count < logIDs.count)
    }

    private func toggle(_ tag: String) {
        let key = TagText.key(tag)
        message = nil
        if toAdd.contains(where: { TagText.key($0) == key }) { toAdd.removeAll { TagText.key($0) == key }; return }
        if toRemove.contains(key) { toRemove.remove(key); return }
        let count = owned[key]?.count ?? 0
        if count == logIDs.count, count > 0 { toRemove.insert(key) } else { toAdd.append(tag) }
    }

    private func commitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let tags = TagText.parseList(text)
        guard !tags.isEmpty else { message = "标签不能含空格，也不能是纯数字（#3 表示任务编号）"; return }
        for tag in tags {
            let key = TagText.key(tag)
            toRemove.remove(key)
            let existing = choices.first { TagText.key($0) == key } ?? tag
            if !state(existing).full { toAdd = TagText.merge(toAdd, [existing]) }
        }
        draft = ""
        message = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("给 \(logIDs.count) 条日志加标签").font(.headline)
                Text("实心：全部选中 · 描边：部分选中")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if choices.isEmpty {
                Text("还没有标签").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    FlowLayout(spacing: 6) {
                        ForEach(choices, id: \.self) { tag in
                            let current = state(tag)
                            Button { toggle(tag) } label: { TagChip(name: tag, highlighted: current.full, partial: current.partial) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("#\(tag)")
                                .accessibilityValue(current.full ? "全部日志都有" : (current.partial ? "部分日志有" : "没有"))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 190)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "plus").foregroundStyle(Palette.muted)
                    TextField("新标签…", text: $draft).textFieldStyle(.plain).onSubmit(commitDraft)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 7))
                if let message { Text(LocalizedStringKey(message)).font(.caption).foregroundStyle(.orange) }
            }
            HStack {
                Text("加 \(toAdd.count) · 去 \(toRemove.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    commitDraft()
                    store.updateLogTags(add: toAdd, remove: choices.filter { toRemove.contains(TagText.key($0)) }, forLogs: logIDs)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(store.isReadOnly)
            }
        }
        .padding(18).frame(width: 380)
    }
}
