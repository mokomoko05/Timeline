import AppKit
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
    var select: () -> Void = {}
    var items: [RadialItem] {
        TaskPriority.allCases.map { priority in
            RadialItem(id: priority.rawValue, symbol: "circle.fill", title: priority.title,
                       active: priority == task.priority, tint: PriorityMark(priority: priority).color,
                       action: { store.setPriority(priority, for: task.id) })
        }
    }

    var body: some View {
        NativeTaskHandle(task: task, enabled: !store.isReadOnly, drawsHandle: false,
                         select: select, priorityItems: items,
                         priorityColor: NSColor(PriorityMark(priority: task.priority).color))
            .frame(width: 18, height: 22)
            .help("左键按住拖动；右键设置优先级")
            .accessibilityLabel(LocalizedStringKey(task.priority.title))
            .accessibilityHint("左键按住拖动任务，右键选择优先级")
            .accessibilityActions {
                ForEach(items) { item in Button(LocalizedStringKey(item.title), action: item.action) }
            }
    }
}

struct PrioritySelectionButton: View {
    let priority: TaskPriority
    let items: [RadialItem]
    var enabled = true
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            PriorityMark(priority: priority).frame(width: 18, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .help("设置优先级").accessibilityLabel(LocalizedStringKey(priority.title))
        .popover(isPresented: $showing, arrowEdge: .leading) {
            PriorityPaletteView(items: items, close: { showing = false })
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
            Text(task.dueDate.map(label) ?? AppLocalized("未设日期"))
                .font(.system(size: compact ? 9 : 10, weight: .medium, design: .monospaced))
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


@MainActor
final class PriorityPaletteController {
    static let shared = PriorityPaletteController()
    private(set) var popover: NSPopover?
    var isOpen: Bool { popover?.isShown == true }

    func dismiss() { popover?.performClose(nil); popover = nil }

    func present(items: [RadialItem], anchor: NSView) {
        guard anchor.window != nil, !items.isEmpty else { return }
        dismiss()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !Headless.active
        let content = PriorityPaletteView(items: items, close: { [weak self] in self?.dismiss() })
        let host = NSHostingController(rootView: LocalizedRoot { content })
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize
        self.popover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minX)
        if Headless.active { popover.contentViewController?.view.window?.alphaValue = 0 }
    }
}

struct PriorityPaletteView: View {
    @Environment(\.typography) private var typography
    let items: [RadialItem]
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("优先级").font(.headline)
            FlowLayout(spacing: 6) {
                ForEach(items) { item in
                    Button {
                        item.action()
                        close()
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(item.tint ?? Palette.muted).frame(width: 8, height: 8)
                            Text(LocalizedStringKey(item.title)).font(.system(size: typography.pt(12)))
                            if item.active { Image(systemName: "checkmark").font(.system(size: 10)) }
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(item.active ? Palette.accent.opacity(0.18) : Palette.card, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(item.active ? Palette.accent : Palette.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain).accessibilityLabel(LocalizedStringKey(item.title))
                    .accessibilityAddTraits(item.active ? .isSelected : [])
                }
            }.frame(width: 270)
        }.padding(16).foregroundStyle(Palette.ink)
    }
}
