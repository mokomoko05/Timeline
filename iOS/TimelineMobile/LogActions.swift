import SwiftUI
import TimelineCore
import UIKit

/// 长按一条日志 / 笔记的操作，和 Mac 日志的右键菜单对齐：复制文字、编辑、标签、关联待办、打开待办的笔记、删除。
///
/// 每一行只拿到这个对象发起操作，编辑页、确认框和提示放在页面上（`logActionsHost`），一页一份，不是每行一份。
@MainActor
final class LogActions: ObservableObject {
    enum Sheet: Identifiable {
        case edit(JournalStore.LoggedLog)
        case tags(JournalStore.LoggedLog)
        case link(JournalStore.LoggedLog)

        var id: String {
            switch self {
            case .edit(let logged): return "edit-" + logged.id.uuidString
            case .tags(let logged): return "tags-" + logged.id.uuidString
            case .link(let logged): return "link-" + logged.id.uuidString
            }
        }
    }

    @Published var sheet: Sheet?
    @Published var deleting: JournalStore.LoggedLog?
    /// 「打开待办的笔记」：推进任务页。
    @Published var openTask: UUID?
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
                case .edit(let logged): LogEditSheet(store: store, logged: logged)
                case .tags(let logged): LogTagsSheet(store: store, logged: logged)
                case .link(let logged): LogLinkSheet(store: store, logged: logged)
                }
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
            .navigationDestination(item: $actions.openTask) { TaskPage(store: store, id: $0) }
    }
}

/// 长按菜单里的各项。
struct LogMenuItems: View {
    @ObservedObject var store: JournalStore
    let logged: JournalStore.LoggedLog
    let actions: LogActions

    var body: some View {
        let log = logged.log
        Button { actions.copy(log) } label: { Label(log.images.isEmpty ? "复制文字" : "复制文字（不含图片）", systemImage: "doc.on.doc") }
            .disabled(log.copyText == nil)
        if !store.isReadOnly {
            Button { actions.sheet = .edit(logged) } label: { Label("编辑", systemImage: "pencil") }
            Button { actions.sheet = .tags(logged) } label: { Label(log.tags.isEmpty ? "加标签…" : "标签…", systemImage: "tag") }
            Button { actions.sheet = .link(logged) } label: { Label(log.taskID == nil ? "关联待办…" : "更改关联待办…", systemImage: "link") }
        }
        if let id = log.taskID, let task = store.locate(id) {
            Button { actions.openTask = id } label: {
                Label(LF("打开「%@」的笔记", String(TaskText.rendered(task.task.title).characters)), systemImage: "text.bubble")
            }
        }
        if !store.isReadOnly {
            Divider()
            Button(role: .destructive) { actions.deleting = logged } label: { Label("删除", systemImage: "trash") }
        }
    }
}

/// 改一条日志的正文。
private struct LogEditSheet: View {
    @ObservedObject var store: JournalStore
    let logged: JournalStore.LoggedLog
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($focused)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .background(Palette.background)
                .navigationTitle("编辑日志")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            if text != logged.log.text {
                                store.updateLog(logged.id, text: text, on: logged.date)
                                store.save()
                            }
                            dismiss()
                        }
                        .disabled(text.nilIfEmpty == nil && logged.log.images.isEmpty)
                    }
                }
                .onAppear {
                    text = logged.log.text
                    focused = true
                }
        }
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
