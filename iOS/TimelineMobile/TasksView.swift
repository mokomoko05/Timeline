import SwiftUI
import TimelineCore

/// 待办：按「逾期 / 今天 / 明天 / 七天内 / 以后 / 无日期」分组，和 Mac 主界面的时间轴一致。
struct TasksView: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var sync: SyncModel
    @AppStorage("showCompleted") private var showCompleted = false
    @State private var adding = false
    @State private var query = ""

    private struct Group: Identifiable {
        let id: Int
        let title: String
        let tasks: [ScheduledTask]
    }

    private static let groupTitles = [0: "逾期", 1: "今天", 2: "明天", 3: "七天内", 4: "以后", 5: "无截止日期", 7: "已放弃"]

    private var groups: [Group] {
        let now = Date()
        let all = store.tasks(matching: query)
        let open = TaskSortMode.deadline.sorted(all.filter { !$0.task.completed }, now: now)
        var result = Dictionary(grouping: open) { TaskSortMode.group(for: $0.task, now: now) }
            .map { Group(id: $0.key, title: Self.groupTitles[$0.key] ?? "", tasks: $0.value) }
            .sorted { $0.id < $1.id }
        if showCompleted {
            let done = all.filter(\.task.completed).sorted { ($0.task.dueDate ?? $0.date) > ($1.task.dueDate ?? $1.date) }
            if !done.isEmpty { result.append(Group(id: 99, title: "已完成", tasks: Array(done.prefix(100)))) }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.tasks) { item in
                            NavigationLink(value: item.id) { TaskRow(store: store, item: item) }
                                .swipeActions(edge: .leading) {
                                    Button { postpone(item) } label: { Label("推后一天", systemImage: "arrow.turn.down.right") }
                                        .tint(.orange)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { store.deleteTodo(item.id, on: item.date) } label: { Label("删除", systemImage: "trash") }
                                    if !item.task.isDone {
                                        Button { store.dropTodo(item.id, on: item.date) } label: {
                                            Label(item.task.isDropped ? "恢复" : "放弃", systemImage: "xmark.circle")
                                        }.tint(.gray)
                                    }
                                }
                        }
                    }
                }
            }
            .overlay {
                if groups.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "没有待办" : "没有找到", systemImage: "checkmark.circle",
                                           description: Text(query.isEmpty ? "点右上角 + 添加" : ""))
                }
            }
            .searchable(text: $query, prompt: "搜索待办或 #标签")
            .navigationTitle("待办")
            .navigationDestination(for: UUID.self) { TaskDetailView(store: store, id: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Toggle(isOn: $showCompleted) { Image(systemName: "checkmark.circle") }
                        .toggleStyle(.button)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $adding) { AddTaskSheet(store: store) }
            .syncOnRefresh(sync)
        }
    }

    private func postpone(_ item: ScheduledTask) {
        let calendar = JournalDates.calendar
        let base = max(calendar.startOfDay(for: item.task.dueDate ?? Date()), calendar.startOfDay(for: Date()))
        store.setDeadline(item.id, to: calendar.date(byAdding: .day, value: 1, to: base))
    }
}

struct TaskRow: View {
    @ObservedObject var store: JournalStore
    let item: ScheduledTask

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                store.toggleTodo(item.id, on: item.date)
            } label: {
                Image(systemName: item.task.isDone ? "checkmark.circle.fill" : (item.task.isDropped ? "xmark.circle" : "circle"))
                    .font(.title3)
                    .foregroundStyle(item.task.completed ? Color.secondary : item.task.priority.color)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text(TaskText.rendered(item.task.title))
                    .strikethrough(item.task.completed)
                    .foregroundStyle(item.task.completed ? .secondary : .primary)
                HStack(spacing: 8) {
                    if let number = item.task.number { Text("#\(number)") }
                    if let due = item.task.dueDate { Text(TaskFormat.due(due, hasTime: item.task.dueHasTime)) }
                    if item.task.repeatRule != .none { Image(systemName: "repeat") }
                    ForEach(item.task.tags, id: \.self) { Text("#" + $0).foregroundStyle(Color.accentColor) }
                    let notes = store.noteCount(for: item.id)
                    if notes > 0 { Label("\(notes)", systemImage: "note.text") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }
}

enum TaskFormat {
    static func due(_ date: Date, hasTime: Bool) -> String {
        let calendar = JournalDates.calendar
        var text: String
        if calendar.isDateInToday(date) { text = "今天" }
        else if calendar.isDateInTomorrow(date) { text = "明天" }
        else if calendar.isDateInYesterday(date) { text = "昨天" }
        else { text = date.formatted(.dateTime.month().day().weekday(.abbreviated)) }
        if hasTime { text += " " + date.formatted(date: .omitted, time: .shortened) }
        return text
    }
}

extension TaskPriority {
    var color: Color {
        switch self {
        case .urgent: return .red
        case .high: return .orange
        case .normal: return .accentColor
        case .lower: return .teal
        case .low: return .gray
        }
    }
}

/// 新建待办：和 Mac 的快速添加一样识别「明天 3点」之类的日期和 `#标签`；也可以直接选日期。
struct AddTaskSheet: View {
    @ObservedObject var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var hasDue = false
    @State private var due = Date()
    @State private var priority = TaskPriority.normal
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("要做什么？可写「明天 下午3点」「#标签」", text: $text, axis: .vertical)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(add)
                Toggle("截止日期", isOn: $hasDue.animation())
                if hasDue { DatePicker("日期", selection: $due, displayedComponents: .date) }
                Picker("优先级", selection: $priority) {
                    ForEach(TaskPriority.allCases) { Text($0.title).tag($0) }
                }
            }
            .navigationTitle("新待办")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加", action: add).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func add() {
        let today = Date()
        guard let created = store.addParsedTodo(text, on: today, priority: priority) else { return }
        if hasDue { store.setDeadline(created.id, to: due) }
        dismiss()
    }
}
