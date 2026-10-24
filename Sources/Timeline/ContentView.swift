import AppKit
import Combine
import SwiftUI
import TimelineCore
import UniformTypeIdentifiers

struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.vertical, 8)
    }
}

struct ContentView: View {
    @Environment(\.typography) private var typography
    @Environment(\.locale) private var locale
    @ObservedObject var store: JournalStore
    @ObservedObject var loginItem: LoginItem
    @State private var selectedDate = JournalDates.calendar.startOfDay(for: Date())
    /// 待办输入的缓冲。放在 @State（不是 @StateObject）里：只有输入行观察它，按键不重绘整个主界面。
    @State private var todoDraft = LogDraftBuffer(field: .deadline)
    @State private var displayedMonth = JournalDates.monthStart(Date())
    @State private var actionError: String?
    @State private var showingLinkComposer = false
    @State private var linkInsertion: LinkInsertion?
    @State private var pendingLink: String?
    @State private var agenda: AgendaFilter?
    @State private var showingBackups = false
    @State private var requestedEdit: UUID?
    @State private var showingMonthJumper = false
    private let notesWindow = NotesWindowController.shared
    @State private var overdueCount = 0
    @State private var scrollTarget: UUID?
    /// 点摘要里的数字时，要定位的任务类型（`overdue` / `today`）。
    @State private var scrollGroup: String?
    @State private var expandedFinished: Set<UUID> = []
    /// 待办行的位置，用来判断一次点击是不是点在待办上（不是 @Published，更新它不会触发重绘）。
    @State private var rowRegions = TaskRowRegions()
    @AppStorage(Prefs.hideCompleted) private var hideCompleted = false
    @AppStorage(Prefs.clickExpands) private var clickExpands = true
    @AppStorage(Prefs.weekStartsSunday) private var weekStartsSunday = false
    @Environment(\.focusSession) private var focus
    @ObservedObject private var themes = ThemeStore.shared
    @EnvironmentObject private var reminders: ReminderScheduler
    @EnvironmentObject private var interaction: WorkspaceInteraction
    @EnvironmentObject private var commands: CommandCenter
    @EnvironmentObject private var toast: ToastCenter
    @State private var currentDayKey = JournalDates.key(Date())
    @State private var addingTodo = false
    @State private var creationOptions = TaskCreationOptions()
    @AppStorage("tasksPaneExpanded") private var tasksVisible = false
    /// 跨日、唤醒、改系统时间时立即刷新；平时每分钟兜底一次（逾期角标），允许系统合并唤醒。
    private let dayTimer = Publishers.Merge(
        Timer.publish(every: 60, tolerance: 15, on: .main, in: .common).autoconnect(),
        Publishers.MergeMany([
            NotificationCenter.default.publisher(for: .NSCalendarDayChanged),
            NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemClockDidChange),
            NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange),
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification),
        ]).receive(on: RunLoop.main).map { _ in Date() }
    )
    private var entry: DayEntry { store.entry(for: selectedDate) }
    /// 全部任务（不属于某一天），按截止时间排序；隐藏已完成时过滤掉已完成的。
    private var orderedTasks: [ScheduledTask] {
        store.tasks().sorted(by: TaskTimelineSection.precedes)
            .filter { !hideCompleted || !$0.task.completed }
    }
    private var visibleTasks: [ScheduledTask] {
        TaskTimelineSection.sections(for: orderedTasks, today: JournalDates.date(for: currentDayKey) ?? Date())
            .flatMap { $0.visibleTasks(expanded: expandedFinished) }
    }
    private var weekStart: Int { weekStartsSunday ? 1 : 2 }
    private var footerVisible: Bool { store.errorMessage != nil || !reminders.status.isEmpty }
    private var draft: Binding<String> {
        Binding(get: { todoDraft.text }, set: { todoDraft.update($0) })
    }

    /// 带「撤销」提示的操作。普通编辑不打扰用户。
    private static var toastMessages: [String: String] { ToastCenter.undoMessages }

    var body: some View {
        VStack(spacing: 0) {
            ResizableWorkspace(tasksVisible: $tasksVisible) {
                VStack(alignment: .leading, spacing: 16) {
                    dateHeader
                    todoCard
                }
                .padding(16)
                .simultaneousGesture(TapGesture().onEnded { interaction.activePane = .tasks })
            } calendar: {
                calendarCard.padding(16)
            }
            if footerVisible { footer.transition(.opacity) }
        }
        .id("\(themes.themeID)|\(themes.appearance.rawValue)")
        .animation(Motion.quick, value: footerVisible)
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .frame(minWidth: 640, minHeight: 560)
        // 点了待办以外的地方（日历、空白、标题栏……）就取消选中。
        .background(ClickAwayDeselect(regions: rowRegions, selection: { interaction.selectedTaskID }, deselect: {
            interaction.selectedTaskID = nil
        }))
        .overlay(alignment: .bottom) {
            ToastView(center: toast).padding(.bottom, footerVisible ? 52 : 18)
        }
        .sheet(isPresented: $showingLinkComposer, onDismiss: {
            if linkInsertion?.finish(inserting: pendingLink) != true {
                if let pendingLink { todoDraft.set(todoDraft.text + (todoDraft.text.isEmpty ? "" : " ") + pendingLink) }
                tasksVisible = true
                addingTodo = true
            }
            pendingLink = nil
            linkInsertion = nil
        }) {
            LinkComposer(insert: { pendingLink = $0 }, initialAddress: linkInsertion?.initialAddress ?? "", initialLabel: linkInsertion?.initialLabel ?? "")
        }
        .sheet(item: $agenda) { filter in
            AgendaView(store: store, navigate: { date, id in
                // 主界面的日志 / 总结条目统一跳到合并窗口的日记模式，并选中对应日期。
                if let date, id == nil {
                    notesWindow.showJournal(store: store, date: date)
                } else {
                    reveal(date: date, taskID: id)
                }
            }, filter: filter)
        }
        .sheet(isPresented: $showingBackups) { BackupRestoreView(store: store) }
        .alert("暂时无法完成操作", isPresented: Binding(
            get: { actionError != nil || loginItem.errorMessage != nil },
            set: { if !$0 { actionError = nil; loginItem.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { actionError = nil; loginItem.errorMessage = nil }
        } message: {
            Text(actionError ?? loginItem.errorMessage ?? "")
        }
        .onAppear {
            todoDraft.attach(store: store, date: selectedDate)
            refreshOverview()
        }
        .onChange(of: selectedDate) { todoDraft.attach(store: store, date: $0) }
        .onReceive(dayTimer) { now in
            refreshOverview()
            let newKey = JournalDates.key(now)
            guard currentDayKey != newKey else { return }
            if JournalDates.key(selectedDate) == currentDayKey { select(now) }
            currentDayKey = newKey
        }
        .onReceive(store.$days.debounce(for: .milliseconds(400), scheduler: RunLoop.main)) { _ in refreshOverview() }
        .onReceive(store.$lastAction.dropFirst()) { event in
            toast.dismiss()
            // 只在主窗口是当前窗口时提示（在日志窗口里删的，提示出现在日志窗口）。
            guard let event, AppRouter.mainIsKey(), let message = Self.toastMessages[event.name] else { return }
            toast.show(message, actionTitle: "撤销") { store.undo() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
            reminders.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .timelineNavigate)) { if let date = $0.object as? Date { select(date) } }
        .onReceive(NotificationCenter.default.publisher(for: .timelineReveal)) { if let id = $0.object as? UUID { reveal(date: store.locate(id)?.task.dueDate, taskID: id) } }
        .onReceive(NotificationCenter.default.publisher(for: .timelineOpenTag)) { if let tag = $0.object as? String { showNotes(tag: tag) } }
        .onReceive(commands.subject) { handle($0) }
    }

    // MARK: - 命令

    /// 打开笔记窗口：指定标签就定位到标签；否则保持上次关闭时的样子（任务、标签、搜索词都不变），不再跟着清单里选中的任务跳。
    /// 打开笔记。`taskID` 指定就跳到那个任务（还没笔记也能直接写）；都不指定，就看清单里有没有选中的任务：
    /// 有就打开它的笔记，没有就回到上次笔记停留的地方。
    private func showNotes(tag: String?, taskID: UUID? = nil, followSelection: Bool = true) {
        let target = taskID ?? (followSelection && tag == nil ? interaction.selectedTaskID.flatMap { store.locate($0)?.id } : nil)
        notesWindow.show(store: store, taskID: target, tag: tag,
                         reveal: { id in reveal(date: store.locate(id)?.task.dueDate, taskID: id) },
                         openDay: { date in select(date); notesWindow.showJournal(store: store, date: date) })
    }

    /// 这些命令的结果在主窗口里（清单、日历、搜索面板……）：主窗口被收起了就先把它调出来，不然点了什么都看不到。
    private static func needsMainWindow(_ command: AppCommand) -> Bool {
        switch command {
        case .newTodo, .search, .agenda, .reveal, .backups, .export, .rollover, .toggleTasks, .shiftMonth, .today, .shiftDay,
             .selectAdjacent, .toggleSelected, .editSelected, .deleteSelected, .deadlineSelected, .tagsSelected:
            return true
        default: return false
        }
    }

    private func handle(_ command: AppCommand) {
        if Self.needsMainWindow(command) { AppRouter.presentMain() }
        switch command {
        case .deadlineSelected, .tagsSelected:
            guard let task = selectedTask else { return }
            tasksVisible = true
            scrollTarget = task.id
            let kind: TaskPopoverRequest.Kind = { if case .tagsSelected = command { return .tags } else { return .deadline } }()
            // 等清单滚到这一行、行画出来之后再请它打开面板。
            DispatchQueue.main.async { interaction.taskPopover = TaskPopoverRequest(id: task.id, kind: kind) }
        case .pinSelected:
            guard let task = selectedTask, !task.task.completed else { return }
            store.pinTask(store.pinnedTask?.id == task.id ? nil : task.id)
        case .dropSelected:
            guard let task = selectedTask, !task.task.isDone else { return }
            store.dropTodo(task.id, on: task.date)
        case .focusSelected:
            guard let task = selectedTask, !task.task.completed, let focus else { return }
            if focus.active?.taskID == task.id { focus.stop(reason: "手动结束") } else { focus.start(task: task, url: FocusSession.link(in: task.task.title)) }
        case .notesSelected:
            showNotes(tag: nil)
        case .newTodo:
            tasksVisible = true
            interaction.activePane = .tasks
            addingTodo = true
        case .newLog:
            // 写日志：打开当天日志，光标直接在输入框里。
            notesWindow.showJournal(store: store, date: selectedDate)
        case .insertLink:
            guard !store.isReadOnly else { return }
            linkInsertion = LinkInsertion()
            showingLinkComposer = true
        case .today: select(Date()); scrollGroup = "today"
        case .search: agenda = .all
        case .notes: showNotes(tag: nil)
        case .notesForTask(let id): showNotes(tag: nil, taskID: id)
        case .notesHotKey(let appWasActive):
            switch notesWindow.hotKeyAction(appWasActive) {
            case .open:
                if notesWindow.window != nil { notesWindow.bringToFront() }
                else { showNotes(tag: nil) }
            case .close: notesWindow.close()
            case .bringForward: notesWindow.bringToFront()
            }
        case .toggleNotes:
            if notesWindow.isVisible, notesWindow.window?.isOnActiveSpace == true { notesWindow.close() }
            else if notesWindow.isVisible { notesWindow.bringToFront() }
            else { showNotes(tag: nil) }
        case .agenda(let filter): agenda = filter
        case .shiftDay(let amount): shiftDay(amount)
        case .shiftMonth(let amount): shiftMonth(amount)
        case .toggleTasks: toggleTasks()
        case .toggleDayLog:
            if notesWindow.isVisible, notesWindow.window?.isOnActiveSpace == true { notesWindow.close() }
            else { notesWindow.showJournal(store: store, date: selectedDate) }
        case .rollover: rolloverToday()
        case .selectAdjacent(let amount): moveSelection(amount)
        case .toggleSelected:
            if let task = selectedTask { store.toggleTodo(task.id, on: task.date) }
        case .editSelected:
            guard let task = selectedTask else { return }
            tasksVisible = true
            requestedEdit = task.id
        case .deleteSelected:
            guard let task = selectedTask else { return }
            let neighbours = visibleTasks.map(\.task)
            let index = neighbours.firstIndex { $0.id == task.id }
            store.deleteTodo(task.id, on: task.date)
            interaction.selectedTaskID = index.flatMap { i in
                (i + 1 < neighbours.count ? neighbours[i + 1] : (i > 0 ? neighbours[i - 1] : nil))?.id
            }
        case .deselect: interaction.selectedTaskID = nil
        case .reveal(let id): reveal(date: store.locate(id)?.task.dueDate, taskID: id)
        case .export: exportJournal()
        case .backups: showingBackups = true
        case .settings: AppRouter.showSettings()
        case .quickCapture: AppRouter.showQuickCapture()
        }
    }

    private var selectedTask: ScheduledTask? { interaction.selectedTaskID.flatMap(store.locate) }

    private func sameDay(_ a: Date, _ b: Date) -> Bool { JournalDates.calendar.isDate(a, inSameDayAs: b) }

    private func reveal(date: Date?, taskID: UUID?) {
        AppRouter.presentMain()
        if let date { select(date) } else if taskID != nil { tasksVisible = true }
        interaction.selectedTaskID = taskID
        if let taskID { scrollTarget = taskID }
    }

    private func moveSelection(_ amount: Int) {
        let list = visibleTasks.map(\.task)
        guard !list.isEmpty else { return }
        tasksVisible = true
        interaction.activePane = .tasks
        if let id = interaction.selectedTaskID, let index = list.firstIndex(where: { $0.id == id }) {
            interaction.selectedTaskID = list[min(max(index + amount, 0), list.count - 1)].id
        } else {
            interaction.selectedTaskID = (amount > 0 ? list.first : list.last)?.id
        }
    }

    private func rolloverToday() {
        guard store.rolloverUnfinished(to: Date()) > 0 else {
            toast.show("没有逾期的事项")
            return
        }
        select(Date())
    }

    private func refreshOverview() {
        let now = Date()
        overdueCount = store.overdueCount(now: now)
        NSApp.dockTile.badgeLabel = overdueCount > 0 ? "\(overdueCount)" : nil
    }

    // MARK: - 头部与清单

    private var optionsMenu: some View {
        Menu {
            Button("新建待办") { commands.send(.newTodo) }
            Button("快速记录…") { commands.send(.quickCapture) }
            Button("插入链接…") { commands.send(.insertLink) }.disabled(store.isReadOnly)
            Divider()
            Button("搜索任务、日志与总结…") { commands.send(.search) }
            Button("笔记…") { commands.send(.notes) }
            Button("未完成事项…") { agenda = .unfinished }
            Button("即将截止…") { agenda = .upcoming }
            Button("已逾期…") { agenda = .overdue }
            if overdueCount > 0 {
                Button("把 \(overdueCount) 项逾期事项的截止日期改到今天") { rolloverToday() }
            }
            Divider()
            Toggle("隐藏已完成", isOn: $hideCompleted)
            Toggle("单击日期时展开待办清单", isOn: $clickExpands)
            Divider()
            Button("导出为文件夹…", action: exportJournal).disabled(store.isReadOnly)
            Button("备份与恢复…") { showingBackups = true }
            Button("设置…") { commands.send(.settings) }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: typography.pt(19))).foregroundStyle(Palette.muted)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 34, height: 34)
        .help("更多选项")
        .accessibilityLabel("更多选项")
    }

    private var dateHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(format(selectedDate, "M月d日"))
                        .font(.system(size: typography.pt(26), weight: .semibold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    if JournalDates.calendar.isDateInToday(selectedDate) {
                        Text("今天").font(.system(size: typography.pt(11), weight: .medium))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Palette.soft, in: Capsule())
                            .foregroundStyle(Palette.accent)
                    } else {
                        Button("回到今天") { select(Date()) }
                            .buttonStyle(HitAreaButtonStyle(compact: true)).font(.system(size: typography.pt(11), weight: .medium))
                            .foregroundStyle(Palette.accent).help("回到今天 · ⌘T")
                    }
                }
                Text(format(selectedDate, "yyyy年 · EEEE"))
                    .font(.system(size: typography.pt(12))).foregroundStyle(Palette.muted)
                    .lineLimit(1).fixedSize()
                overviewChip
            }
            Spacer()
            HStack(spacing: 12) {
                navigationButton("chevron.left", help: "前一天 · ⌥⌘←") { shiftDay(-1) }
                navigationButton("chevron.right", help: "后一天 · ⌥⌘→") { shiftDay(1) }
                navigationButton("text.alignleft", help: "当天日志 · ⌘J") { notesWindow.showJournal(store: store, date: selectedDate) }
                navigationButton("sidebar.left", help: "收起待办清单 · ⌘\\") { toggleTasks() }
            }
        }
        .padding(.vertical, 2)
    }

    /// 逾期事项的入口：查看，或一键把它们的截止日期改到今天。
    @ViewBuilder
    private var overviewChip: some View {
        if overdueCount > 0 {
            Menu {
                Button("查看已逾期事项（\(overdueCount)）…") { agenda = .overdue }
                Button("把 \(overdueCount) 项逾期事项的截止日期改到今天") { rolloverToday() }
            } label: {
                Label("逾期 \(overdueCount)", systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: typography.pt(11), weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Palette.deadline.opacity(0.14), in: Capsule())
                    .foregroundStyle(Palette.deadline)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("查看逾期事项")
        }
    }

    /// 清单顶部的数量可直接定位到对应任务，时间线不按日期分段。
    private var summaryBar: some View {
        let summary = store.taskSummary()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                summaryChip(summary.overdue, "逾期", tint: Palette.deadline, group: "overdue")
                summaryChip(summary.dueToday, "今天", tint: Palette.accent, group: "today", alwaysVisible: true)
                summaryChip(summary.open, "未完成", tint: Palette.muted, group: nil)
                summaryChip(orderedTasks.filter { $0.task.dueDate == nil }.count, "未设日期", tint: Palette.muted, group: "undated")
                Spacer(minLength: 0)
            }
            if summary.totalToday > 0 {
                HStack(spacing: 8) {
                    ProgressView(value: summary.todayFraction).tint(Palette.success)
                        .animation(Motion.quick, value: summary.doneToday)
                        .accessibilityLabel("今天的进度").accessibilityValue("\(summary.doneToday) / \(summary.totalToday)")
                    Text("今天 \(summary.doneToday)/\(summary.totalToday)")
                        .font(.system(size: typography.pt(11), weight: .medium, design: .monospaced)).foregroundStyle(Palette.muted).fixedSize()
                }
            }
        }
    }

    @ViewBuilder
    private func summaryChip(_ count: Int, _ title: String, tint: Color, group: String?, alwaysVisible: Bool = false) -> some View {
        // 今天与未完成始终显示；今天即使为零也可定位日期区间。
        if count > 0 || group == nil || alwaysVisible {
            Button {
                if group == "today" { select(Date()) }
                if let group { scrollGroup = group }
            } label: {
                HStack(spacing: 4) {
                    Text("\(count)").font(.system(size: typography.pt(13), weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(LocalizedStringKey(title)).font(.system(size: typography.pt(11)))
                }
                .foregroundStyle(count > 0 ? tint : Palette.muted)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(count > 0 ? tint.opacity(0.12) : Palette.soft.opacity(0.6), in: Capsule())
            }
            .buttonStyle(.plain)
            .raisedOnHover(radius: 10, enabled: group != nil)
            .disabled(group == nil)
            .help(group == nil ? "\(count) 项未完成" : "跳到\(title)的任务")
            .accessibilityLabel("\(count) 项\(title)")
        }
    }

    private var todoCard: some View {
        let all = store.tasks()
        let visible = orderedTasks
        let completed = all.filter(\.task.completed).count
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                TimelineMark().stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 18, height: 20).foregroundStyle(Palette.accent).accessibilityHidden(true)
                Text("待办清单").font(.system(size: typography.pt(16), weight: .semibold))
                    .foregroundStyle(interaction.activePane == .tasks ? Palette.accent : Palette.ink)
                Spacer()
                let hidden = hideCompleted ? completed : 0
                HStack(spacing: 6) {
                    if hidden > 0 {
                        Button { hideCompleted = false } label: {
                            Label("已隐藏 \(hidden) 项", systemImage: "eye.slash")
                                .font(.system(size: typography.pt(11)))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Palette.soft, in: Capsule())
                        }
                        .buttonStyle(.plain).foregroundStyle(Palette.accent).raisedOnHover(radius: 10)
                        .help("已完成的事项被隐藏，点击显示").accessibilityLabel("显示已隐藏的 \(hidden) 项已完成事项")
                    }
                }
            }
            summaryBar
            ScrollViewReader { proxy in
                ScrollView {
                    TaskTimelineView(store: store, tasks: orderedTasks, today: JournalDates.date(for: currentDayKey) ?? Date(),
                                     selectedDate: selectedDate, expanded: $expandedFinished, requestedEdit: $requestedEdit,
                                     navigate: select, selectTask: { interaction.activePane = .tasks }, next: { addingTodo = true })
                        .padding(.vertical, 12)
                        .onPreferenceChange(TaskRowGlobalFramesKey.self) { rowRegions.rows = $0 }
                }
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { rowRegions.viewport = proxy.frame(in: .global) }
                        .onChange(of: proxy.frame(in: .global)) { rowRegions.viewport = $0 }
                })
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo(TaskTimelineSection.dayID(Date()), anchor: .top)
                    }
                }
                .onChange(of: scrollTarget) { id in
                    if let id {
                        if let item = store.locate(id), item.task.completed {
                            expandedFinished.insert(id)
                            if let due = item.task.dueDate { select(due) }
                        }
                        DispatchQueue.main.async { withAnimation(Motion.quick) { proxy.scrollTo(id, anchor: .center) } }
                        scrollTarget = nil
                    }
                }
                .onChange(of: selectedDate) { date in
                    // 日志窗口开着：跟着主窗口换到同一天。
                    if notesWindow.isVisible { notesWindow.showJournal(store: store, date: date) }
                }
                .onChange(of: scrollGroup) { id in
                    if let id {
                        if id == "undated" {
                            withAnimation(Motion.quick) { proxy.scrollTo("undated", anchor: .top) }
                        } else if id == "today" {
                            withAnimation(Motion.quick) { proxy.scrollTo(TaskTimelineSection.dayID(Date()), anchor: .top) }
                        } else if let item = visible.first(where: { !$0.task.completed && (id == "overdue" ? ($0.task.effectiveDeadline ?? .distantFuture) < Date() : JournalDates.calendar.isDateInToday($0.task.dueDate ?? .distantPast)) }) {
                            withAnimation(Motion.quick) { proxy.scrollTo(item.id, anchor: .top) }
                        }
                        scrollGroup = nil
                    }
                }
                .onChange(of: requestedEdit) { id in
                    if let id {
                        if store.locate(id)?.task.completed == true { expandedFinished.insert(id) }
                        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .onChange(of: interaction.selectedTaskID) { id in
                    if interaction.suppressNextTaskScroll { interaction.suppressNextTaskScroll = false; return }
                    if let id { withAnimation(Motion.quick) { proxy.scrollTo(id) } }
                }
                // 空日期定位到省略段，不为日历浏览添加空刻度。
                .onChange(of: selectedDate) { _ in
                    DispatchQueue.main.async {
                        let sections = TaskTimelineSection.sections(for: orderedTasks, today: JournalDates.date(for: currentDayKey) ?? Date())
                        if let id = TaskTimelineSection.navigationID(for: selectedDate, in: sections) {
                            withAnimation(Motion.quick) { proxy.scrollTo(id, anchor: .top) }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            ObservingDraft(draft: todoDraft) { _ in TaskComposerRow(store: store, text: draft, focused: $addingTodo, options: $creationOptions,
                            defaultDate: selectedDate, submit: addTodo, cancel: { addingTodo = false }, previous: {
                if let newest = visible.max(by: { ($0.task.number ?? 0) < ($1.task.number ?? 0) }) {
                    addingTodo = false
                    requestedEdit = newest.id
                }
            }) }
        }
        .disabled(store.isReadOnly)
        .modifier(Card())
        .frame(maxHeight: .infinity)
    }

    // MARK: - 月历

    private var calendarCard: some View {
        let dates = JournalDates.monthGrid(displayedMonth, weekStart: weekStart)
        let dueByDay = store.calendarDeadlines
        let previews = dates.map { date in
            DeadlineDayCell.previewItems(dueItems: dueByDay[JournalDates.key(date)] ?? [], hideCompleted: hideCompleted)
        }
        let weekdays = DateFormatters.formatter(locale: locale).veryShortStandaloneWeekdaySymbols ?? []
        let ordered = (0..<7).map { weekdays[($0 + weekStart - 1) % 7] }
        return VStack(spacing: 12) {
            HStack {
                if !tasksVisible {
                    navigationButton("sidebar.left", help: "展开所选日期的待办清单 · ⌘\\") { toggleTasks() }
                    selectedDayChip
                }
                Button { showingMonthJumper = true } label: {
                    HStack(spacing: 4) {
                        Text(format(displayedMonth, "yyyy年 M月"))
                            .font(.system(size: typography.pt(16), weight: .semibold, design: .rounded))
                            .foregroundStyle(interaction.activePane == .calendar ? Palette.accent : Palette.ink)
                        Image(systemName: "chevron.down").font(.system(size: typography.pt(8), weight: .bold)).foregroundStyle(Palette.muted)
                    }
                }
                .buttonStyle(HitAreaButtonStyle(compact: true))
                .help("选择月份")
                .accessibilityLabel("选择月份，当前\(format(displayedMonth, "yyyy年M月"))")
                .popover(isPresented: $showingMonthJumper, arrowEdge: .bottom) {
                    MonthJumper(current: displayedMonth) { date in
                        displayedMonth = JournalDates.monthStart(date)
                        showingMonthJumper = false
                    }
                }
                Spacer()
                Button("今天") { select(Date()) }
                    .buttonStyle(HitAreaButtonStyle()).font(.system(size: typography.pt(11), weight: .medium))
                    .foregroundStyle(Palette.accent).help("回到今天 · ⌘T")
                Button("未完成") { agenda = .unfinished }.buttonStyle(HitAreaButtonStyle()).font(.system(size: typography.pt(11))).foregroundStyle(Palette.accent)
                Button { agenda = .all } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(HitAreaButtonStyle()).help("搜索 · ⌘F").accessibilityLabel("搜索")
                Button { commands.send(.notes) } label: { Image(systemName: "note.text") }
                    .buttonStyle(HitAreaButtonStyle()).help("笔记 · ⌘N").accessibilityLabel("笔记")
                navigationButton("chevron.left", help: "上个月") { shiftMonth(-1) }
                navigationButton("chevron.right", help: "下个月") { shiftMonth(1) }
                optionsMenu
            }
            GeometryReader { geometry in
                let metrics = CalendarGridMetrics(size: geometry.size, counts: previews.map(\.count), scale: typography.scale)
                ScrollView(.vertical) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(metrics.columnWidth), spacing: 6), count: 7), spacing: 6) {
                        ForEach(Array(ordered.enumerated()), id: \.offset) { _, weekday in
                            Text(weekday).font(.system(size: typography.pt(11), weight: .medium))
                                .foregroundStyle(Palette.muted).frame(height: metrics.weekdayHeight)
                        }
                        ForEach(Array(dates.enumerated()), id: \.element) { index, date in
                            DeadlineDayCell(store: store, date: date, selectedDate: selectedDate,
                                            displayedMonth: displayedMonth, height: metrics.weekHeights[index / 7],
                                            items: previews[index],
                                            select: { selectFromCalendar(date) },
                                            open: { selectFromCalendar(date, forceExpand: true); addingTodo = true },
                                            openLog: { selectFromCalendar(date); notesWindow.showJournal(store: store, date: date) },
                                            editTask: { item in
                                interaction.activePane = .calendar
                                NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
                                tasksVisible = true
                                interaction.selectedTaskID = item.id
                                requestedEdit = item.id
                            })
                        }
                    }
                    .padding(2).padding(.trailing, CalendarGridMetrics.scrollbarGutter)
                    .frame(width: geometry.size.width, alignment: .leading)
                }
            }
            .frame(minHeight: 120)
        }
        .background(MonthSwipeCatcher { shiftMonth($0) })
    }

    /// 清单收起、单击日期又不展开时，在这里确认当前选中的日期并可一键展开。
    private var selectedDayChip: some View {
        Button { toggleTasks() } label: {
            HStack(spacing: 5) {
                Text(selectedDate.relativeLabel).fontWeight(.semibold)
                let due = store.calendarDeadlines[JournalDates.key(selectedDate)] ?? []
                if !due.isEmpty {
                    Text("\(due.filter(\.task.isDone).count)/\(due.filter { !$0.task.isDropped }.count)").font(.system(size: typography.pt(10), design: .monospaced))
                }
            }
            .font(.system(size: typography.pt(11)))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Palette.soft, in: Capsule())
            .foregroundStyle(Palette.accent)
        }
        .buttonStyle(.plain)
        .help("所选日期，点击展开待办清单").accessibilityLabel("所选日期 \(format(selectedDate, "M月d日"))，展开待办清单")
    }

    private func selectFromCalendar(_ date: Date, forceExpand: Bool = false) {
        interaction.activePane = .calendar
        if !sameDay(date, selectedDate) {
            NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
            selectedDate = JournalDates.calendar.startOfDay(for: date)
        }
        if clickExpands || forceExpand { tasksVisible = true }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(spacing: 6) {
                if let error = store.errorMessage {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).lineLimit(2).help(error)
                    if !store.isReadOnly { Button("重试保存", action: store.save).buttonStyle(HitAreaButtonStyle()) }
                    Button("打开数据文件夹") { NSWorkspace.shared.open(store.directory) }.buttonStyle(HitAreaButtonStyle())
                } else {
                    Image(systemName: "bell.slash")
                    Text(reminders.status).lineLimit(2)
                }
                Spacer()
                if !reminders.status.isEmpty {
                    Button("通知设置") { if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) } }
                        .buttonStyle(HitAreaButtonStyle())
                }
            }
            .font(.system(size: typography.pt(11)))
            .foregroundStyle(Palette.deadline)
            .padding(.horizontal, 30).padding(.vertical, 8)
        }
    }

    private func navigationButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: typography.pt(11), weight: .medium))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(HitAreaButtonStyle()).foregroundStyle(Palette.muted).help(LocalizedStringKey(help)).accessibilityLabel(LocalizedStringKey(help))
    }

    private func select(_ date: Date) {
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        tasksVisible = true
        selectedDate = JournalDates.calendar.startOfDay(for: date)
        displayedMonth = JournalDates.monthStart(date)
    }

    private func toggleTasks() {
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        tasksVisible.toggle()
    }

    private func shiftDay(_ amount: Int) {
        if let date = JournalDates.calendar.date(byAdding: .day, value: amount, to: selectedDate) { select(date) }
    }

    private func shiftMonth(_ amount: Int) {
        if let date = JournalDates.calendar.date(byAdding: .month, value: amount, to: displayedMonth) { displayedMonth = date }
    }

    private func addTodo() {
        guard !store.isReadOnly else { return }
        todoDraft.flush()
        let added = store.commitDraft(on: selectedDate, options: creationOptions)
        if !added.isEmpty { creationOptions = TaskCreationOptions() }
        addingTodo = true
        scrollTarget = added.last?.id
        if added.contains(where: { $0.task.reminderMinutes != nil }) {
            Task { @MainActor in
                _ = await reminders.requestPermission()
                reminders.refresh()
            }
        }
    }

    private func format(_ date: Date, _ pattern: String) -> String {
        if locale.language.languageCode?.identifier == "en" {
            let templates = ["M月d日": "MMMd", "yyyy年 · EEEE": "yEEEE", "yyyy年 M月": "yMMMM", "yyyy年M月": "yMMMM"]
            return DateFormatters.formatter(locale: locale, template: templates[pattern] ?? pattern).string(from: date)
        }
        return DateFormatters.formatter(locale: locale, format: pattern).string(from: date)
    }

    /// 导出为文件夹：journal.json 加上日志里用到的全部图片。
    private func exportJournal() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Timeline 备份-\(JournalDates.key(Date()))"
        panel.canCreateDirectories = true
        panel.message = AppLocalized("将导出为一个文件夹，包含 journal.json 和日志图片（Images）。")
        panel.prompt = AppLocalized("导出")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportFolder(to: url)
            toast.show("已导出到「\(url.lastPathComponent)」", actionTitle: "显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } catch { actionError = error.localizedDescription }
    }
}
