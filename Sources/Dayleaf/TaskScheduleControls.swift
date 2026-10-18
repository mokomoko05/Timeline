import SwiftUI
import DayleafCore

struct PriorityMark: View {
    let priority: TaskPriority
    private var color: Color {
        switch priority {
        case .high: return .orange
        case .normal: return Palette.muted
        case .low: return .blue
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .help(LocalizedStringKey(priority.title))
            .accessibilityLabel(LocalizedStringKey(priority.title))
    }
}

struct TaskPriorityButton: View {
    @ObservedObject var store: JournalStore
    let task: Todo
    var body: some View {
        Button {
            guard let current = store.locate(task.id)?.task else { return }
            let next: TaskPriority
            switch current.priority {
            case .normal: next = .high
            case .high: next = .low
            case .low: next = .normal
            }
            store.setPriority(next, for: task.id)
        } label: {
            PriorityMark(priority: task.priority)
                .frame(width: 18, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(store.isReadOnly)
        .raisedOnHover(radius: 4, enabled: !store.isReadOnly)
        .help(AppLocalizedFormat("%@ · 点击切换", AppLocalized(task.priority.title)))
        .accessibilityLabel(LocalizedStringKey(task.priority.title))
        .accessibilityHint("点击切换优先级")
    }
}

struct TaskDeadlineButton: View {
    @ObservedObject var store: JournalStore
    let task: Todo
    var compact = false
    @State private var showing = false

    static func time(_ date: Date) -> String {
        let parts = JournalDates.calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    var body: some View {
        if let due = task.dueDate {
            Button { showing = true } label: {
                Text(label(due)).font(.system(size: compact ? 9 : 10, weight: .medium, design: .monospaced))
                    .lineLimit(1).fixedSize()
                    .foregroundStyle(!task.completed && task.effectiveDeadline.map({ $0 < Date() }) == true ? Palette.deadline : Palette.muted)
                    .padding(.horizontal, compact ? 2 : 4).padding(.vertical, 2)
            }
            .buttonStyle(.plain).raisedOnHover(radius: 4).disabled(store.isReadOnly)
            .help("修改截止时间")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                TaskDeadlineEditor(store: store, task: task, close: { showing = false })
            }
        }
    }

    private func label(_ due: Date) -> String {
        if compact { return Self.time(due) }
        if task.dueHasTime {
            return JournalDates.calendar.isDateInToday(due)
                ? AppLocalizedFormat("%@ 前", Self.time(due)) : due.relativeLabel + " " + Self.time(due)
        }
        return due.relativeLabel
    }
}

private struct TaskDeadlineEditor: View {
    @ObservedObject var store: JournalStore
    let task: Todo
    let close: () -> Void
    @State private var due: Date
    @State private var timed: Bool
    init(store: JournalStore, task: Todo, close: @escaping () -> Void) {
        self.store = store; self.task = task; self.close = close
        _due = State(initialValue: task.dueDate ?? Date())
        _timed = State(initialValue: task.dueHasTime)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker("截止日期", selection: $due, displayedComponents: .date)
            HStack {
                Picker("截止时间", selection: $timed) {
                    Text("未设置").tag(false)
                    Text("指定时间").tag(true)
                }.frame(width: 170)
                if timed { DatePicker("截止时间", selection: $due, displayedComponents: .hourAndMinute).labelsHidden() }
            }
            HStack {
                Button("清除") { store.setDeadline(task.id, to: nil); close() }
                Spacer()
                Button("保存") {
                    if let current = store.locate(task.id) {
                        store.updateTodo(task.id, scheduledDate: current.date, dueDate: due, dueHasTime: timed,
                                         reminderMinutes: current.task.reminderMinutes, repeatRule: current.task.repeatRule)
                    }
                    close()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(14).frame(width: 310)
    }
}
