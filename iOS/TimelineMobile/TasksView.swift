import SwiftUI
import TimelineCore

/// 待办时间轴：和 Mac 主界面一样，左边一根时间线，按截止日期分组；逾期的排最前，今天标出现在的时刻，
/// 已完成的在当天收成一行，没有日期的排在最后。
struct TasksView: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var sync: SyncModel
    @State private var adding = false
    @State private var query = ""
    @State private var expandedDone: Set<String> = []
    @State private var path: [UUID] = []

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
            .syncOnRefresh(sync)
        }
    }

    // MARK: 时间轴的行

    private enum Row: Identifiable {
        case day(key: String, date: Date?, title: String, subtitle: String, kind: DayKind)
        case task(ScheduledTask)
        case now(Date)
        case doneSummary(key: String, count: Int)
        case empty

        var id: String {
            switch self {
            case .day(let key, _, _, _, _): return "day-" + key
            case .task(let item): return item.id.uuidString
            case .now: return "now"
            case .doneSummary(let key, _): return "done-" + key
            case .empty: return "empty"
            }
        }
    }

    private enum DayKind { case overdue, today, future, undated }

    private var rows: [Row] {
        let now = Date()
        let calendar = JournalDates.calendar
        let today = calendar.startOfDay(for: now)
        let all = store.tasks(matching: query)
        let order = TaskSortMode.deadline
        var rows: [Row] = []

        let overdue = order.sorted(all.filter { !$0.task.completed && ($0.task.effectiveDeadline.map { $0 < now } ?? false) && calendar.startOfDay(for: $0.task.dueDate!) < today }, now: now)
        if !overdue.isEmpty {
            rows.append(.day(key: "overdue", date: nil, title: "逾期", subtitle: "\(overdue.count) 项", kind: .overdue))
            rows += overdue.map(Row.task)
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
            let open = order.sorted(items.filter { !$0.task.completed }, now: now)
            let done = items.filter(\.task.completed)
            let key = JournalDates.key(day)
            let isToday = calendar.isDate(day, inSameDayAs: today)
            let relative = DayText.relative(day).map { $0 + " · " } ?? ""
            rows.append(.day(key: key, date: day, title: DayText.short(day), subtitle: relative + DayText.weekday(day),
                             kind: isToday ? .today : .future))
            var placedNow = !isToday
            for item in open {
                if !placedNow, item.task.dueHasTime, let due = item.task.dueDate, due > now {
                    rows.append(.now(now))
                    placedNow = true
                }
                rows.append(.task(item))
            }
            if !placedNow, open.contains(where: \.task.dueHasTime) { rows.append(.now(now)) }
            if !done.isEmpty {
                rows.append(.doneSummary(key: key, count: done.count))
                if expandedDone.contains(key) { rows += done.map(Row.task) }
            }
            if isToday, open.isEmpty, done.isEmpty { rows.append(.empty) }
        }

        let undated = order.sorted(all.filter { $0.task.dueDate == nil && !$0.task.completed }, now: now)
        if !undated.isEmpty {
            rows.append(.day(key: "undated", date: nil, title: "—", subtitle: "未设日期", kind: .undated))
            rows += undated.map(Row.task)
        }
        return rows
    }

    private var timeline: some View {
        let rows = rows
        // 不用 LazyVStack：按真实高度滚动，滚动条不会错位。
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                rowView(row, hasPrevious: index > 0, hasNext: index < rows.count - 1)
            }
        }
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
        case .task(let item):
            RailRow(label: timeLabel(item.task), labelColor: item.task.dueHasTime ? Palette.accent : Palette.muted,
                    hasPrevious: hasPrevious, hasNext: hasNext, nodeY: 22) {
                Dot(color: item.task.completed ? Palette.muted : item.task.priority.color, size: 9, ring: item.task.priority == .urgent || item.task.priority == .high)
            } content: {
                TaskCard(store: store, item: item) { path.append(item.id) }
                    .padding(.bottom, 8)
            }
        case .now(let date):
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
        return task.dueHasTime ? DayText.time(due) : "全天"
    }
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
                Chip(text: "今天")
                Spacer()
            }
            Text(now.formatted(.dateTime.year()) + " · " + DayText.weekday(now))
                .font(.subheadline).foregroundStyle(Palette.muted)
            HStack(spacing: 6) {
                if overdue > 0 { Chip(text: "\(overdue) 逾期", color: Palette.deadline) }
                Chip(text: "\(todayTasks.count - todayDone) 今天", color: Palette.accent)
                Chip(text: "\(open.count) 未完成", color: Palette.muted)
                if undated > 0 { Chip(text: "\(undated) 未设日期", color: Palette.muted) }
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

/// 时间轴上的一张待办卡片：点卡片打开笔记，点右边的圆圈完成。
struct TaskCard: View {
    @ObservedObject var store: JournalStore
    let item: ScheduledTask
    let open: () -> Void

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
        .card()
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: open)
        .contextMenu { TaskActions(store: store, item: item) }
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
                if task.repeatRule != .none { Label(task.repeatRule.title, systemImage: "repeat") }
            }
            .font(.caption)
            .foregroundStyle(Palette.muted)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
        }
    }
}

/// 长按菜单。
struct TaskActions: View {
    @ObservedObject var store: JournalStore
    let item: ScheduledTask

    var body: some View {
        Button { store.toggleTodo(item.id, on: item.date) } label: {
            Label(item.task.isDone ? "取消完成" : "完成", systemImage: "checkmark.circle")
        }
        Button { postpone() } label: { Label("推后一天", systemImage: "arrow.turn.down.right") }
        if !item.task.isDone {
            Button { store.dropTodo(item.id, on: item.date) } label: {
                Label(item.task.isDropped ? "恢复" : "放弃", systemImage: "xmark.circle")
            }
        }
        Button(role: .destructive) { store.deleteTodo(item.id, on: item.date) } label: { Label("删除", systemImage: "trash") }
    }

    private func postpone() {
        let calendar = JournalDates.calendar
        let base = max(calendar.startOfDay(for: item.task.dueDate ?? Date()), calendar.startOfDay(for: Date()))
        store.setDeadline(item.id, to: calendar.date(byAdding: .day, value: 1, to: base))
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
                    ForEach(TaskPriority.allCases) { Text($0.title).tag($0) }
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
