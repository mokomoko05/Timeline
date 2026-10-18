import AppKit
import SwiftUI
import DayleafCore

/// 输入框里能触发补全的符号：`@` 关联待办，`#` 选标签。
enum MentionTrigger: Character {
    case task = "@"
    case tag = "#"

    /// 半角和全角（中文输入法下打出来的）都认。
    var units: [unichar] {
        switch self {
        case .task: return [0x40, 0xFF20]
        case .tag: return [0x23, 0xFF03]
        }
    }
}

/// 输入框里正在写的 `@xxx` / `#xxx`：符号必须在开头或空白之后，光标紧跟在词后面。
struct MentionToken: Equatable {
    /// 包含符号的整段范围（UTF-16）。
    let range: NSRange
    /// 符号后面写的字（拼音输入法的分隔符 `'` 已去掉）。
    let query: String
    var trigger: MentionTrigger = .task

    static let maxQuery = 24

    static func find(in text: String, caret: Int, triggers: Set<MentionTrigger> = [.task]) -> MentionToken? {
        let ns = text as NSString
        guard caret >= 1, caret <= ns.length else { return nil }
        var index = caret
        while index > 0 {
            let unit = ns.character(at: index - 1)
            if let trigger = triggers.first(where: { $0.units.contains(unit) }) {
                let start = index - 1
                if start > 0, !isSpace(ns.character(at: start - 1)) { return nil }
                let raw = ns.substring(with: NSRange(location: index, length: caret - index))
                guard raw.count <= maxQuery else { return nil }
                return MentionToken(range: NSRange(location: start, length: caret - start),
                                    query: raw.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: ""),
                                    trigger: trigger)
            }
            if isSpace(unit) { return nil }
            index -= 1
        }
        return nil
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

/// 补全列表里的一项。
enum MentionItem: Identifiable {
    case task(ScheduledTask)
    case tag(TagCandidate)

    var id: String {
        switch self {
        case .task(let item): return "task:" + item.id.uuidString
        case .tag(let candidate): return candidate.id
        }
    }
}

/// 补全的状态：输入框（`TaskInput`）负责发现 `@xxx` / `#xxx` 和处理 ↑ ↓ 回车 Tab Esc，候选由所在的界面按上下文提供。
@MainActor
final class MentionState: ObservableObject {
    static let limit = 6

    @Published private(set) var token: MentionToken?
    @Published private(set) var results: [MentionItem] = []
    @Published var selection = 0

    /// 这个输入框响应哪些符号。
    var triggers: Set<MentionTrigger> = [.task]
    /// 按符号和查询词给出候选（调用方带上正在写的标签等上下文）。
    var provider: (MentionTrigger, String) -> [MentionItem] = { _, _ in [] }
    /// 选中一项之后。`@xxx` / `#xxx` 已经从输入框里删掉了。
    var onPick: (MentionItem) -> Void = { _ in }
    /// 输入框注册的「确认当前选择」，列表里点一下也走这里。
    var acceptAction: (() -> Bool)?
    /// 按 Esc 关掉的那个符号（位置）：在它被删掉或重新输入之前不再弹出。
    private var dismissedAt: Int?

    var isActive: Bool { token != nil && !results.isEmpty }

    func update(_ new: MentionToken?) {
        guard let new else {
            dismissedAt = nil
            clear()
            return
        }
        if new.range.location == dismissedAt { clear(); return }
        guard new != token else { return }
        let changed = new.query != token?.query || new.range.location != token?.range.location || new.trigger != token?.trigger
        token = new
        results = Array(provider(new.trigger, new.query).prefix(Self.limit))
        if changed { selection = 0 }
    }

    func move(_ delta: Int) {
        guard isActive else { return }
        selection = (selection + delta + results.count) % results.count
    }

    func dismiss() {
        dismissedAt = token?.range.location
        clear()
    }

    /// 取走当前选中的候选，同时关闭列表。
    func take() -> (token: MentionToken, item: MentionItem)? {
        guard isActive, let token, results.indices.contains(selection) else { return nil }
        let item = results[selection]
        dismissedAt = nil
        clear()
        return (token, item)
    }

    func choose(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selection = index
        _ = acceptAction?()
    }

    private func clear() {
        if token != nil { token = nil }
        if !results.isEmpty { results = [] }
    }
}

/// 常用的候选来源：待办按上下文标签排序，标签排除已选的。
@MainActor
enum MentionProviders {
    static func make(store: JournalStore, contextTags: @escaping () -> [String] = { [] }, chosenTags: @escaping () -> [String] = { [] }) -> (MentionTrigger, String) -> [MentionItem] {
        { [store] trigger, query in
            switch trigger {
            // 已完成、已放弃的也能搜到（排在未完成的后面）。
            case .task: return store.linkCandidates(query: query, includeCompleted: true, contextTags: contextTags()).map(MentionItem.task)
            case .tag: return store.tagCandidates(query: query, excluding: chosenTags()).map(MentionItem.tag)
            }
        }
    }
}

/// 输入框下面的补全列表（`@` 待办、`#` 标签）。
struct MentionList: View {
    @ObservedObject var state: MentionState
    @ObservedObject var store: JournalStore
    /// 正在写的标签等：带这些标签的待办会排前面，并标出来。
    var contextTags: [String] = []

    var body: some View {
        if state.isActive {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(state.results.enumerated()), id: \.element.id) { index, item in
                    row(item).padding(.horizontal, 10).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(index == state.selection ? Palette.soft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .padding(.horizontal, 3)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in state.choose(index) })
                }
                Text("↑ ↓ 选择 · 回车 / Tab 确认 · Esc 取消").font(.system(size: UIScale.pt(10))).foregroundStyle(Palette.muted)
                    .padding(.horizontal, 10).padding(.vertical, 4)
            }
            .padding(.vertical, 3)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .accessibilityElement(children: .contain).accessibilityLabel(state.token?.trigger == .tag ? "标签候选" : "关联待办候选")
        }
    }

    @ViewBuilder
    private func row(_ item: MentionItem) -> some View {
        switch item {
        case .task(let task): taskRow(task)
        case .tag(let tag): tagRow(tag)
        }
    }

    private func taskRow(_ item: ScheduledTask) -> some View {
        let isFocus = item.id == store.focusTaskID
        let isPinned = item.id == store.pinnedTask?.id
        let shared = item.task.tags.filter { tag in contextTags.contains { TagText.matches(tag, query: $0) || TagText.matches($0, query: tag) } }
        return HStack(spacing: 6) {
            Text(item.task.number.map { "#\($0)" } ?? "").font(.system(size: UIScale.pt(11), design: .monospaced))
                .foregroundStyle(Palette.muted).frame(width: 34, alignment: .leading)
            Text(String(TaskText.rendered(item.task.title, alias: item.task.calendarName).characters))
                .font(.system(size: UIScale.pt(13))).lineLimit(1)
                .foregroundStyle(item.task.completed ? Palette.muted : Palette.ink)
                .strikethrough(item.task.isDone, color: Palette.muted)
            if item.task.isDropped {
                Label("已放弃", systemImage: "xmark.circle.fill").labelStyle(.titleAndIcon).font(.system(size: UIScale.pt(10))).foregroundStyle(Palette.muted)
            } else if item.task.isDone {
                Label("已完成", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).font(.system(size: UIScale.pt(10))).foregroundStyle(Palette.success)
            }
            if isFocus { Image(systemName: "timer").foregroundStyle(Palette.success).font(.system(size: UIScale.pt(10))) }
            if isPinned { Image(systemName: "pin.fill").foregroundStyle(Palette.accent).font(.system(size: UIScale.pt(10))) }
            Spacer(minLength: 4)
            ForEach(Array((shared.isEmpty ? Array(item.task.tags.prefix(2)) : shared).prefix(2)), id: \.self) { tag in
                Text("#" + tag).font(.system(size: UIScale.pt(10))).lineLimit(1)
                    .foregroundStyle(shared.contains(tag) ? Palette.accent : Palette.muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((item.task.number.map { "#\($0) " } ?? "") + item.task.title)
        .accessibilityAddTraits(.isButton)
    }

    private func tagRow(_ tag: TagCandidate) -> some View {
        HStack(spacing: 6) {
            Image(systemName: tag.isNew ? "plus.circle" : "number").font(.system(size: UIScale.pt(11))).foregroundStyle(Palette.muted)
                .frame(width: 20, alignment: .leading)
            Text("#" + tag.name).font(.system(size: UIScale.pt(13))).foregroundStyle(Palette.accent).lineLimit(1)
            Spacer(minLength: 4)
            if tag.isNew {
                Text("新建标签").font(.system(size: UIScale.pt(10))).foregroundStyle(Palette.muted)
            } else if tag.taskCount > 0 || tag.noteCount > 0 {
                Text("\(tag.taskCount) 个待办 · \(tag.noteCount) 条笔记").font(.system(size: UIScale.pt(10))).foregroundStyle(Palette.muted)
            } else {
                Text("空标签").font(.system(size: UIScale.pt(10))).foregroundStyle(Palette.muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((tag.isNew ? "新建标签 #" : "标签 #") + tag.name)
        .accessibilityAddTraits(.isButton)
    }
}
