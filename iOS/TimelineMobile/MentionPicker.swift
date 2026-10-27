import SwiftUI
import TimelineCore
import UIKit

/// 输入框里能触发补全的符号：`@` 关联待办，`#` 选标签。和 Mac 的快速日志一样。
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
    let trigger: MentionTrigger

    static let maxQuery = 24

    static func find(in text: String, caret: Int) -> MentionToken? {
        let ns = text as NSString
        guard caret >= 1, caret <= ns.length else { return nil }
        var index = caret
        // 从光标往回找符号，碰到空白就算没有；最多看 maxQuery 个字，长文里不会一路扫到开头。
        while index > 0, caret - index <= maxQuery + 1 {
            let unit = ns.character(at: index - 1)
            if let trigger = [MentionTrigger.task, .tag].first(where: { $0.units.contains(unit) }) {
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

/// 补全的状态。输入框（`AutoFocusTextView`）每次改字、挪光标时报给它；只有列表订阅它，
/// 所以打字时列表以外的界面不会因为它重算。候选来自 `provider`（同一个查询词只算一次）。
@MainActor
final class MentionModel: ObservableObject {
    static let limit = 8

    @Published private(set) var token: MentionToken?
    @Published private(set) var results: [MentionItem] = []

    var provider: (MentionTrigger, String) -> [MentionItem] = { _, _ in [] }
    /// 选中一项之后。`@xxx` / `#xxx` 已经从输入框里删掉了。
    var onPick: (MentionItem) -> Void = { _ in }
    /// 输入框：删掉选中的词、插入符号、收回焦点都要用它。
    weak var textView: UITextView?
    /// 输入框改了字（不是打字改的，比如删掉选中的词）后通知绑定的文字。
    var textEdited: () -> Void = {}

    var isActive: Bool { token != nil && !results.isEmpty }

    /// 输入框的字或光标变了。
    func update(_ view: UITextView) {
        let selected = view.selectedRange
        let next = selected.length == 0 ? MentionToken.find(in: view.text, caret: selected.location) : nil
        guard next != token else { return }
        let queryChanged = next?.query != token?.query || next?.trigger != token?.trigger
        token = next
        if let next {
            if queryChanged {
                let start = CACurrentMediaTime()
                results = Array(provider(next.trigger, next.query).prefix(Self.limit))
                PerfProbe.lap("候选「\(next.query)」\(Int((CACurrentMediaTime() - start) * 1000)) ms")
            }
        } else if !results.isEmpty {
            results = []
        }
    }

    func pick(_ item: MentionItem) {
        guard let token else { return }
        remove(token.range)
        self.token = nil
        results = []
        onPick(item)
    }

    /// 关掉列表：把还没写完的 `@xxx` / `#xxx` 一起删掉。
    func dismiss() {
        guard let token else { return }
        remove(token.range)
        self.token = nil
        results = []
    }

    /// 按钮「关联待办」「标签」：在光标处插入符号，弹出同一个列表，接着打字就是搜索。
    func start(_ trigger: MentionTrigger) {
        guard let view = textView else { return }
        if token?.trigger == trigger { dismiss(); return }
        if let token { remove(token.range) }
        if !view.isFirstResponder { view.becomeFirstResponder() }
        let text = view.text as NSString
        let caret = view.selectedRange.location
        let needsSpace = caret > 0 && caret <= text.length
            && !CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(text.character(at: caret - 1)) ?? " ")
        view.insertText((needsSpace ? " " : "") + String(trigger.rawValue))
    }

    private func remove(_ range: NSRange) {
        guard let view = textView, NSMaxRange(range) <= (view.text as NSString).length else { return }
        view.unmarkText()
        guard let start = view.position(from: view.beginningOfDocument, offset: range.location),
              let end = view.position(from: start, offset: range.length),
              let textRange = view.textRange(from: start, to: end) else { return }
        view.replace(textRange, withText: "")
        textEdited()
    }
}

/// 常用的候选来源：待办按上下文标签排序（已完成的排后面），标签排除已选的。
@MainActor
enum MentionProviders {
    static func make(store: JournalStore, chosenTags: @escaping () -> [String]) -> (MentionTrigger, String) -> [MentionItem] {
        { [store] trigger, query in
            switch trigger {
            case .task:
                return Array(store.linkCandidates(query: query, includeCompleted: true, contextTags: chosenTags()).prefix(MentionModel.limit)).map(MentionItem.task)
            case .tag:
                return store.tagCandidates(query: query, excluding: chosenTags(), limit: MentionModel.limit).map(MentionItem.tag)
            }
        }
    }
}

/// 输入卡里的候选列表：贴在输入框上面，一行一个，手指好点。最多露出四行，多的在里面滚。
struct MentionList: View {
    @ObservedObject var model: MentionModel
    let store: JournalStore
    static let rowHeight: CGFloat = 48

    var body: some View {
        if model.isActive, let token = model.token {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(token.trigger == .task ? "关联待办" : "加标签")
                        .font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                    if !token.query.isEmpty {
                        Text("“\(token.query)”").font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                    Spacer()
                    Button { model.dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.body).foregroundStyle(Palette.muted.opacity(0.7))
                            .frame(width: 32, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }
                .padding(.leading, 12).padding(.top, 4)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.results) { item in
                            Button { model.pick(item) } label: { row(item) }
                                .buttonStyle(MentionRowStyle())
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: Self.rowHeight * min(4.5, CGFloat(model.results.count)))
            }
            .padding(.bottom, 4)
            .background(Palette.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.line.opacity(0.6), lineWidth: 0.5))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(token.trigger == .tag ? "标签候选" : "关联待办候选")
            // 截图检查用：选第一个候选。
            .onReceive(NotificationCenter.default.publisher(for: PerfProbe.action)) { note in
                if note.object as? String == "mentionPick", let first = model.results.first { model.pick(first) }
            }
        }
    }

    @ViewBuilder private func row(_ item: MentionItem) -> some View {
        switch item {
        case .task(let task): taskRow(task)
        case .tag(let tag): tagRow(tag)
        }
    }

    private func taskRow(_ item: ScheduledTask) -> some View {
        let task = item.task
        let meta = [task.number.map { "#\($0)" }, task.dueDate.map { DayText.relative($0) ?? DayText.short($0) }].compactMap { $0 }
            + task.tags.prefix(2).map { "#" + $0 }
        return HStack(spacing: 10) {
            Circle().fill(task.completed ? Palette.muted.opacity(0.5) : task.priority.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(TaskText.rendered(task.title).characters))
                    .font(.subheadline.weight(.medium)).lineLimit(1)
                    .foregroundStyle(task.completed ? Palette.muted : Palette.ink)
                    .strikethrough(task.isDone, color: Palette.muted)
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · ")).font(.caption2).foregroundStyle(Palette.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if item.id == store.focusTaskID { Image(systemName: "timer").foregroundStyle(Palette.success) }
            if item.id == store.pinnedTask?.id { Image(systemName: "pin.fill").foregroundStyle(Palette.accent) }
            if task.isDone { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success) }
            else if task.isDropped { Image(systemName: "xmark.circle").foregroundStyle(Palette.muted) }
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((task.number.map { "#\($0) " } ?? "") + task.title)
    }

    private func tagRow(_ tag: TagCandidate) -> some View {
        HStack(spacing: 10) {
            Image(systemName: tag.isNew ? "plus" : "number")
                .font(.caption.weight(.semibold)).foregroundStyle(Palette.note)
                .frame(width: 24, height: 24)
                .background(Palette.note.opacity(0.12), in: Circle())
            Text(tag.name).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink).lineLimit(1)
            Spacer(minLength: 4)
            Text(tag.isNew ? L("新建标签") : (tag.taskCount > 0 || tag.noteCount > 0 ? LF("%lld 待办 · %lld 笔记", tag.taskCount, tag.noteCount) : L("空标签")))
                .font(.caption2).foregroundStyle(Palette.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((tag.isNew ? L("新建标签") + " #" : "#") + tag.name)
    }
}

/// 候选行：整行可点，按下时垫一层浅色。
private struct MentionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .frame(height: MentionList.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Palette.accent.opacity(0.1) : .clear)
    }
}
