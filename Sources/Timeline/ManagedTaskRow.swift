import AppKit
import SwiftUI
import TimelineCore

struct ManagedTaskRow: View {
    @Environment(\.typography) private var typography
    @ObservedObject var store: JournalStore
    @EnvironmentObject private var interaction: WorkspaceInteraction
    @Environment(\.focusSession) private var focus
    /// 主窗口的命令中心（搜索面板里的行没有它）。
    @Environment(\.appCommands) private var commands
    let date: Date
    let task: Todo
    var compact = false
    @Binding var requestedEdit: UUID?
    /// 截止日期正好是日历里选中的那一天时，左侧加一条强调线。
    var emphasized = false
    var timeline = false
    var next: () -> Void = {}
    var select: () -> Void = {}
    @State private var showingDetails = false
    @State private var showingDeadline = false
    @State private var showingTags = false
    @State private var hovered = false

    private var selected: Bool { interaction.selectedTaskID == task.id }

    var body: some View {
        HStack(spacing: 6) {
            if timeline {
                TaskDeadlineButton(store: store, task: task, compact: true, rowActive: hovered || selected)
                .frame(width: TaskTimelineLayout.timeWidth(typography), alignment: .trailing)
                priorityControl
                    .frame(width: 22).frame(maxHeight: .infinity)
                    .background {
                        if task.timeRange != nil {
                            VStack(spacing: 0) {
                                Circle().fill(Palette.accent).frame(width: 4, height: 4)
                                Rectangle().fill(Palette.accent.opacity(0.55)).frame(width: 2)
                                Circle().fill(Palette.accent).frame(width: 4, height: 4)
                            }.padding(.vertical, 5).allowsHitTesting(false)
                        }
                        // 悬停 / 选中时珠子外多一圈柔和的光晕。
                        Circle().fill(PriorityMark(priority: task.priority).color.opacity(0.16))
                            .frame(width: 22, height: 22)
                            .opacity(hovered || selected ? 1 : 0)
                            .animation(decorationAnimation, value: hovered || selected)
                            .allowsHitTesting(false)
                    }
            }
            rowContent
        }
        .fixedSize(horizontal: false, vertical: true)
        .onHover { hovered = $0 }
        // 悬停、选中的过渡只作用在底色、描边、光晕这些装饰层上（见 decorationAnimation），
        // 整行（含原生文本）不进动画事务：拖动排序和选中时不再每帧重算整行。
        .animation(Motion.quick, value: task.completed)
    }

    private var decorationAnimation: Animation? { Motion.reduced ? nil : .easeOut(duration: 0.16) }

    private var priorityControl: some View {
        TaskPriorityButton(store: store, task: task, select: {
            if interaction.selectedTaskID != task.id { interaction.suppressNextTaskScroll = true }
            selectTask()
        })
    }

    private var completedRow: some View {
        HStack(spacing: 6) {
            Text(String(TaskText.rendered(task.title).characters).replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: typography.pt(compact ? 11 : 12)))
                .strikethrough(task.isDone)
                .foregroundStyle(Palette.muted)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if task.isDropped {
                Text("已放弃").font(.system(size: typography.pt(10))).foregroundStyle(Palette.muted)
            }
            completionButton
        }
        .frame(minHeight: typography.pt(24))
        .padding(.horizontal, 8)
    }

    /// 截止日期（清单模式）、工作板与专注入口。
    private var detailColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if !timeline { TaskDeadlineButton(store: store, task: task) }
            if store.board(for: .task(task.id)) != nil {
                BoardOpenButton(store: store, owner: .task(task.id)).font(.system(size: 10)).buttonStyle(.plain)
            }
            if let focus {
                TaskFocusButton(session: focus, task: ScheduledTask(date: date, task: task))
            }
        }
        .padding(.vertical, 2)
        .frame(maxHeight: .infinity)
    }

    /// 标签与更多操作。
    private var rowActions: some View {
        HStack(spacing: 0) {
            TagSelectionButton(store: store, tags: Binding(get: { store.locate(task.id)?.task.tags ?? task.tags }, set: { store.setTags(task.id, $0) }))
            RadialMenuButton(items: { radialItems }, help: "更多操作：笔记、标签、固定、放弃、删除")
                .popover(isPresented: $showingTags, arrowEdge: .leading) { TagPickerView(store: store, task: task) }
        }
    }

    private var completionButton: some View {
        Button { selectTask(); withAnimation(Motion.quick) { store.toggleTodo(task.id, on: date) } } label: {
            Image(systemName: task.isDropped ? "xmark.circle.fill" : (task.completed ? "checkmark.circle.fill" : "circle"))
                .font(.system(size: typography.pt(compact ? 14 : 17), weight: .light))
                .foregroundStyle(task.isDone ? Palette.success : Palette.muted)
                .frame(width: 18, height: 22)
                .id(task.completed)
                .transition(Motion.reduced ? .identity : .scale(scale: 0.4).combined(with: .opacity))
                .animation(Motion.spring, value: task.completed)
        }
        .buttonStyle(HitAreaButtonStyle(compact: timeline && task.completed))
        .accessibilityLabel((task.isDropped ? "恢复已放弃的待办：" : (task.completed ? "标记未完成：" : "标记完成：")) + task.title)
        .help(task.isDropped ? "已放弃：点一下恢复成未完成" : "")
    }

    private var card: some View {
        HStack(alignment: .center, spacing: 4) {
            HStack(alignment: .center, spacing: 1) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .center, spacing: 1) {
                        if !timeline {
                            priorityControl
                                .frame(width: 18, height: 26)
                        }
                        if let number = task.number, !timeline {
                            Text("#\(number)").font(.system(size: typography.pt(10), design: .monospaced))
                                .foregroundStyle(Palette.muted).fixedSize()
                        }
                        TaskTitleView(title: Binding(
                            get: { store.entry(for: date).todos.first(where: { $0.id == task.id })?.title ?? task.title },
                            set: { store.renameTodo(task.id, title: $0, on: date) }
                        ), completed: task.isDone, color: task.isDropped ? Palette.muted : Palette.ink, fontSize: compact ? 12 : 14,
                                      next: next, itemID: task.id, requestedEdit: $requestedEdit,
                                      prepare: selectTask, menuItems: menuItems)
                    }
                    if task.reminderMinutes != nil || task.repeatRule != .none || !task.tags.isEmpty || store.pinnedTask?.id == task.id || task.isDropped {
                        HStack(spacing: 4) {
                            if task.isDropped { Label("已放弃", systemImage: "nosign") }
                            if store.pinnedTask?.id == task.id {
                                Image(systemName: "pin.fill").foregroundStyle(Palette.accent).help("固定关联：新日志默认记到它名下")
                            }
                            if task.reminderMinutes != nil { Image(systemName: "bell") }
                            if task.repeatRule != .none { Image(systemName: "repeat") }
                            TaskTagLine(tags: task.tags)
                        }
                        .font(.system(size: typography.pt(10))).lineLimit(1)
                        .foregroundStyle(overdue ? Palette.deadline : Palette.muted)
                        .padding(.horizontal, 5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !timeline { detailColumn }
            }
            // 先按内容确定高度，再让右列分配上下空间，避免 Spacer 撑高条目。
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 时间轴里的操作按钮悬停时浮在标题右侧，不占版面：标题能用满整行，悬停也不会让文字重排。
            .overlay(alignment: .trailing) {
                if timeline {
                    HStack(spacing: 2) { detailColumn; rowActions }
                        .padding(.leading, 22)
                        // 只在左缘做一段渐隐，盖住被按钮压住的标题末尾；底色与这一行当前的底色一致，看不出边界。
                        .background {
                            ZStack {
                                Palette.background
                                (selected ? Palette.accent.opacity(0.11) : Palette.soft.opacity(0.45))
                            }
                            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.3)],
                                                 startPoint: .leading, endPoint: .trailing))
                        }
                        .opacity(hovered || selected ? 1 : 0)
                        .animation(decorationAnimation, value: hovered || selected)
                        .allowsHitTesting(hovered || selected)
                        .accessibilityHidden(!hovered && !selected)
                }
            }
            HStack(spacing: 0) {
                if !timeline { rowActions }
                completionButton
            }
            .fixedSize()
        }
        .padding(.horizontal, 6).padding(.vertical, compact ? 4 : 7)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(timeline ? (selected ? Palette.accent.opacity(0.11) : (hovered ? Palette.soft.opacity(0.45) : .clear)) : Palette.card)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(colors: [.white.opacity(timeline ? 0 : (hovered ? 0.055 : 0.025)), .clear],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .shadow(color: .black.opacity(timeline ? 0 : (hovered || selected ? 0.18 : 0.07)),
                        radius: hovered || selected ? 5 : 2, x: 0, y: hovered || selected ? 2 : 1)
                .animation(decorationAnimation, value: hovered)
                .animation(decorationAnimation, value: selected)
        }
        // 常驻一道很淡的细边（有质感但不花），悬停时浮起来：边变清晰、下面有一点阴影。
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line.opacity(timeline ? 0 : (hovered ? 0.9 : 0.35)), lineWidth: 0.75)
            .animation(decorationAnimation, value: hovered).allowsHitTesting(false))
        .overlay { TaskLandingFlash(id: task.id) }
        .overlay(alignment: .leading) {
            if emphasized && !timeline { Capsule().fill(Palette.accent).frame(width: 3).padding(.vertical, 6).allowsHitTesting(false) }
        }
        .overlay {
            // 时间轴里的选中是一层柔和的底色和极细的边，不再是一圈生硬的粗框；清单卡片保留描边。
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Palette.accent.opacity(timeline ? 0.35 : 1) : .clear, lineWidth: timeline ? Metrics.hairline : 1.5)
                .animation(decorationAnimation, value: selected)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            Capsule().fill(Palette.accent).frame(width: 2.5).padding(.vertical, 8)
                .opacity(timeline && selected ? 1 : 0)
                .scaleEffect(x: 1, y: timeline && selected ? 1 : 0.4, anchor: .center)
                .animation(Motion.reduced ? nil : Motion.spring, value: selected)
                .allowsHitTesting(false)
        }
    }

    private var rowContent: some View {
        Group {
            if timeline && task.completed {
                completedRow.transition(.opacity)
            } else {
                card.transition(.opacity)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .simultaneousGesture(TapGesture().onEnded { selectTask() })
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
        .popover(isPresented: $showingDeadline, arrowEdge: .leading) {
            TaskDeadlineEditor(store: store, task: task, close: { showingDeadline = false })
        }
        // 键盘（D / T）或菜单请这一行打开面板。
        .onChange(of: interaction.taskPopover) { request in
            guard let request, request.id == task.id else { return }
            interaction.taskPopover = nil
            NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
            switch request.kind {
            case .details: showingDetails = true
            case .deadline: showingDeadline = true
            case .tags: showingTags = true
            }
        }
        .disabled(store.isReadOnly)
    }

    /// 环形菜单里的操作（也是右键菜单的内容）。
    private var radialItems: [RadialItem] {
        let noteCount = store.noteCount(for: task.id)
        var items: [RadialItem] = [
            RadialItem(id: "board", symbol: "list.bullet.rectangle", title: "打开工作板", action: {
                selectTask()
                BoardWindowController.shared.show(store: store, owner: .task(task.id))
            }),
            RadialItem(id: "notes", symbol: noteCount > 0 ? "note.text" : "square.and.pencil",
                       title: noteCount > 0 ? AppLocalizedFormat("打开笔记（%lld 条）", noteCount) : "写笔记", active: noteCount > 0, action: {
                selectTask()
                NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
                commands?.send(.notesForTask(task.id))
            }),
            RadialItem(id: "tag", symbol: task.tags.isEmpty ? "tag" : "tag.fill", title: "标签", active: !task.tags.isEmpty, action: {
                selectTask()
                NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
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
                NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
                store.dropTodo(task.id, on: date)
            }))
        }
        items.append(RadialItem(id: "delete", symbol: "trash", title: "删除 · ⌘Z 撤销", destructive: true, action: {
            NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
            store.deleteTodo(task.id, on: date)
            if interaction.selectedTaskID == task.id { interaction.selectedTaskID = nil }
        }))
        return items
    }

    private var menuItems: [TextMenuItem] {
        guard !store.isReadOnly else { return [] }
        var list = radialItems.map { TextMenuItem(title: $0.title, symbol: $0.symbol, destructive: $0.destructive, action: $0.action) }
        if task.completed {
            list.insert(TextMenuItem(title: task.isDropped ? "恢复" : "取消完成", symbol: "arrow.uturn.backward", action: {
                withAnimation(Motion.quick) { store.toggleTodo(task.id, on: date) }
            }), at: 0)
        }
        list.insert(TextMenuItem(title: "任务设置…", symbol: "slider.horizontal.3", action: {
            selectTask()
            NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
            showingDetails = true
        }), at: 1)
        list.insert(TextMenuItem(title: "截止日期与时间…（D）", symbol: "calendar.badge.clock", action: {
            selectTask()
            NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
            showingDeadline = true
        }), at: 1)
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
