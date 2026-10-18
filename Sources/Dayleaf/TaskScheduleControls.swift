import SwiftUI
import DayleafCore

struct PriorityMark: View {
    let priority: TaskPriority
    var body: some View {
        if priority != .normal {
            Image(systemName: priority == .high ? "arrow.up" : "arrow.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(priority == .high ? Color.orange : Palette.muted)
                .help(LocalizedStringKey(priority.title))
                .accessibilityLabel(LocalizedStringKey(priority.title))
        }
    }
}

struct TaskPriorityButton: View {
    @ObservedObject var store: JournalStore
    let task: Todo
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            PriorityMark(priority: task.priority)
                .frame(width: 14, height: 18).contentShape(Rectangle())
        }
            .buttonStyle(.plain).disabled(store.isReadOnly)
            .help("优先级").accessibilityLabel(LocalizedStringKey(task.priority.title))
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(TaskPriority.allCases) { priority in
                        Button { store.setPriority(priority, for: task.id); showing = false } label: {
                            HStack {
                                Text(LocalizedStringKey(priority.title))
                                Spacer()
                                if task.priority == priority { Image(systemName: "checkmark") }
                            }.padding(6).contentShape(Rectangle())
                        }.buttonStyle(.plain).raisedOnHover(radius: 5)
                    }
                }.padding(8).frame(width: 150)
            }
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
