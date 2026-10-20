import AppKit
import SwiftUI
import TimelineCore

/// 与待办卡片共用信息位置，在创建前选择优先级、日期与标签。
struct TaskComposerRow: View {
    @Environment(\.typography) private var typography
    @ObservedObject var store: JournalStore
    @Binding var text: String
    @Binding var focused: Bool
    @Binding var options: TaskCreationOptions
    var defaultDate = Date()
    var compact = false
    let submit: () -> Void
    var cancel: () -> Void = {}
    var previous: () -> Void = {}
    var complete: (() -> Void)?

    private var preview: Todo { options.applying(to: QuickAdd.parse(text).resolve(defaultDay: defaultDate).todo) }

    var body: some View {
        HStack(spacing: 4) {
            PrioritySelectionButton(priority: options.priority, items: TaskPriority.allCases.map { priority in
                RadialItem(id: priority.rawValue, symbol: "circle.fill", title: priority.title,
                    active: options.priority == priority, tint: PriorityMark(priority: priority).color,
                    action: { options.priority = priority })
            }, enabled: !store.isReadOnly)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                TaskInput(text: $text, focused: $focused, placeholder: "添加待办…", fontSize: compact ? 12 : 14,
                          submit: submit, cancel: cancel, previous: previous, complete: complete,
                          minHeight: compact ? 24 : typography.pt(22), maxLines: compact ? 1 : 3, allowsNewlines: compact,
                          collapsesPastedNewlines: false, returnSubmits: compact, submitsOnBlur: false)
                if !preview.tags.isEmpty || preview.reminderMinutes != nil || preview.repeatRule != .none {
                    HStack(spacing: 4) {
                        if preview.reminderMinutes != nil { Image(systemName: "bell") }
                        if preview.repeatRule != .none { Image(systemName: "repeat") }
                        TaskTagLine(tags: preview.tags)
                    }.font(.system(size: typography.pt(10))).foregroundStyle(Palette.muted)
                        .padding(.horizontal, 3)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                DraftDeadlineButton(options: $options, initial: preview, defaultDate: defaultDate)
                Button(action: submit) {
                    Image(systemName: "arrow.turn.down.left").font(.system(size: 10))
                        .frame(minWidth: 24, minHeight: 20)
                }.buttonStyle(.plain).raisedOnHover(radius: 4)
                    .foregroundStyle(Palette.accent).accessibilityLabel("添加待办")
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.foregroundStyle(Palette.muted)
            TodoDraftTagButton(store: store, text: $text)
        }
        .padding(.horizontal, 6).padding(.vertical, compact ? 4 : 7)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Palette.accent.opacity(0.7) : Palette.line.opacity(0.6), lineWidth: focused ? 1.5 : 0.75).allowsHitTesting(false))
        .disabled(store.isReadOnly)
    }
}

struct DraftDeadlineButton: View {
    @Binding var options: TaskCreationOptions
    let initial: Todo
    var defaultDate = Date()
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Text(initial.dueDate.map { due in
                initial.dueHasTime ? due.relativeLabel + " " + TaskDeadlineButton.time(due) : due.relativeLabel
            } ?? "No Due")
                .font(.system(size: 10, weight: .medium, design: .monospaced)).lineLimit(1)
                .padding(.horizontal, 4).padding(.vertical, 2)
        }
        .buttonStyle(.plain).raisedOnHover(radius: 4).help("修改截止时间")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            DraftDeadlineEditor(options: $options, initial: initial, defaultDate: defaultDate)
        }
    }
}

private struct DraftDeadlineEditor: View {
    @Binding var options: TaskCreationOptions
    @Environment(\.dismiss) private var dismiss
    @State private var due: Date
    @State private var timed: Bool

    init(options: Binding<TaskCreationOptions>, initial: Todo, defaultDate: Date) {
        _options = options
        _due = State(initialValue: initial.dueDate ?? defaultDate)
        _timed = State(initialValue: initial.dueHasTime)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeadlineSelectionView(due: $due, timed: $timed)
            HStack {
                Button("清除") {
                    options.overridesDeadline = true; options.dueDate = nil; options.dueHasTime = false
                    dismiss()
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    options.overridesDeadline = true; options.dueDate = due; options.dueHasTime = timed
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(14)
    }
}
