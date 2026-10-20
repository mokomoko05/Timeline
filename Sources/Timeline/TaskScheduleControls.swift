import SwiftUI
import TimelineCore

struct PriorityMark: View {
    let priority: TaskPriority
    var color: Color {
        switch priority {
        case .urgent: return .red
        case .high: return .orange
        case .normal: return .blue
        case .lower: return .green
        case .low: return Palette.muted
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
    var items: [RadialItem] {
        TaskPriority.allCases.map { priority in
            RadialItem(id: priority.rawValue, symbol: "circle.fill", title: priority.title,
                       active: priority == task.priority, tint: PriorityMark(priority: priority).color,
                       action: { store.setPriority(priority, for: task.id) })
        }
    }

    var body: some View {
        PrioritySelectionButton(priority: task.priority, items: items, enabled: !store.isReadOnly)
    }
}

struct PrioritySelectionButton: View {
    let priority: TaskPriority
    let items: [RadialItem]
    var enabled = true
    @State private var anchor = AnchorBox()

    var body: some View {
        Button {
            RadialMenuController.shared.present(items: items, anchor: anchor.view ?? NSView(), kind: .priority)
        } label: {
            PriorityMark(priority: priority)
                .frame(width: 18, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .raisedOnHover(radius: 4, enabled: enabled)
        .background(AnchorReader(box: anchor))
        .onHover { inside in
            if inside && enabled {
                RadialMenuController.shared.scheduleOpen(items: { items }, anchor: anchor.view, kind: .priority)
            } else { RadialMenuController.shared.cancelOpen() }
        }
        .help(LocalizedStringKey(priority.title))
        .accessibilityLabel(LocalizedStringKey(priority.title))
        .accessibilityHint("选择优先级")
        .accessibilityActions {
            ForEach(items) { item in Button(LocalizedStringKey(item.title), action: item.action) }
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
        Button { showing = true } label: {
            Text(task.dueDate.map(label) ?? "No Due").font(.system(size: compact ? 9 : 10, weight: .medium, design: .monospaced))
                .lineLimit(1).fixedSize()
                .foregroundStyle(!task.completed && task.effectiveDeadline.map({ $0 < Date() }) == true ? Palette.deadline : Palette.muted)
                .padding(.horizontal, compact ? 2 : 4).padding(.vertical, 2)
        }
        .buttonStyle(.plain).raisedOnHover(radius: 4).disabled(store.isReadOnly)
        .help("修改截止时间")
        .accessibilityIdentifier("task-deadline-" + task.id.uuidString)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            TaskDeadlineEditor(store: store, task: task, close: { showing = false })
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
            DeadlineSelectionView(due: $due, timed: $timed)
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
        }.padding(14)
    }
}
