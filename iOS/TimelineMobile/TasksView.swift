import SwiftUI
import TimelineCore

/// 待办时间轴：和 Mac 主界面一样，左边一根时间线，按截止日期分组；逾期的排最前，今天标出现在的时刻，
/// 已完成的在当天收成一行，没有日期的排在最后。同一天里按手动顺序（和 Mac 共用），
/// 按住左边的圆点可以拖动：在同一天里调整先后，拖到别的日期就改截止日期。
struct TasksView: View {
    @ObservedObject var store: JournalStore
    let sync: SyncModel
    @State private var adding = false
    @State private var query = ""
    @State private var expandedDone: Set<String> = []
    @State private var path: [UUID] = []
    @State private var frames = RowFrames()
    @GestureState private var drag: TaskDrag?

    private static let space = "taskTimeline"

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if query.isEmpty { TaskHeader(store: store) }
                    timeline
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .scrollDisabled(drag != nil)
            .background(Palette.background)
            .searchable(text: $query, prompt: "搜索待办或 #标签")
            .navigationTitle("待办")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { TaskPage(store: store, id: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $adding) { AddTaskSheet(store: store) }
            .onReceive(NotificationCenter.default.publisher(for: PerfProbe.openEditor)) { note in
                if note.object as? String == "task" { adding = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: ReminderScheduler.revealTask)) { note in
                if let id = note.object as? UUID, store.locate(id) != nil { path = [id] }
            }
            .syncOnRefresh(sync)
            .safeAreaInset(edge: .bottom) { FocusBar() }
        }
    }

    // MARK: 时间轴的行

    private enum Row: Identifiable {
        case day(key: String, date: Date?, title: String, subtitle: String, kind: DayKind)
        case task(ScheduledTask, group: String)
        case now(Date, group: String)
        case doneSummary(key: String, count: Int)
        case empty(group: String)

        var id: String {
            switch self {
            case .day(let key, _, _, _, _): return "day-" + key
            case .task(let item, _): return item.id.uuidString
            case .now: return "now"
            case .doneSummary(let key, _): return "done-" + key
            case .empty: return "empty"
            }
        }

        /// 这一行属于哪个分组：日期键、"overdue" 或 "undated"。
        var group: String {
            switch self {
            case .day(let key, _, _, _, _): return key
            case .task(_, let group), .now(_, let group), .empty(let group): return group
            case .doneSummary(let key, _): return key
            }
        }

        var isHeader: Bool { if case .day = self { return true } else { return false } }

        /// 可以参与排序的未完成任务。
        var openTask: ScheduledTask? {
            if case .task(let item, _) = self, !item.task.completed { return item }
            return nil
        }
    }

    private enum DayKind { case overdue, today, future, undated }

    private var rows: [Row] {
        let now = Date()
        let calendar = JournalDates.calendar
        let today = calendar.startOfDay(for: now)
        let all = store.tasks(matching: query)
        var rows: [Row] = []

        // 逾期的先按日期、同一天里按手动顺序。
        let overdue = all.filter { !$0.task.completed && ($0.task.effectiveDeadline.map { $0 < now } ?? false) && calendar.startOfDay(for: $0.task.dueDate!) < today }
            .sorted { a, b in
                let dayA = calendar.startOfDay(for: a.task.dueDate!), dayB = calendar.startOfDay(for: b.task.dueDate!)
                return dayA != dayB ? dayA < dayB : ScheduledTask.listOrder(a, b)
            }
        if !overdue.isEmpty {
            rows.append(.day(key: "overdue", date: nil, title: L("逾期"), subtitle: LF("%lld 项", overdue.count), kind: .overdue))
            rows += overdue.map { .task($0, group: "overdue") }
        }

        // 今天起有截止日期的：按天分组。
        let dated = all.filter { item in
            guard let due = item.task.dueDate else { return false }
            return calendar.startOfDay(for: due) >= today && !item.task.isDropped
        }
        var byDay = Dictionary(grouping: dated) { calendar.startOfDay(for: $0.task.dueDate!) }
        if query.isEmpty, byDay[today] == nil { byDay[today] = [] }
        for day in byDay.keys.sorted() {
            let items = byDay[day] ?? []
            let open = items.filter { !$0.task.completed }.sorted(by: ScheduledTask.listOrder)
            let done = items.filter(\.task.completed)
            let key = JournalDates.key(day)
            let isToday = calendar.isDate(day, inSameDayAs: today)
            let relative = DayText.relative(day).map { $0 + " · " } ?? ""
            rows.append(.day(key: key, date: day, title: DayText.short(day), subtitle: relative + DayText.weekday(day),
                             kind: isToday ? .today : .future))
            var placedNow = !isToday
            for item in open {
                if !placedNow, item.task.dueHasTime, let due = item.task.dueDate, due > now {
                    rows.append(.now(now, group: key))
                    placedNow = true
                }
                rows.append(.task(item, group: key))
            }
            if !placedNow, open.contains(where: \.task.dueHasTime) { rows.append(.now(now, group: key)) }
            if !done.isEmpty {
                rows.append(.doneSummary(key: key, count: done.count))
                if expandedDone.contains(key) { rows += done.map { .task($0, group: key) } }
            }
            if isToday, open.isEmpty, done.isEmpty { rows.append(.empty(group: key)) }
        }

        let undated = all.filter { $0.task.dueDate == nil && !$0.task.completed }.sorted(by: ScheduledTask.listOrder)
        if !undated.isEmpty {
            rows.append(.day(key: "undated", date: nil, title: "—", subtitle: L("未设日期"), kind: .undated))
            rows += undated.map { .task($0, group: "undated") }
        }
        return rows
    }

    private var timeline: some View {
        let rows = rows
        let plan = drag.flatMap { dropPlan($0, rows: rows) }
        // 不用 LazyVStack：按真实高度滚动，滚动条不会错位。
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let dragged = drag?.id == row.openTask?.id && drag != nil
                rowView(row, hasPrevious: index > 0, hasNext: index < rows.count - 1)
                    .background {
                        GeometryReader { geometry in
                            let frame = geometry.frame(in: .named(Self.space))
                            Color.clear
                                .onAppear { frames.values[row.id] = frame }
                                .onChange(of: frame) { _, value in frames.values[row.id] = value }
                        }
                    }
                    .offset(y: dragged ? drag!.translation : 0)
                    .scaleEffect(dragged ? 1.02 : 1)
                    .shadow(color: .black.opacity(dragged ? 0.18 : 0), radius: 10, y: 4)
                    .zIndex(dragged ? 1 : 0)
                    .opacity(drag != nil && !dragged && row.isHeader ? 0.7 : 1)
            }
        }
        .coordinateSpace(name: Self.space)
        .overlay(alignment: .topLeading) {
            if let plan {
                // 放下的位置：一根横线，放不下（拖进逾期分组）时是红色。
                Capsule()
                    .fill(plan.valid ? Palette.accent : Palette.danger)
                    .frame(height: 3)
                    .padding(.leading, RailRow<EmptyView, EmptyView>.labelWidth + 8)
                    .offset(y: plan.lineY - 1.5)
                    .allowsHitTesting(false)
            }
        }
        .animation(.snappy(duration: 0.2), value: plan?.lineY)
        .sensoryFeedback(.selection, trigger: plan?.lineY)
        .sensoryFeedback(.impact(weight: .medium), trigger: drag?.id) { old, new in old == nil && new != nil }
        .overlay {
            if rows.isEmpty { ContentUnavailableView("没有找到", systemImage: "magnifyingglass").padding(.top, 60) }
        }
    }

    @ViewBuilder private func rowView(_ row: Row, hasPrevious: Bool, hasNext: Bool) -> some View {
        switch row {
        case .day(_, _, let title, let subtitle, let kind):
            let color: Color = kind == .overdue ? Palette.deadline : (kind == .today ? Palette.accent : Palette.muted)
            RailRow(label: kind == .undated ? "" : title, labelColor: color, hasPrevious: hasPrevious, hasNext: hasNext, nodeY: 14) {
                if kind == .today { Dot(color: color, size: 7, ring: true) }
                else if kind == .undated { Rectangle().fill(Palette.line).frame(width: 12, height: 1.5).background(Palette.background) }
                else { Circle().stroke(color, lineWidth: 1.5).frame(width: 9, height: 9).background(Circle().fill(Palette.background)) }
            } content: {
                Text(subtitle)
                    .font(.subheadline.weight(kind == .today ? .semibold : .regular))
                    .foregroundStyle(color)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
            }
            .padding(.top, hasPrevious ? 14 : 0)
        case .task(let item, _):
            RailRow(label: timeLabel(item.task), labelColor: item.task.dueHasTime ? Palette.accent : Palette.muted,
                    hasPrevious: hasPrevious, hasNext: hasNext, nodeY: 22) {
                Dot(color: item.task.completed ? Palette.muted : item.task.priority.color, size: drag?.id == item.id ? 13 : 9,
                    ring: item.task.priority == .urgent || item.task.priority == .high)
                    .animation(.snappy, value: drag?.id == item.id)
            } content: {
                TaskCard(store: store, item: item) { path.append(item.id) }
                    .padding(.bottom, 8)
            }
            .overlay(alignment: .topLeading) {
                // 左边时间和圆点这一块是拖动把手：按住一下再拖。
                if !item.task.completed, query.isEmpty {
                    Color.clear
                        .frame(width: RailRow<EmptyView, EmptyView>.labelWidth + RailRow<EmptyView, EmptyView>.railWidth + 12, height: 48)
                        .contentShape(Rectangle())
                        .gesture(reorderGesture(item))
                }
            }
        case .now(let date, _):
            RailRow(label: DayText.time(date), labelColor: Palette.accent, hasPrevious: hasPrevious, hasNext: hasNext, nodeY: 8) {
                Circle().fill(Palette.accent).frame(width: 6, height: 6)
            } content: {
                Rectangle().fill(Palette.accent.opacity(0.6)).frame(height: 1).padding(.top, 7).padding(.bottom, 8)
            }
        case .doneSummary(let key, let count):
            RailRow(hasPrevious: hasPrevious, hasNext: hasNext, nodeY: 12) {
                EmptyView()
            } content: {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if expandedDone.contains(key) { expandedDone.remove(key) } else { expandedDone.insert(key) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("已完成 \(count) 项")
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                            .rotationEffect(.degrees(expandedDone.contains(key) ? 90 : 0))
                    }
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }
        case .empty:
            RailRow(hasPrevious: hasPrevious, hasNext: hasNext, nodeY: 12) { EmptyView() } content: {
                Text("今天没有待办").font(.footnote).foregroundStyle(Palette.muted).padding(.bottom, 10)
            }
        }
    }

    private func timeLabel(_ task: Todo) -> String {
        guard let due = task.dueDate else { return "" }
        let calendar = JournalDates.calendar
        let today = calendar.startOfDay(for: Date())
        if calendar.startOfDay(for: due) < today { return DayText.short(due) }
        return task.dueHasTime ? DayText.time(due) : L("全天")
    }

    // MARK: 拖动排序

    /// 按住圆点 0.3 秒后跟着手指走；松手时按落点重新排序或改日期。
    private func reorderGesture(_ item: ScheduledTask) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
            .updating($drag) { value, state, _ in
                guard case .second(true, let movement) = value else { return }
                let start = frames.values[item.id.uuidString]?.midY ?? 0
                state = TaskDrag(id: item.id, translation: movement?.translation.height ?? 0,
                                 y: movement?.location.y ?? start)
            }
            .onEnded { value in
                guard case .second(true, let movement?) = value else { return }
                let final = TaskDrag(id: item.id, translation: movement.translation.height, y: movement.location.y)
                guard let plan = dropPlan(final, rows: rows), plan.valid, plan.changes else { return }
                withAnimation(.snappy(duration: 0.25)) { store.moveTask(item.id, to: plan.day, order: plan.order) }
                store.save()
            }
    }

    private struct DropPlan {
        var lineY: CGFloat
        var valid: Bool
        var changes: Bool
        var day: Date?
        var order: [UUID]
    }

    /// 手指在 `drag.y` 松开的话：插在哪两行之间、属于哪个分组、分组里的新顺序。
    private func dropPlan(_ drag: TaskDrag, rows: [Row]) -> DropPlan? {
        guard let dragged = rows.first(where: { $0.openTask?.id == drag.id }), let item = dragged.openTask else { return nil }
        let others = rows.filter { $0.openTask?.id != drag.id }.compactMap { row in frames.values[row.id].map { (row, $0) } }
        guard !others.isEmpty else { return nil }
        let position = others.filter { $0.1.midY < drag.y }.count
        // 落在某个日期标题之前，算上一个分组的末尾；否则算后面那一行的分组。
        let group: String
        if position < others.count, !others[position].0.isHeader {
            group = others[position].0.group
        } else if position > 0 {
            group = others[position - 1].0.group
        } else {
            group = others[0].0.group
        }
        let lineY = position < others.count ? others[position].1.minY - 2 : others[others.count - 1].1.maxY + 2
        var order = others.prefix(position).compactMap { $0.0.group == group ? $0.0.openTask?.id : nil }
        order.append(item.id)
        order += others.dropFirst(position).compactMap { $0.0.group == group ? $0.0.openTask?.id : nil }
        let calendar = JournalDates.calendar
        let day: Date?
        let valid: Bool
        switch group {
        case "overdue":
            // 逾期分组没有一个确定的日期：只能在里面调整先后。
            valid = dragged.group == "overdue"
            day = item.task.dueDate.map { calendar.startOfDay(for: $0) }
        case "undated":
            valid = true
            day = nil
        default:
            day = JournalDates.date(for: group)
            valid = day != nil
        }
        let current = rows.filter { $0.group == dragged.group }.compactMap { $0.openTask?.id }
        let changes = group != dragged.group || order != current
        return DropPlan(lineY: lineY, valid: valid, changes: changes, day: day, order: order)
    }
}

/// 正在拖的任务：手指相对起点的位移，和手指在时间轴里的位置。
private struct TaskDrag: Equatable {
    var id: UUID
    var translation: CGFloat
    var y: CGFloat
}

/// 各行在时间轴里的位置。只在拖动时读，放在引用类型里，更新它不会让界面重算。
private final class RowFrames {
    var values: [String: CGRect] = [:]
}

/// 顶部：今天的日期、逾期 / 今天 / 未完成 / 未设日期的数量，和今天的完成进度。
private struct TaskHeader: View {
    @ObservedObject var store: JournalStore

    var body: some View {
        let now = Date()
        let calendar = JournalDates.calendar
        let tasks = store.tasks()
        let open = tasks.filter { !$0.task.completed }
        let overdue = open.filter { $0.task.effectiveDeadline.map { $0 < now } ?? false }.count
        let todayTasks = tasks.filter { $0.task.dueDate.map(calendar.isDateInToday) ?? false && !$0.task.isDropped }
        let todayDone = todayTasks.filter(\.task.isDone).count
        let undated = open.filter { $0.task.dueDate == nil }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(now.formatted(.dateTime.month(.defaultDigits).day()))
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Palette.ink)
                Chip(text: L("今天"))
                Spacer()
            }
            Text(now.formatted(.dateTime.year()) + " · " + DayText.weekday(now))
                .font(.subheadline).foregroundStyle(Palette.muted)
            HStack(spacing: 6) {
                if overdue > 0 { Chip(text: LF("%lld 逾期", overdue), color: Palette.deadline) }
                Chip(text: LF("%lld 今天", todayTasks.count - todayDone), color: Palette.accent)
                Chip(text: LF("%lld 未完成", open.count), color: Palette.muted)
                if undated > 0 { Chip(text: LF("%lld 未设日期", undated), color: Palette.muted) }
            }
            if !todayTasks.isEmpty {
                HStack(spacing: 10) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.line.opacity(0.6))
                            Capsule().fill(Palette.success)
                                .frame(width: geometry.size.width * CGFloat(todayDone) / CGFloat(max(1, todayTasks.count)))
                        }
                    }
                    .frame(height: 5)
                    Text("今天 \(todayDone)/\(todayTasks.count)").font(.caption).foregroundStyle(Palette.muted).monospacedDigit()
                }
            }
        }
        .padding(.top, 8)
    }
}

/// 时间轴上的一张待办卡片：点卡片打开笔记，点右边的圆圈完成，长按是完整的操作菜单。
struct TaskCard: View {
    @ObservedObject var store: JournalStore
    let item: ScheduledTask
    let open: () -> Void
    @State private var sheet: TaskSheet?

    var body: some View {
        let task = item.task
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(TaskText.rendered(task.title))
                    .font(.body.weight(task.completed ? .regular : .medium))
                    .foregroundStyle(task.completed ? Palette.muted : Palette.ink)
                    .strikethrough(task.completed, color: Palette.muted)
                    .multilineTextAlignment(.leading)
                TaskMeta(store: store, task: task)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { store.toggleTodo(item.id, on: item.date) }
            } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : (task.isDropped ? "xmark.circle" : "circle"))
                    .font(.title3)
                    .foregroundStyle(task.isDone ? Palette.success : Palette.muted)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 8)
        .card(highlighted: store.focusTaskID == item.id)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: open)
        .contextMenu { TaskActions(store: store, item: item) { sheet = $0 } }
        .sheet(item: $sheet) { TaskSheetView(store: store, id: item.id, sheet: $0) }
    }
}

/// 长按菜单打开的面板。
enum TaskSheet: String, Identifiable {
    case date, edit, note, focus
    var id: String { rawValue }
}

struct TaskSheetView: View {
    @ObservedObject var store: JournalStore
    let id: UUID
    let sheet: TaskSheet

    var body: some View {
        switch sheet {
        case .date: TaskDateSheet(store: store, id: id)
        case .edit: TaskEditSheet(store: store, id: id)
        case .note: ComposeSheet(store: store, taskID: id)
        case .focus: FocusStartSheet(store: store, taskID: id)
        }
    }
}
/// 标签、编号、笔记数、专注时长、重复。
struct TaskMeta: View {
    @ObservedObject var store: JournalStore
    let task: Todo

    var body: some View {
        let notes = store.noteCount(for: task.id)
        let hasBoard = store.board(for: .task(task.id))?.hasContent == true
        if !task.tags.isEmpty || notes > 0 || task.focusSeconds >= 60 || task.repeatRule != .none || hasBoard {
            HStack(spacing: 8) {
                ForEach(task.tags, id: \.self) { Text("#" + $0).foregroundStyle(Palette.accent) }
                if notes > 0 { Label("\(notes)", systemImage: "text.bubble") }
                if hasBoard { Image(systemName: "doc.text") }
                if task.focusSeconds >= 60 { Label(Duration.brief(task.focusSeconds), systemImage: "timer") }
                if task.repeatRule != .none { Label(L(task.repeatRule.title), systemImage: "repeat") }
            }
            .font(.caption)
            .foregroundStyle(Palette.muted)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
        }
    }
}

/// 长按菜单：和 Mac 右键菜单一样的操作，外加改日期和开始专注。
struct TaskActions: View {
    @ObservedObject var store: JournalStore
    @EnvironmentObject private var focus: FocusTimer
    let item: ScheduledTask
    let present: (TaskSheet) -> Void

    var body: some View {
        let task = item.task
        Section {
            Button { store.toggleTodo(item.id, on: item.date); store.save() } label: {
                Label(task.isDone ? "取消完成" : (task.isDropped ? "恢复" : "完成"), systemImage: task.completed ? "arrow.uturn.backward" : "checkmark.circle")
            }
            if !task.completed {
                if focus.session?.taskID == item.id {
                    Button { focus.stop(reason: "手动结束") } label: { Label("结束专注", systemImage: "stop.circle") }
                } else {
                    Button { present(.focus) } label: { Label("开始专注…", systemImage: "timer") }
                }
            }
        }
        Section {
            Menu {
                Button { setDay(0) } label: { Label("今天", systemImage: "sun.max") }
                Button { setDay(1) } label: { Label("明天", systemImage: "sunrise") }
                Button { setDay(nextMondayOffset) } label: { Label("下周一", systemImage: "calendar.badge.plus") }
                Button { postpone() } label: { Label("推后一天", systemImage: "arrow.turn.down.right") }
                Button { present(.date) } label: { Label("选择日期和时间…", systemImage: "calendar") }
                if task.dueDate != nil {
                    Button(role: .destructive) { store.setDeadline(item.id, to: nil); store.save() } label: {
                        Label("清除截止日期", systemImage: "calendar.badge.minus")
                    }
                }
            } label: {
                Label("截止日期", systemImage: "calendar.badge.clock")
            }
            Menu {
                ForEach(TaskPriority.allCases) { priority in
                    Button { store.setPriority(priority, for: item.id); store.save() } label: {
                        if task.priority == priority { Label(L(priority.title), systemImage: "checkmark") } else { Text(L(priority.title)) }
                    }
                }
            } label: {
                Label("优先级", systemImage: "flag")
            }
            if !task.completed {
                let pinned = store.pinnedTask?.id == item.id
                Button { store.pinTask(pinned ? nil : item.id); store.save() } label: {
                    Label(pinned ? "取消固定" : "固定为当前待办", systemImage: pinned ? "pin.slash" : "pin")
                }
            }
        }
        Section {
            Button { present(.note) } label: { Label("写笔记", systemImage: "square.and.pencil") }
            Button { present(.edit) } label: { Label("任务设置…", systemImage: "slider.horizontal.3") }
            if !task.isDone {
                Button { store.dropTodo(item.id, on: item.date); store.save() } label: {
                    Label(task.isDropped ? "恢复" : "放弃（留着记录）", systemImage: task.isDropped ? "arrow.uturn.backward.circle" : "nosign")
                }
            }
        }
        Button(role: .destructive) { store.deleteTodo(item.id, on: item.date); store.save() } label: { Label("删除", systemImage: "trash") }
    }

    private var calendar: Calendar { JournalDates.calendar }

    /// 离下周一还有几天（今天是周一时为 7）。
    private var nextMondayOffset: Int {
        let weekday = calendar.component(.weekday, from: Date())
        return (9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7
    }

    private func setDay(_ offset: Int) {
        store.setDeadline(item.id, to: calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date())))
        store.save()
    }

    private func postpone() {
        let base = max(calendar.startOfDay(for: item.task.dueDate ?? Date()), calendar.startOfDay(for: Date()))
        store.setDeadline(item.id, to: calendar.date(byAdding: .day, value: 1, to: base))
        store.save()
    }
}

/// 选日期（和可选的时刻）。
struct TaskDateSheet: View {
    @ObservedObject var store: JournalStore
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var hasTime = false
    @State private var reminder = -1
    @EnvironmentObject private var reminders: ReminderScheduler

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("日期", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                Toggle("指定时间", isOn: $hasTime.animation())
                if hasTime { DatePicker("时间", selection: $date, displayedComponents: .hourAndMinute) }
                Section {
                    ReminderPicker(minutes: $reminder, timed: hasTime)
                } footer: {
                    if reminder >= 0, reminders.authorization == .denied {
                        Text("通知未开启：到 设置 › 通知 › Timeline 里允许通知，提醒才会响。")
                    }
                }
            }
            .navigationTitle("截止日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { save(); dismiss() } }
            }
            .onAppear {
                guard let task = store.locate(id)?.task else { return }
                date = task.dueDate ?? Date()
                hasTime = task.dueHasTime
                reminder = task.reminderMinutes ?? -1
            }
        }
        .presentationDetents([.large])
    }

    private func save() {
        guard let item = store.locate(id) else { return }
        let calendar = JournalDates.calendar
        let due = hasTime ? calendar.date(bySetting: .second, value: 0, of: date) ?? date : calendar.startOfDay(for: date)
        store.updateTodo(id, scheduledDate: item.date, dueDate: due, dueHasTime: hasTime,
                         reminderMinutes: reminder < 0 ? nil : reminder, repeatRule: item.task.repeatRule)
        store.save()
    }
}

/// 新建待办：和 Mac 的快速添加一样识别「明天 3点」之类的日期和 `#标签`；也可以直接选日期。
struct AddTaskSheet: View {
    @ObservedObject var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var hasDue = false
    @State private var due = Date()
    @State private var priority = TaskPriority.normal
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("要做什么？可写「明天 下午3点」「#标签」", text: $text, axis: .vertical)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(add)
                Toggle("截止日期", isOn: $hasDue.animation())
                if hasDue { DatePicker("日期", selection: $due, displayedComponents: .date) }
                Picker("优先级", selection: $priority) {
                    ForEach(TaskPriority.allCases) { Text(L($0.title)).tag($0) }
                }
            }
            .navigationTitle("新待办")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加", action: add).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func add() {
        guard let created = store.addParsedTodo(text, on: Date(), priority: priority) else { return }
        if hasDue { store.setDeadline(created.id, to: due) }
        dismiss()
    }
}
