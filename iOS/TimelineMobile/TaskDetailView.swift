import SwiftUI
import TimelineCore

/// 一个待办：标题、截止日期、优先级、标签，下面是它的笔记和工作板。
struct TaskDetailView: View {
    @ObservedObject var store: JournalStore
    let id: UUID
    @State private var title = ""
    @State private var tags = ""
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    private var item: ScheduledTask? { store.locate(id) }

    var body: some View {
        if let item {
            Form {
                Section {
                    TextField("标题", text: $title, axis: .vertical)
                        .onSubmit { commitTitle(item) }
                    TextField("标签（空格分隔）", text: $tags)
                        .textInputAutocapitalization(.never)
                        .onSubmit { commitTags(item) }
                    Toggle("已完成", isOn: Binding(get: { item.task.isDone }, set: { _ in store.toggleTodo(id, on: item.date) }))
                        .disabled(item.task.isDropped)
                }
                Section("安排") {
                    Toggle("截止日期", isOn: Binding(get: { item.task.dueDate != nil }, set: { on in
                        store.setDeadline(id, to: on ? Date() : nil)
                    }))
                    if let due = item.task.dueDate {
                        DatePicker("日期", selection: Binding(get: { due }, set: { store.setDeadline(id, to: $0) }), displayedComponents: .date)
                        Toggle("指定时间", isOn: Binding(get: { item.task.dueHasTime }, set: { on in
                            update(item, due: due, hasTime: on)
                        }))
                        if item.task.dueHasTime {
                            DatePicker("时间", selection: Binding(get: { due }, set: { update(item, due: $0, hasTime: true) }), displayedComponents: .hourAndMinute)
                        }
                    }
                    Picker("重复", selection: Binding(get: { item.task.repeatRule }, set: { rule in
                        store.updateTodo(id, scheduledDate: item.date, dueDate: item.task.dueDate ?? Date(), dueHasTime: item.task.dueHasTime,
                                         reminderMinutes: item.task.reminderMinutes, repeatRule: rule)
                    })) {
                        ForEach(RepeatRule.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("优先级", selection: Binding(get: { item.task.priority }, set: { store.setPriority($0, for: id) })) {
                        ForEach(TaskPriority.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section("笔记") {
                    ForEach(store.notes(for: id).reversed()) { LogRow(store: store, logged: $0, showsTask: false) }
                    HStack(alignment: .bottom) {
                        TextField("记一笔…", text: $note, axis: .vertical).focused($noteFocused)
                        Button { addNote() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                            .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section {
                    if let board = store.board(for: .task(id)) {
                        NavigationLink("工作板") { BoardEditor(store: store, id: board.id) }
                    } else {
                        Button("创建工作板") { store.ensureBoard(for: .task(id)) }
                    }
                }
            }
            .navigationTitle(item.task.number.map { "#\($0)" } ?? "待办")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { load(item) }
            .onChange(of: item.task) { _, _ in if !noteFocused { load(item) } }
            .onDisappear { commitTitle(item); commitTags(item) }
        } else {
            ContentUnavailableView("待办已删除", systemImage: "trash")
        }
    }

    private func load(_ item: ScheduledTask) {
        title = item.task.title
        tags = item.task.tags.map { "#" + $0 }.joined(separator: " ")
    }

    private func commitTitle(_ item: ScheduledTask) {
        guard store.locate(id) != nil, title != item.task.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.renameTodo(id, title: title, on: item.date)
    }

    private func commitTags(_ item: ScheduledTask) {
        guard let current = store.locate(id) else { return }
        let parsed = TagText.parseList(tags)
        guard parsed != current.task.tags else { return }
        store.updateTodo(id, scheduledDate: current.date, dueDate: current.task.dueDate, dueHasTime: current.task.dueHasTime,
                         reminderMinutes: current.task.reminderMinutes, repeatRule: current.task.repeatRule, tags: parsed)
    }

    private func update(_ item: ScheduledTask, due: Date, hasTime: Bool) {
        store.updateTodo(id, scheduledDate: item.date, dueDate: due, dueHasTime: hasTime,
                         reminderMinutes: item.task.reminderMinutes, repeatRule: item.task.repeatRule)
    }

    private func addNote() {
        let parsed = TagText.extract(from: note)
        if (try? store.quickLog(parsed.title, taskID: id, linkDefault: false, tags: parsed.tags, allowInlineTaskReference: false, on: Date())) != nil {
            note = ""
        }
    }
}
