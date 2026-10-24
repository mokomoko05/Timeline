import AppKit
import SwiftUI
import TimelineCore

struct PriorityMark: View {
    let priority: TaskPriority
    var color: Color {
        switch priority {
        case .urgent: return Palette.danger
        case .high: return Palette.attention
        case .normal: return Palette.accent
        case .lower: return Palette.success
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
    /// 只用来执行操作；不观察仓库，所在的行或格子随数据变化重建它。
    let store: JournalStore
    let task: Todo
    var dragOrigin: TaskDragOrigin = .taskList
    @Environment(\.taskReorder) private var reorder
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
                         select: select, reorder: reorder.map { model in
                             TaskReorderHooks(begin: { model.begin(task.id) }, update: { model.update($0) },
                                 end: { model.finish() }, cancel: { model.cancel() })
                         }, priorityItems: items,
                         priorityColor: NSColor(PriorityMark(priority: task.priority).color), dragOrigin: dragOrigin)
            .frame(width: 18, height: 22)
            .help(dragOrigin == .calendar ? "拖到日历或左侧日期分组修改日期；拖到 No Due 清除日期；右键设置优先级" : "同一日期内上下排序；拖到日历修改日期；右键设置优先级")
            .accessibilityLabel(LocalizedStringKey(task.priority.title))
            .accessibilityHint(dragOrigin == .calendar ? "拖到日历或左侧日期分组修改日期；拖到 No Due 清除日期；右键设置优先级" : "同一日期内上下排序，拖到日历修改日期，右键选择优先级")
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
    /// 只用来执行操作；不观察仓库，所在的行或格子随数据变化重建它。
    let store: JournalStore
    let task: Todo
    var compact = false
    @State private var showing = false

    static func time(_ date: Date) -> String {
        let parts = JournalDates.calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    static func label(for task: Todo, compact: Bool = false) -> String {
        guard let due = task.dueDate else { return AppLocalized("设置日期") }
        if compact { return task.dueHasTime ? time(due) : AppLocalized("全天") }
        return task.dueHasTime ? due.relativeLabel + " " + time(due) : due.relativeLabel
    }

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 3) {
                if !compact { Image(systemName: task.dueHasTime ? "clock" : "calendar") }
                Text(Self.label(for: task, compact: compact))
            }
                .font(.system(size: compact ? 10 : 11, weight: .medium)).monospacedDigit()
                .lineLimit(1).fixedSize()
                .foregroundStyle(!task.completed && task.effectiveDeadline.map({ $0 < Date() }) == true ? Palette.deadline : (task.dueHasTime ? Palette.accent : Palette.muted))
                .padding(.horizontal, compact ? 2 : 4).padding(.vertical, 2)
        }
        .buttonStyle(.plain).raisedOnHover(radius: 4).disabled(store.isReadOnly)
        .help(task.dueDate.map { $0.formatted(date: .complete, time: task.dueHasTime ? .shortened : .omitted) } ?? AppLocalized("设置截止日期与时间"))
        .accessibilityLabel(AppLocalized("截止日期与时间") + " " + Self.label(for: task))
        .accessibilityIdentifier("task-deadline-" + task.id.uuidString)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            TaskDeadlineEditor(store: store, task: task, close: { showing = false })
        }
    }
}

struct TaskDeadlineEditor: View {
    @ObservedObject var store: JournalStore
    let task: Todo
    let close: () -> Void
    @State private var due: Date
    @State private var timed: Bool
    init(store: JournalStore, task: Todo, close: @escaping () -> Void) {
        self.store = store; self.task = task; self.close = close
        _due = State(initialValue: DeadlineSelection.initialDate(task.dueDate ?? Date(), hasTime: task.dueHasTime))
        _timed = State(initialValue: task.dueHasTime)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("截止日期与时间").font(.system(size: 14, weight: .semibold))
            Text(String(TaskText.rendered(task.title).characters)).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
            DeadlineSelectionView(due: $due, timed: $timed)
            Divider()
            HStack {
                Button("清除") { store.setDeadline(task.id, to: nil); close() }
                    .disabled(task.dueDate == nil)
                Spacer()
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                Button("保存") {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    if let current = store.locate(task.id) {
                        store.updateTodo(task.id, scheduledDate: current.date, dueDate: due, dueHasTime: timed,
                                         reminderMinutes: current.task.reminderMinutes, repeatRule: current.task.repeatRule)
                    }
                    close()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(16).foregroundStyle(Palette.ink).background(Palette.background)
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
