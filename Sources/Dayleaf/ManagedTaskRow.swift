import AppKit
import SwiftUI
import DayleafCore

struct ManagedTaskRow: View {
    @Environment(\.typography) private var typography
    @ObservedObject var store: JournalStore
    @EnvironmentObject private var interaction: WorkspaceInteraction
    @ObservedObject private var dragSession = TaskDragSession.shared
    @Environment(\.focusSession) private var focus
    @Environment(\.taskReorder) private var reorder
    /// 主窗口的命令中心（搜索面板里的行没有它）。
    @Environment(\.appCommands) private var commands
    let date: Date
    let task: Todo
    var compact = false
    @Binding var requestedEdit: UUID?
    /// 截止日期正好是日历里选中的那一天时，左侧加一条强调线。
    var emphasized = false
    var next: () -> Void = {}
    var select: () -> Void = {}
    @State private var showingDetails = false
    @State private var showingTags = false
    @State private var hovered = false

    private var selected: Bool { interaction.selectedTaskID == task.id || dragSession.activeID == task.id }

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Button { selectTask(); store.toggleTodo(task.id, on: date) } label: {
                Image(systemName: task.isDropped ? "xmark.circle.fill" : (task.completed ? "checkmark.circle.fill" : "circle"))
                    .font(.system(size: typography.pt(compact ? 14 : 17), weight: .light))
                    .foregroundStyle(task.isDropped ? Palette.muted : (task.completed ? Palette.success : Palette.muted))
                    .frame(width: 18, height: 22)
                    .id(task.completed)
                    .transition(Motion.reduced ? .identity : .scale(scale: 0.4).combined(with: .opacity))
                    .animation(Motion.spring, value: task.completed)
            }
            .buttonStyle(HitAreaButtonStyle())
            .accessibilityLabel((task.isDropped ? "恢复已放弃的待办：" : (task.completed ? "标记未完成：" : "标记完成：")) + task.title)
            .help(task.isDropped ? "已放弃：点一下恢复成未完成" : "")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 1) {
                    TaskPriorityButton(store: store, task: task)
                        .frame(width: 18, height: 26)
                    if let number = task.number {
                        Text("#\(number)").font(.system(size: typography.pt(10), design: .monospaced))
                            .foregroundStyle(Palette.muted).padding(.top, 7).fixedSize()
                    }
                TaskTitleView(title: Binding(
                    get: { store.entry(for: date).todos.first(where: { $0.id == task.id })?.title ?? task.title },
                    set: { store.renameTodo(task.id, title: $0, on: date) }
                ), completed: task.completed, color: Palette.ink, fontSize: compact ? 12 : 14,
                              next: next, itemID: task.id, requestedEdit: $requestedEdit,
                              prepare: selectTask, menuItems: menuItems)
                    TaskDeadlineButton(store: store, task: task).padding(.top, 4)
                }
                if task.reminderMinutes != nil || task.repeatRule != .none || task.focusSeconds >= 1 || focus?.active?.taskID == task.id || !task.tags.isEmpty || store.pinnedTask?.id == task.id || task.isDropped {
                    HStack(spacing: 4) {
                        if task.isDropped { Label("已放弃", systemImage: "nosign") }
                        if store.pinnedTask?.id == task.id {
                            Image(systemName: "pin.fill").foregroundStyle(Palette.accent).help("固定关联：新日志默认记到它名下")
                        }
                        if task.reminderMinutes != nil { Image(systemName: "bell") }
                        if task.repeatRule != .none { Image(systemName: "repeat") }
                        if let focus { FocusTimeBadge(session: focus, taskID: task.id, accumulated: task.focusSeconds) }
                        TaskTagLine(tags: task.tags)
                    }
                    .font(.system(size: typography.pt(10))).lineLimit(1)
                    .foregroundStyle(overdue ? Palette.deadline : Palette.muted)
                    .padding(.horizontal, 5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                if let focus, !task.completed {
                    FocusPlayButton(session: focus, task: ScheduledTask(date: date, task: task), url: FocusSession.link(in: task.title))
                }
                RadialMenuButton(items: { radialItems }, help: "更多操作：笔记、截止日期、标签、固定、放弃、删除")
                    .popover(isPresented: $showingTags, arrowEdge: .leading) { TagPickerView(store: store, task: task) }
                TaskDragHandle(task: task, enabled: !store.isReadOnly, select: { reorder?.suppressScroll = true; selectTask() }, reorder: reorder.map { model in
                    TaskReorderHooks(begin: { model.begin(task.id) }, update: { model.update($0) },
                                     end: { model.finish() }, cancel: { model.cancel() })
                })
            }
            .fixedSize()
        }
        .padding(.horizontal, 6).padding(.vertical, compact ? 4 : 7)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
        // 常驻一道很淡的细边（有质感但不花），悬停时浮起来：边变清晰、下面有一点阴影。
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line.opacity(hovered ? 0.9 : 0.35), lineWidth: 0.75).allowsHitTesting(false))
        .shadow(color: .black.opacity(hovered && !selected ? 0.16 : 0), radius: hovered ? 4 : 0, x: 0, y: hovered ? 2 : 0)
        .onHover { hovered = $0 }
        .animation(Motion.quick, value: hovered)
        .overlay(alignment: .leading) {
            if emphasized { Capsule().fill(Palette.accent).frame(width: 3).padding(.vertical, 6).allowsHitTesting(false) }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Palette.accent : .clear, lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .simultaneousGesture(TapGesture().onEnded { selectTask() })
        .animation(.easeInOut(duration: 0.12), value: selected)
        .modifier(TaskDragSource(task: task, enabled: !store.isReadOnly, select: selectTask))
        .contextMenu {
            ForEach(Array(menuItems.enumerated()), id: \.offset) { _, item in
                if item.separator { Divider() } else {
                    Button(role: item.destructive ? .destructive : nil, action: item.action) {
                        if let symbol = item.symbol { Label(LocalizedStringKey(item.title), systemImage: symbol) } else { Text(LocalizedStringKey(item.title)) }
                    }
                }
            }
        }
        .popover(isPresented: $showingDetails, arrowEdge: .leading) { TaskDetailsView(store: store, task: task, date: date) }
        // 键盘（D / T）或菜单请这一行打开面板。
        .onChange(of: interaction.taskPopover) { request in
            guard let request, request.id == task.id else { return }
            interaction.taskPopover = nil
            NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
            switch request.kind {
            case .details: showingDetails = true
            case .tags: showingTags = true
            }
        }
        .disabled(store.isReadOnly)
    }

    /// 环形菜单里的操作（也是右键菜单的内容）。
    private var radialItems: [RadialItem] {
        let noteCount = store.notes(for: task.id).count
        var items: [RadialItem] = [
            RadialItem(id: "notes", symbol: noteCount > 0 ? "note.text" : "square.and.pencil",
                       title: noteCount > 0 ? "打开笔记（\(noteCount) 条）" : "写笔记", active: noteCount > 0, action: {
                selectTask()
                NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
                commands?.send(.notesForTask(task.id))
            }),
            RadialItem(id: "date", symbol: "calendar.badge.clock", title: "截止日期与月历短标题", action: {
                selectTask()
                NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
                showingDetails = true
            }),
            RadialItem(id: "tag", symbol: task.tags.isEmpty ? "tag" : "tag.fill", title: "标签", active: !task.tags.isEmpty, action: {
                selectTask()
                NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
                showingTags = true
            }),
        ]
        if !task.completed {
            let pinned = store.pinnedTask?.id == task.id
            items.append(RadialItem(id: "pin", symbol: pinned ? "pin.fill" : "pin", title: pinned ? "取消固定" : "固定为当前待办", active: pinned, action: {
                store.pinTask(pinned ? nil : task.id)
            }))
        }
        if !task.isDone {
            items.append(RadialItem(id: "drop", symbol: task.isDropped ? "arrow.uturn.backward.circle" : "nosign",
                                    title: task.isDropped ? "恢复" : "放弃（留着记录）", action: {
                NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
                store.dropTodo(task.id, on: date)
            }))
        }
        items.append(RadialItem(id: "delete", symbol: "trash", title: "删除 · ⌘Z 撤销", destructive: true, action: {
            NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
            store.deleteTodo(task.id, on: date)
            if interaction.selectedTaskID == task.id { interaction.selectedTaskID = nil }
        }))
        return items
    }

    private var menuItems: [TextMenuItem] {
        guard !store.isReadOnly else { return [] }
        var list = radialItems.map { TextMenuItem(title: $0.title, symbol: $0.symbol, destructive: $0.destructive, action: $0.action) }
        list.insert(contentsOf: TaskPriority.allCases.map { priority in
            TextMenuItem(title: priority.title, symbol: task.priority == priority ? "checkmark" : nil,
                         action: { store.setPriority(priority, for: task.id) })
        }, at: 0)
        // 删除前面加一条分隔线。
        if let last = list.indices.last, list.count > 1 { list.insert(.divider, at: last) }
        return list
    }

    private var overdue: Bool { !task.completed && task.effectiveDeadline.map { $0 < Date() } == true }

    private func selectTask() {
        interaction.selectedTaskID = task.id
        select()
    }
}
