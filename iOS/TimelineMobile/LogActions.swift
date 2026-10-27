import SwiftUI
import TimelineCore
import UIKit

/// 长按一条日志 / 笔记的操作，和 Mac 日志的右键菜单对齐：复制文字、编辑、标签、关联待办、打开待办的笔记、删除。
///
/// 每一行只拿到这个对象发起操作，编辑页、确认框和提示放在页面上（`logActionsHost`），一页一份，不是每行一份。
@MainActor
final class LogActions: ObservableObject {
    enum Sheet: Identifiable {
        case tags(JournalStore.LoggedLog)
        case link(JournalStore.LoggedLog)
        case select(JournalStore.LoggedLog)

        var id: String {
            switch self {
            case .tags(let logged): return "tags-" + logged.id.uuidString
            case .link(let logged): return "link-" + logged.id.uuidString
            case .select(let logged): return "select-" + logged.id.uuidString
            }
        }
    }

    @Published var sheet: Sheet?
    /// 改正文用输入卡，不走面板。输入卡挂在整个应用最上层（盖住导航栏、搜索框和浮动按钮），见 `LogEditing`。
    var editing: JournalStore.LoggedLog? {
        get { LogEditing.shared.item }
        set { LogEditing.shared.item = newValue }
    }
    @Published var deleting: JournalStore.LoggedLog?
    /// 「打开待办的笔记」：推进任务页。
    @Published var openTask: NotesView.Destination?
    let toast = Toast()

    func copy(_ log: DailyLogEntry) {
        guard let text = log.copyText else { return }
        UIPasteboard.general.string = text
        toast.show(L("已复制文字"))
    }
}

private struct LogActionsKey: EnvironmentKey {
    static let defaultValue: LogActions? = nil
}

extension EnvironmentValues {
    var logActions: LogActions? {
        get { self[LogActionsKey.self] }
        set { self[LogActionsKey.self] = newValue }
    }
}

extension View {
    /// 页面上挂一份日志操作：编辑页、标签页、关联待办、删除确认和提示。要放在 `NavigationStack` 里面。
    func logActionsHost(_ store: JournalStore) -> some View {
        modifier(LogActionsHost(store: store))
    }
}

private struct LogActionsHost: ViewModifier {
    @ObservedObject var store: JournalStore
    @StateObject private var actions = LogActions()

    func body(content: Content) -> some View {
        content
            .environment(\.logActions, actions)
            .overlay(alignment: .bottom) { ToastView(toast: actions.toast).padding(.bottom, 80) }
            .sheet(item: $actions.sheet) { sheet in
                switch sheet {
                case .tags(let logged): LogTagsSheet(store: store, logged: logged)
                case .link(let logged): LogLinkSheet(store: store, logged: logged)
                case .select(let logged): LogSelectSheet(logged: logged)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: PerfProbe.action)) { note in
                // 性能 / 截图检查：打开最长那条日志的「选择文字」。
                if note.object as? String == "selectText", actions.sheet == nil,
                   let logged = store.allLogs().max(by: { $0.log.text.count < $1.log.text.count }) { actions.sheet = .select(logged) }
                if note.object as? String == "editLog", actions.editing == nil,
                   let logged = store.allLogs().max(by: { $0.log.text.count < $1.log.text.count }) { actions.editing = logged }
                if note.object as? String == "closeLogEditor" { actions.editing = nil }
            }
            .confirmationDialog("删除这条日志？", isPresented: Binding(get: { actions.deleting != nil }, set: { if !$0 { actions.deleting = nil } }),
                                titleVisibility: .visible, presenting: actions.deleting) { logged in
                Button("删除", role: .destructive) {
                    store.deleteLog(logged.id, on: logged.date)
                    store.save()
                    actions.toast.show(L("已删除"))
                }
            } message: { logged in
                if let text = logged.log.copyText { Text(String(text.prefix(80))) }
            }
            .navigationDestination(item: $actions.openTask) { destination in
                if case .task(let id, let reveal) = destination { TaskPage(store: store, id: id, reveal: reveal) }
            }
    }
}

/// 长按菜单里的各项。
struct LogMenuItems: View {
    @ObservedObject var store: JournalStore
    let logged: JournalStore.LoggedLog
    let actions: LogActions

    var body: some View {
        ForEach(Array(actions.menu(store: store, logged: logged).enumerated()), id: \.offset) { _, item in
            if item.separated { Divider() }
            Button(role: item.destructive ? .destructive : nil, action: item.run) { Label(item.title, systemImage: item.symbol) }
                .disabled(item.disabled)
        }
    }
}

extension LogActions {
    /// 长按菜单的一项。图片的 SwiftUI 菜单（`LogMenuItems`）和文字的 UIKit 菜单（`LongTextMenu`）都从这里出，两边一样。
    struct MenuItem {
        let title: String
        let symbol: String
        var disabled = false
        var destructive = false
        /// 和上一项之间画一条分隔线。
        var separated = false
        let run: () -> Void
    }

    func menu(store: JournalStore, logged: JournalStore.LoggedLog) -> [MenuItem] {
        let log = logged.log
        var items = [
            MenuItem(title: L(log.images.isEmpty ? "复制文字" : "复制文字（不含图片）"), symbol: "doc.on.doc", disabled: log.copyText == nil) { [self] in copy(log) },
            MenuItem(title: L("选择文字"), symbol: "character.cursor.ibeam", disabled: log.copyText == nil) { [self] in sheet = .select(logged) },
        ]
        if !store.isReadOnly {
            items += [
                MenuItem(title: L("编辑"), symbol: "pencil", disabled: !log.hasEditableText) { [self] in editing = logged },
                MenuItem(title: L(log.tags.isEmpty ? "加标签…" : "标签…"), symbol: "tag") { [self] in sheet = .tags(logged) },
                MenuItem(title: L(log.taskID == nil ? "关联待办…" : "更改关联待办…"), symbol: "link") { [self] in sheet = .link(logged) },
            ]
        }
        if let id = log.taskID, let task = store.locate(id) {
            items.append(MenuItem(title: LF("打开「%@」的笔记", String(TaskText.rendered(task.task.title).characters)), symbol: "text.bubble") { [self] in
                openTask = .task(id, reveal: logged.id)
            })
        }
        if !store.isReadOnly {
            items.append(MenuItem(title: L("删除"), symbol: "trash", destructive: true, separated: true) { [self] in deleting = logged })
        }
        return items
    }
}

/// 改一条日志的正文：和工作板一样所见即所得（只有光标所在的元素露出 Markdown 标记），输入卡按内容长高，太长就在里面滚动。
/// 收起（点暗处、「完成」）时写回；「取消」放弃这次的修改。
@MainActor
final class LogEditing: ObservableObject {
    static let shared = LogEditing()
    @Published var item: JournalStore.LoggedLog?
}

extension View {
    /// 改日志的输入卡：挂在整个应用最上层。
    func logEditorHost(_ store: JournalStore) -> some View {
        modifier(LogEditorHost(store: store))
    }
}

private struct LogEditorHost: ViewModifier {
    let store: JournalStore
    @ObservedObject private var editing = LogEditing.shared

    func body(content: Content) -> some View {
        content.floatingEditor(item: $editing.item) { LogEditSheet(store: store, logged: $0).id($0.id) }
    }
}

private struct LogEditSheet: View {
    @ObservedObject var store: JournalStore
    let logged: JournalStore.LoggedLog
    @Environment(\.closeEditor) private var closeEditor
    @StateObject private var session: BoardWebSession

    init(store: JournalStore, logged: JournalStore.LoggedLog) {
        self.store = store
        self.logged = logged
        _session = StateObject(wrappedValue: BoardWebSession(store: store, document: .log(id: logged.id, date: logged.date)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorCardHeader(title: "编辑日志", confirm: "完成", canConfirm: true, cancel: {
                session.discard()
                closeEditor?()
            }) {
                session.commit()
                closeEditor?()
            }
            BoardWebEditor(session: session)
                .frame(height: min(max(session.contentHeight ?? 120, 96), UIScreen.main.bounds.height * 0.32))
                .animation(.snappy(duration: 0.15), value: session.contentHeight)
        }
        .onAppear {
            session.beginEditing()
            if PerfProbe.typing == "log" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { session.runTypingTest(PerfProbe.typingText) }
            }
        }
        .onDisappear { session.commit() }
    }
}

/// 「选择文字」：整条日志放进一个只读、可选中的文本框，拖动选择手柄复制其中一段。
/// 默认显示排好版的样子（复制出来是排版后的文字，粘到备忘录之类还带着加粗）；右上角可以换成 Markdown 原文。
private struct LogSelectSheet: View {
    let logged: JournalStore.LoggedLog
    @Environment(\.dismiss) private var dismiss
    @State private var source = false

    var body: some View {
        let text = logged.log.copyText ?? ""
        NavigationStack {
            SelectableTextView(text: source ? Self.plain(text) : RichText.selectable(text, size: 17))
                .ignoresSafeArea(.container, edges: .bottom)
                .background(Palette.background)
                .navigationTitle("选择文字")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button(source ? "显示排版" : "显示原文") { source.toggle() }
                    }
                }
        }
        .presentationDetents([.large])
    }

    private static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular),
                                                       .foregroundColor: UIColor(Palette.ink)])
    }
}

/// 只读、可选中的文本框：系统的选择手柄、放大镜、拷贝 / 全选 / 查询。
private struct SelectableTextView: UIViewRepresentable {
    let text: NSAttributedString

    func makeUIView(context: Context) -> LaidOutTextView {
        // TextKit 2 只排看得到的那段、其余按估算高度：上万字的日志一滚动就边排边改总高度，每帧都卡。
        // 用 TextKit 1，宽度定下来时一次排完整篇（一万多字几毫秒），滚动时只需要画。
        let view = LaidOutTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 40, right: 16)
        view.alwaysBounceVertical = true
        view.linkTextAttributes = [.foregroundColor: UIColor(Palette.accent)]
        return view
    }

    func updateUIView(_ view: LaidOutTextView, context: Context) {
        guard view.attributedText != text else { return }
        view.attributedText = text
        view.relayout()
        view.selectedRange = NSRange(location: 0, length: 0)
    }
}

/// 宽度变了（或换了文字）就把全文排完，总高度一开始就是准的。
private final class LaidOutTextView: UITextView {
    private var laidOutWidth: CGFloat = 0

    func relayout() {
        laidOutWidth = 0
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.width != laidOutWidth else { return }
        laidOutWidth = bounds.width
        layoutManager.ensureLayout(for: textContainer)
    }
}

/// 一条日志的标签：已有的标签点一下切换，也可以输入新标签。
private struct LogTagsSheet: View {
    @ObservedObject var store: JournalStore
    let logged: JournalStore.LoggedLog
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [String] = []
    @State private var all: [String] = []
    @State private var newTag = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("新标签", text: $newTag)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit(addNew)
                        Button("添加", action: addNew).disabled(TagText.normalize(newTag) == nil)
                    }
                }
                Section("标签") {
                    ForEach(all, id: \.self) { tag in
                        Button {
                            if let index = selected.firstIndex(where: { TagText.key($0) == TagText.key(tag) }) { selected.remove(at: index) }
                            else { selected.append(tag) }
                        } label: {
                            HStack {
                                Text("#" + tag).foregroundStyle(Palette.ink)
                                Spacer()
                                if selected.contains(where: { TagText.key($0) == TagText.key(tag) }) {
                                    Image(systemName: "checkmark").foregroundStyle(Palette.accent)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { save(); dismiss() } }
            }
            .onAppear {
                selected = logged.log.tags
                all = TagText.merge(logged.log.tags, store.allTags().map(\.name))
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func addNew() {
        guard let name = TagText.normalize(newTag) else { return }
        if !all.contains(where: { TagText.key($0) == TagText.key(name) }) { all.insert(name, at: 0) }
        if !selected.contains(where: { TagText.key($0) == TagText.key(name) }) { selected.append(name) }
        newTag = ""
    }

    private func save() {
        let before = logged.log.tags
        let removed = before.filter { tag in !selected.contains { TagText.key($0) == TagText.key(tag) } }
        let added = selected.filter { tag in !before.contains { TagText.key($0) == TagText.key(tag) } }
        guard !added.isEmpty || !removed.isEmpty else { return }
        for tag in added { _ = store.createTag(tag) }
        store.updateLogTags(add: added, remove: removed, forLogs: [logged.id])
        store.save()
    }
}

/// 改一条日志关联的待办：可搜索，最上面是「不关联」。
private struct LogLinkSheet: View {
    @ObservedObject var store: JournalStore
    let logged: JournalStore.LoggedLog
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [TaskChoice] = []
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    row(nil, title: L("不关联"))
                }
                ForEach(choices.filter { query.isEmpty || $0.title.localizedStandardContains(query) }) { row($0.id, title: $0.title) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索待办")
            .navigationTitle("关联待办")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onAppear { choices = TaskChoice.open(in: store, including: logged.log.taskID, limit: 200) }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ id: UUID?, title: String) -> some View {
        Button {
            if id != logged.log.taskID {
                store.setLogTask(id, forLog: logged.id, on: logged.date)
                store.save()
            }
            dismiss()
        } label: {
            HStack {
                Text(title).foregroundStyle(id == nil ? Palette.muted : Palette.ink).lineLimit(2)
                Spacer()
                if id == logged.log.taskID { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
            }
        }
    }
}
