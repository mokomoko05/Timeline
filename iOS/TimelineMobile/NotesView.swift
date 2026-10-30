import SwiftUI
import TimelineCore

/// 笔记：标签（笔记本）和有笔记的任务，和 Mac 笔记窗口的左栏一致。
struct NotesView: View {
    let store: JournalStore
    @ObservedObject var feed: TabFeed
    let sync: SyncModel
    @State private var query = ""

    enum Destination: Hashable {
        /// `reveal`：打开后滚到这条笔记并闪一下（在日记里点了日志的标签或关联的待办）。
        case task(UUID, reveal: UUID? = nil)
        case tag(String, reveal: UUID? = nil)
    }

    var body: some View {
        NavigationStack {
            List {
                let tags = store.allTags().filter { matches("#" + $0.name) && ($0.noteCount > 0 || $0.taskCount > 0) }
                if !tags.isEmpty {
                    Section("标签") {
                        ForEach(tags) { tag in
                            NavigationLink(value: Destination.tag(tag.name)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("#" + tag.name).font(.body.weight(.semibold)).foregroundStyle(Palette.accent)
                                    HStack {
                                        Text("\(tag.taskCount) 个待办 · \(tag.noteCount) 条笔记")
                                        Spacer()
                                        if tag.lastActivity > .distantPast { Text(relative(tag.lastActivity)) }
                                    }
                                    .font(.caption).foregroundStyle(Palette.muted)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
                let topics = store.noteTopics().filter { matches($0.title) || $0.number.map { matches("#\($0)") } == true }
                if !topics.isEmpty {
                    Section("任务") {
                        ForEach(topics) { topic in
                            NavigationLink(value: Destination.task(topic.id)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        if let number = topic.number { Text("#\(number)").font(.subheadline.monospacedDigit()).foregroundStyle(Palette.muted) }
                                        Text(topic.title).font(.body.weight(.medium))
                                            .foregroundStyle(topic.completed || topic.deleted ? Palette.muted : Palette.ink)
                                            .strikethrough(topic.deleted)
                                            .lineLimit(2)
                                    }
                                    HStack(spacing: 8) {
                                        Text("\(topic.count) 条")
                                        if topic.imageCount > 0 { Label("\(topic.imageCount)", systemImage: "photo") }
                                        if topic.completed { Text("已完成").foregroundStyle(Palette.success) }
                                        Spacer()
                                        Text(relative(topic.lastActivity))
                                    }
                                    .font(.caption).foregroundStyle(Palette.muted)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .overlay { if store.noteTopics().isEmpty && store.allTags().isEmpty { ContentUnavailableView("还没有笔记", systemImage: "text.bubble") } }
            .searchable(text: $query, prompt: "搜索任务或 #标签")
            .navigationTitle("笔记")
            .toolbar { SyncToolbarItems(sync: sync) }
            .notesDestinations(store)
            .syncOnRefresh(sync)
        }
    }

    private func matches(_ text: String) -> Bool {
        query.isEmpty || text.localizedStandardContains(query)
    }

    private func relative(_ date: Date) -> String {
        DayText.relative(date) ?? DayText.short(date)
    }
}

extension View {
    /// 从日记里点标签或关联的待办进来：等那条笔记排进来，再滚过去。
    func revealing(_ reveal: UUID?, proxy: ScrollViewProxy) -> some View {
        task {
            guard let reveal else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
            proxy.scrollTo(reveal.uuidString, anchor: .center)
        }
    }

    /// 笔记里的任务页、标签页：笔记页和日记页（点日志的标签）都能推进来。
    func notesDestinations(_ store: JournalStore) -> some View {
        navigationDestination(for: NotesView.Destination.self) { destination in
            switch destination {
            case .task(let id, let reveal): TaskPage(store: store, id: id, reveal: reveal)
            case .tag(let name, let reveal): TagPage(store: store, name: name, reveal: reveal)
            }
        }
    }
}

/// 一个任务的页面：标题、截止、专注、笔记数和标签，操作按钮，下面是它的笔记时间线。
struct TaskPage: View {
    @ObservedObject var store: JournalStore
    let id: UUID
    var reveal: UUID?
    @State private var editing = false
    @State private var composing = false
    @State private var edges = ScrollEdges()
    @State private var positions = LogPositions()

    var body: some View {
        let item = store.locate(id)
        let topic = store.noteTopic(for: id)
        let notes = store.notes(for: id)
        ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 0) {
            Color.clear.frame(height: 0).scrollEdgeMarker(.top)
            VStack(alignment: .leading, spacing: 18) {
                header(item: item, topic: topic, noteCount: notes.count)
                if let board = store.board(for: .task(id)), board.hasContent {
                    NavigationLink { BoardPage(store: store, id: board.id) } label: { BoardPreview(board: board) }
                        .buttonStyle(.plain)
                }
                if notes.isEmpty {
                    ContentUnavailableView("还没有笔记", systemImage: "text.bubble", description: Text("点右上角记一笔")).padding(.top, 20)
                } else {
                    LogTimeline(store: store, logs: notes, groupByDay: true, showsTask: false, reveal: reveal)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, notes.isEmpty ? 16 : EntryRail.width + 8)
            .padding(.bottom, 100)
            Color.clear.frame(height: 0).scrollEdgeMarker(.bottom)
          }
          .coordinateSpace(name: LogPositions.space)
        }
        .startsAtBottom(reveal == nil && !notes.isEmpty, edges: edges)
        .markdownScrolling(proxy)
        .trackScrollEdges(edges, proxy: proxy)
        // 从上到下是从前到后：打开时停在最下面最新的笔记；右边的节奏条代替滚动条。
        .entryRail(NotesRhythm.marks(notes), ticks: NotesRhythm.ticks(notes), positions: positions, edges: edges)
        .revealing(reveal, proxy: proxy)
        }
        .background(Palette.background)
        .overlay(alignment: .bottomTrailing) {
            FloatingButtons(edges: edges, compose: item == nil ? nil : { composing = true })
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if item != nil {
                    Button { editing = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("编辑待办")
                }
            }
        }
        .logActionsHost(store)
        .sheet(isPresented: $editing) { TaskEditSheet(store: store, id: id) }
        .floatingEditor(isPresented: $composing) { ComposeSheet(store: store, taskID: id) }
        .onReceive(NotificationCenter.default.publisher(for: PerfProbe.action)) { note in
            if note.object as? String == "editTask" { editing = true }
            if note.object as? String == "closeSheet" { editing = false }
        }
    }

    @ViewBuilder private func header(item: ScheduledTask?, topic: JournalStore.NoteTopic?, noteCount: Int) -> some View {
        let task = item?.task
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let number = task?.number ?? topic?.number {
                    Text("#\(number)").font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(Palette.accent)
                }
                Text(task.map { TaskText.rendered($0.title) } ?? AttributedString(topic?.title ?? L("已删除的任务")))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(task?.completed == true ? Palette.muted : Palette.ink)
            }
            FlowLayout(spacing: 8) {
                if let range = task?.timeRangeLabel, let start = task?.timelineDate {
                    Label((DayText.relative(start) ?? DayText.short(start)) + " " + range, systemImage: "clock")
                } else if let due = task?.dueDate {
                    Label(LF("截止 %@", (DayText.relative(due) ?? DayText.short(due)) + (task!.dueHasTime ? " " + DayText.time(due) : "")), systemImage: "clock")
                        .foregroundStyle(task!.effectiveDeadline.map { $0 < Date() } == true && !task!.completed ? Palette.deadline : Palette.muted)
                }
                if let seconds = task?.focusSeconds, seconds >= 60 { Label(LF("已专注 %@", Duration.brief(seconds)), systemImage: "hourglass") }
                Text("\(noteCount) 条笔记")
                if task?.isDone == true { Label("已完成", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.success) }
                if task?.isDropped == true { Label("已放弃", systemImage: "xmark.circle").foregroundStyle(Palette.muted) }
                if item == nil { Text("任务已删除").foregroundStyle(Palette.danger) }
                ForEach(task?.tags ?? topic?.tags ?? [], id: \.self) { Chip(text: "#" + $0, filled: false) }
            }
            .font(.subheadline)
            .foregroundStyle(Palette.muted)
            if let item {
                HStack(spacing: 10) {
                    Button {
                        withAnimation { store.toggleTodo(id, on: item.date) }
                    } label: {
                        Label(item.task.isDone ? "已完成" : "完成", systemImage: item.task.isDone ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(Palette.success)
                    .disabled(item.task.isDropped)
                    if store.board(for: .task(id))?.hasContent != true {
                        Button {
                            store.ensureBoard(for: .task(id))
                        } label: { Label("工作板", systemImage: "doc.badge.plus") }
                            .buttonStyle(.bordered)
                    }
                }
                .font(.subheadline)
            }
        }
        .padding(.top, 8)
    }
}

/// 标签笔记本：带这个标签的待办，和它们名下的笔记。
struct TagPage: View {
    @ObservedObject var store: JournalStore
    let name: String
    var reveal: UUID?
    @State private var composing = false
    @State private var edges = ScrollEdges()
    @State private var positions = LogPositions()

    var body: some View {
        let tasks = store.tasks(taggedWith: name)
        let open = TaskSortMode.deadline.sorted(tasks.filter { !$0.task.completed })
        let notes = store.notes(forTag: name)
        ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 0) {
            Color.clear.frame(height: 0).scrollEdgeMarker(.top)
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("#" + name).font(.title2.weight(.bold)).foregroundStyle(Palette.accent)
                    Text("\(tasks.count) 个待办 · \(open.count) 未完成 · \(notes.count) 条笔记")
                        .font(.subheadline).foregroundStyle(Palette.muted)
                }
                .padding(.top, 8)
                if let board = store.board(for: .tag(name)), board.hasContent {
                    NavigationLink { BoardPage(store: store, id: board.id) } label: { BoardPreview(board: board) }
                        .buttonStyle(.plain)
                }
                if !open.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("待办").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                        ForEach(open) { item in
                            NavigationLink(value: NotesView.Destination.task(item.id)) {
                                HStack(spacing: 10) {
                                    Dot(color: item.task.priority.color, size: 8)
                                    Text(TaskText.rendered(item.task.title)).foregroundStyle(Palette.ink).lineLimit(1)
                                    Spacer()
                                    if let due = item.task.dueDate {
                                        Text(DayText.relative(due) ?? DayText.short(due)).font(.caption).foregroundStyle(Palette.muted)
                                    }
                                }
                                .padding(.vertical, 10).padding(.horizontal, 12)
                                .card()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !notes.isEmpty {
                    LogTimeline(store: store, logs: notes, groupByDay: true, reveal: reveal)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, notes.isEmpty ? 16 : EntryRail.width + 8)
            .padding(.bottom, 100)
            Color.clear.frame(height: 0).scrollEdgeMarker(.bottom)
          }
          .coordinateSpace(name: LogPositions.space)
        }
        .startsAtBottom(reveal == nil && !notes.isEmpty, edges: edges)
        .markdownScrolling(proxy)
        .trackScrollEdges(edges, proxy: proxy)
        // 从上到下是从前到后：打开时停在最下面最新的笔记；右边的节奏条代替滚动条。
        .entryRail(NotesRhythm.marks(notes), ticks: NotesRhythm.ticks(notes), positions: positions, edges: edges)
        .revealing(reveal, proxy: proxy)
        }
        .background(Palette.background)
        .overlay(alignment: .bottomTrailing) { FloatingButtons(edges: edges) { composing = true } }
        .navigationBarTitleDisplayMode(.inline)
        .logActionsHost(store)
        .floatingEditor(isPresented: $composing) { ComposeSheet(store: store, tags: [name]) }
    }
}

/// 工作板入口卡片：标题和前几行。
struct BoardPreview: View {
    let board: Board

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.text").foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("工作板").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                Text(board.markdown.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#-*> []").union(.whitespaces)) }
                    .filter { !$0.isEmpty }.prefix(3).joined(separator: " · "))
                    .font(.caption).foregroundStyle(Palette.muted).lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
        }
        .padding(12)
        .card()
    }
}

/// 改标题、标签、截止日期、重复和优先级。
struct TaskEditSheet: View {
    @ObservedObject var store: JournalStore
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var tags = ""
    @State private var hasTime = false
    @State private var timing = TaskTimeDraft(task: Todo(title: ""))

    var body: some View {
        NavigationStack {
            if let item = store.locate(id) {
                Form {
                    Section {
                        TextField("标题", text: $title, axis: .vertical)
                        TextField("标签（空格分隔）", text: $tags).textInputAutocapitalization(.never)
                    }
                    Section("安排") {
                        Toggle("设置任务时间", isOn: $hasTime)
                        if hasTime { TaskTimeFields(timing: $timing) }
                        Picker("重复", selection: Binding(get: { item.task.repeatRule }, set: { rule in
                            store.updateTodo(id, scheduledDate: item.date, dueDate: item.task.dueDate, dueHasTime: item.task.dueHasTime,
                                             reminderMinutes: item.task.reminderMinutes, repeatRule: rule)
                        })) { ForEach(RepeatRule.allCases) { Text(L($0.title)).tag($0) } }
                        Picker("优先级", selection: Binding(get: { item.task.priority }, set: { store.setPriority($0, for: id) })) {
                            ForEach(TaskPriority.allCases) { Text(L($0.title)).tag($0) }
                        }
                    }
                    Section {
                        Button(item.task.isDropped ? "恢复待办" : "放弃待办") { store.dropTodo(id, on: item.date) }.disabled(item.task.isDone)
                        Button("删除待办", role: .destructive) { UndoToast.deleteTodo(id, on: item.date, store: store); dismiss() }
                    }
                }
                .navigationTitle("编辑待办")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { commit(item); dismiss() }.disabled(hasTime && !timing.isValid) }
                }
                .onReceive(NotificationCenter.default.publisher(for: PerfProbe.action)) { note in
                    switch note.object as? String {
                    case "taskInterval": hasTime = true; timing.mode = .interval
                    case "taskIntervalStart": timing.start = timing.end.addingTimeInterval(-7200)
                    case "taskIntervalEnd": timing.end = timing.start.addingTimeInterval(5400)
                    case "taskIntervalSave":
                        commit(item)
                        print("[perf] TASK_INTERVAL \(store.locate(id)?.task.timeRange != nil ? "PASS" : "FAIL")")
                        dismiss()
                    default: break
                    }
                }
                .onAppear {
                    title = item.task.title
                    tags = item.task.tags.map { "#" + $0 }.joined(separator: " ")
                    hasTime = item.task.dueDate != nil
                    timing = TaskTimeDraft(task: item.task)
                }
            } else {
                ContentUnavailableView("待办已删除", systemImage: "trash")
            }
        }
    }

    private func commit(_ item: ScheduledTask) {
        if title != item.task.title, title.nilIfEmpty != nil { store.renameTodo(id, title: title, on: item.date) }
        guard let current = store.locate(id) else { return }
        let parsed = TagText.parseList(tags)
        store.updateTodo(id, scheduledDate: current.date, dueDate: hasTime ? timing.end : nil, dueHasTime: timing.hasTime,
                         reminderMinutes: current.task.reminderMinutes, repeatRule: current.task.repeatRule, tags: parsed,
                         startDate: .some(hasTime ? timing.startDate : nil))
        store.save()
    }
}

/// 自动换行的横排（标签、元信息）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty, current.width + spacing + size.width > width {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing * 0.6)
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
