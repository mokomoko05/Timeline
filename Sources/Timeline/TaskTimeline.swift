import AppKit
import SwiftUI
import TimelineCore

/// 已结束事项在当天原位置展开、收起；不跨日期合并。
struct TaskTimelineItem: Identifiable {
    let tasks: [ScheduledTask]
    let folded: Bool
    var expandedFinished = false
    var id: UUID { tasks[0].id }

    static func items(for tasks: [ScheduledTask], expanded: Set<UUID> = []) -> [Self] {
        var result: [Self] = []
        var finished: [ScheduledTask] = []
        func flush() {
            guard !finished.isEmpty else { return }
            let isExpanded = finished.contains { expanded.contains($0.id) }
            result.append(Self(tasks: finished, folded: !isExpanded, expandedFinished: isExpanded))
            finished = []
        }
        for task in tasks {
            if task.task.completed {
                if let previous = finished.last, !sameDay(previous.task.dueDate, task.task.dueDate) { flush() }
                finished.append(task)
            } else {
                flush()
                result.append(Self(tasks: [task], folded: false))
            }
        }
        flush()
        return result
    }

    private static func sameDay(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): return JournalDates.calendar.isDate(lhs, inSameDayAs: rhs)
        case (nil, nil): return true
        default: return false
        }
    }
}

/// 有限时间轴：只保留近期窗口和有任务的日期，远距离空档用一段虚线表示。
enum TaskTimelineSection: Identifiable {
    case day(Date, [ScheduledTask])
    case gap(Date?, Date?)
    case undated([ScheduledTask])
    case finished([Date], [ScheduledTask])

    var id: String {
        switch self {
        case .day(let date, _): return Self.dayID(date)
        case .gap(let before, let after): return "gap-\(before.map(JournalDates.key) ?? "past")-\(after.map(JournalDates.key) ?? "future")"
        case .undated: return "undated"
        case .finished(let dates, _): return "finished-" + JournalDates.key(dates[0])
        }
    }
    static func dayID(_ date: Date) -> String { "date-" + JournalDates.key(date) }
    static func navigationID(for date: Date, in sections: [Self]) -> String? {
        let day = JournalDates.calendar.startOfDay(for: date)
        if let section = sections.first(where: { $0.id == dayID(day) }) { return section.id }
        if let section = sections.first(where: {
            if case .finished(let dates, _) = $0 { return day >= dates[0] && day <= dates[dates.count - 1] }
            return false
        }) { return section.id }
        return sections.first { section in
            guard case .gap(let before, let after) = section else { return false }
            return (before.map { day > $0 } ?? true) && (after.map { day < $0 } ?? true)
        }?.id
    }
    var tasks: [ScheduledTask] {
        switch self {
        case .day(_, let tasks), .undated(let tasks), .finished(_, let tasks): return tasks
        case .gap: return []
        }
    }

    func visibleTasks(expanded: Set<UUID>) -> [ScheduledTask] {
        if case .finished(_, let tasks) = self {
            return tasks.contains(where: { expanded.contains($0.id) }) ? tasks : []
        }
        return TaskTimelineItem.items(for: tasks, expanded: expanded).filter { !$0.folded }.flatMap(\.tasks)
    }

    /// 日期顺序固定，每个日期（包括未设日期）内部使用持久化的手动顺序。
    static func precedes(_ lhs: ScheduledTask, _ rhs: ScheduledTask) -> Bool {
        let calendar = JournalDates.calendar
        let a = lhs.task.dueDate.map { calendar.startOfDay(for: $0) } ?? .distantFuture
        let b = rhs.task.dueDate.map { calendar.startOfDay(for: $0) } ?? .distantFuture
        if a != b { return a < b }
        return ScheduledTask.listOrder(lhs, rhs)
    }

    static func sections(for tasks: [ScheduledTask], today: Date = Date()) -> [Self] {
        let calendar = JournalDates.calendar
        let today = calendar.startOfDay(for: today)
        let ordered = tasks.sorted(by: precedes)
        let dated = ordered.filter { $0.task.dueDate != nil }
        let byDay = Dictionary(grouping: dated) { calendar.startOfDay(for: $0.task.dueDate!) }
        // 今天和明天是稳定的近期窗口；其余日期只由实际有任务的日期提供。
        let nearTerm = Set((0...1).compactMap { calendar.date(byAdding: .day, value: $0, to: today) })
        var days = nearTerm
        days.formUnion(byDay.keys)
        let sortedDays = days.sorted()
        guard let first = sortedDays.first, let last = sortedDays.last else {
            return [.undated(ordered)]
        }
        var result: [Self] = [.gap(nil, first)]
        var previous: Date?
        for day in sortedDays {
            if let previous, (calendar.dateComponents([.day], from: previous, to: day).day ?? 0) > 1 {
                result.append(.gap(previous, day))
            }
            result.append(.day(day, byDay[day] ?? []))
            previous = day
        }
        result.append(.gap(last, nil))
        result.append(.undated(ordered.filter { $0.task.dueDate == nil }))
        var compact: [Self] = []
        var finishedDates: [Date] = []
        var finishedTasks: [ScheduledTask] = []
        var pendingGap: Self?
        func flushFinished() {
            if !finishedDates.isEmpty { compact.append(.finished(finishedDates, finishedTasks)) }
            finishedDates = []; finishedTasks = []
            if let pendingGap { compact.append(pendingGap) }
            pendingGap = nil
        }
        for section in result {
            switch section {
            case .day(let date, let tasks) where !nearTerm.contains(date) && !tasks.isEmpty && tasks.allSatisfy(\.task.completed):
                // 中间只有空档时也合并，展开时再还原这些日期之间的虚线。
                pendingGap = nil
                finishedDates.append(date); finishedTasks.append(contentsOf: tasks)
            case .gap where !finishedDates.isEmpty:
                pendingGap = section
            default:
                flushFinished(); compact.append(section)
            }
        }
        flushFinished()
        return compact
    }
}

/// 一段轴线由日期容器的高度决定，任务圆点不参与轴线绘制。
struct TaskTimelineAxis: Shape {
    let x: CGFloat
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX + x, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + x, y: rect.maxY))
        }
    }
}

enum TaskTimelineLayout {
    static let spacing: CGFloat = 6
    static func timeWidth(_ typography: AppTypography) -> CGFloat { typography.pt(40) }
    static func axisX(_ typography: AppTypography) -> CGFloat { timeWidth(typography) + 17 }
    static func cardInset(_ typography: AppTypography) -> CGFloat { timeWidth(typography) + 34 }
}

/// 时间轴内容与主窗口分离，日期区间保留独立的轴线。
struct TaskTimelineView: View {
    @ObservedObject var store: JournalStore
    let tasks: [ScheduledTask]
    let today: Date
    let selectedDate: Date
    @Binding var expanded: Set<UUID>
    @Binding var requestedEdit: UUID?
    let navigate: (Date) -> Void
    var selectTask: () -> Void = {}
    var next: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(TaskTimelineSection.sections(for: tasks, today: today)) { section in
                switch section {
                case .day(let date, let items):
                    TimelineDayView(store: store, date: date, tasks: items, selectedDate: selectedDate,
                                    expanded: $expanded, requestedEdit: $requestedEdit,
                                    navigate: navigate, selectTask: selectTask, next: next)
                        .id(section.id)
                case .gap(let before, let after):
                    TimelineGapView(before: before, after: after)
                        .id(section.id)
                case .undated(let items):
                    TimelineDayView(store: store, date: nil, tasks: items, selectedDate: selectedDate,
                                    expanded: $expanded, requestedEdit: $requestedEdit,
                                    navigate: navigate, selectTask: selectTask, next: next)
                        .id(section.id)
                case .finished(let dates, let items):
                    FinishedTimelineDatesView(store: store, dates: dates, tasks: items, selectedDate: selectedDate,
                        expanded: $expanded, requestedEdit: $requestedEdit, navigate: navigate,
                        selectTask: selectTask, next: next)
                        .id(section.id)
                }
            }
        }
        .animation(Motion.quick, value: tasks.map(\.id))
        .animation(Motion.quick, value: expanded)
    }
}

struct TimelineDayView: View {
    @ObservedObject var store: JournalStore
    @Environment(\.typography) private var typography
    let date: Date?
    let tasks: [ScheduledTask]
    let selectedDate: Date
    @Binding var expanded: Set<UUID>
    @Binding var requestedEdit: UUID?
    let navigate: (Date) -> Void
    let selectTask: () -> Void
    let next: () -> Void
    var showsFinishedTasks = false
    @State private var calendarDropTargeted = false
    @ObservedObject private var dragSession = TaskDragSession.shared
    @State private var reorder = TaskReorderModel()
    private var axisTone: TimelineAxisStroke.Tone {
        guard let date else { return .future }
        let calendar = JournalDates.calendar
        if calendar.isDateInToday(date) { return .today }
        return date < calendar.startOfDay(for: Date()) ? .past : .future
    }
    private var reorderSpace: String { "timeline-order-" + (date.map(TaskTimelineSection.dayID) ?? "undated") }
    private var displayed: [ScheduledTask] { tasks.sorted(by: TaskTimelineSection.precedes) }
    private var visibleIDs: [UUID] {
        if showsFinishedTasks { return displayed.map(\.id) }
        return TaskTimelineItem.items(for: displayed, expanded: expanded).filter { !$0.folded }.flatMap(\.tasks).map(\.id)
    }
    private func configureReorder(_ ids: [UUID]) {
        // onChange 直接传入新值；重新读取视图属性可能取得刷新前的分组快照。
        reorder.groupProvider = { _ in ids }
        reorder.commit = { store.reorderTasks($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineDateMarker(date: date, selectedDate: selectedDate, compact: true, navigate: navigate)
            // 刻度属于边界；任务始终位于边界之间。
            VStack(alignment: .leading, spacing: TaskTimelineLayout.spacing) {
                if showsFinishedTasks {
                    ForEach(displayed) { taskRow($0) }
                } else {
                    ForEach(TaskTimelineItem.items(for: displayed, expanded: expanded)) { item in
                        if item.tasks.first?.task.completed == true {
                            FinishedTaskTimelineBlock(store: store, item: item, expanded: $expanded,
                                                      requestedEdit: $requestedEdit, selectTask: selectTask)
                        } else if let task = item.tasks.first { taskRow(task) }
                    }
                }
            }
            .padding(.top, displayed.isEmpty ? 0 : 4)
            .padding(.bottom, displayed.isEmpty ? 4 : 10)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .coordinateSpace(name: reorderSpace)
        .environment(\.taskReorder, store.isReadOnly ? nil : reorder)
        .environment(\.timelineReorderSpace, reorderSpace)
        .onPreferenceChange(TaskRowFramesKey.self) { reorder.frames = $0 }
        .onAppear { configureReorder(visibleIDs) }
        .onChange(of: visibleIDs) { ids in configureReorder(ids) }
        .background { TimelineAxisStroke(highlighted: false, dashed: date == nil, tone: axisTone) }
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(calendarDropTargeted ? Palette.soft : .clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(calendarDropTargeted ? Palette.accent : .clear, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onDrop(of: [TaskDragPayload.type], delegate: CalendarTaskDropTarget(store: store, destination: date,
            calendarSourceOnly: true, targeted: $calendarDropTargeted))
        .onChange(of: dragSession.activeID) { if $0 == nil { calendarDropTargeted = false } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(date.map(TaskTimelineSection.dayID) ?? "undated")
    }

    private func taskRow(_ item: ScheduledTask) -> some View {
        ManagedTaskRow(store: store, date: item.date, task: item.task, requestedEdit: $requestedEdit,
                       timeline: true, next: next, select: selectTask)
            .id(item.id)
            .taskReorderRow(id: item.id, model: reorder, space: reorderSpace)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: TaskRowGlobalFramesKey.self, value: [item.id: geometry.frame(in: .global)])
            })
    }
}

struct FinishedTaskTimelineBlock: View {
    @ObservedObject var store: JournalStore
    @Environment(\.typography) private var typography
    @Environment(\.taskReorder) private var reorder
    let item: TaskTimelineItem
    @Binding var expanded: Set<UUID>
    @Binding var requestedEdit: UUID?
    let selectTask: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: TaskTimelineLayout.spacing) {
            Button {
                withAnimation(Motion.quick) {
                    if item.folded { expanded.formUnion(item.tasks.map(\.id)) }
                    else { expanded.subtract(item.tasks.map(\.id)) }
                }
            } label: {
                HStack(spacing: 7) {
                    let completed = item.tasks.filter(\.task.isDone).count
                    let dropped = item.tasks.filter(\.task.isDropped).count
                    if completed > 0 { Text("已完成 \(completed) 项") }
                    if dropped > 0 { Text("已放弃 \(dropped) 项") }
                    Image(systemName: item.folded ? "chevron.right" : "chevron.down")
                    Spacer(minLength: 0)
                }
                .font(.system(size: typography.pt(11))).foregroundStyle(Palette.muted)
                .frame(height: typography.pt(26)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, TaskTimelineLayout.cardInset(typography))
            .help(item.folded ? "展开已结束事项" : "收起这段已结束事项")
            if !item.folded {
                ForEach(item.tasks) { task in
                    ManagedTaskRow(store: store, date: task.date, task: task.task, requestedEdit: $requestedEdit,
                                   timeline: true, select: selectTask)
                        .id(task.id)
                        .modifier(TimelineReorderRow(id: task.id, model: reorder))
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: TaskRowGlobalFramesKey.self, value: [task.id: geometry.frame(in: .global)])
                        })
                }
            }
        }.id(item.id)
    }
}

private struct TimelineReorderRow: ViewModifier {
    let id: UUID
    let model: TaskReorderModel?
    @Environment(\.timelineReorderSpace) private var space
    func body(content: Content) -> some View {
        if let model { content.taskReorderRow(id: id, model: model, space: space) }
        else { content }
    }
}

private struct TimelineReorderSpaceKey: EnvironmentKey { static let defaultValue = "timeline-order" }
extension EnvironmentValues {
    var timelineReorderSpace: String {
        get { self[TimelineReorderSpaceKey.self] }
        set { self[TimelineReorderSpaceKey.self] = newValue }
    }
}

struct FinishedTimelineDatesView: View {
    @ObservedObject var store: JournalStore
    @Environment(\.typography) private var typography
    let dates: [Date]
    let tasks: [ScheduledTask]
    let selectedDate: Date
    @Binding var expanded: Set<UUID>
    @Binding var requestedEdit: UUID?
    let navigate: (Date) -> Void
    let selectTask: () -> Void
    let next: () -> Void
    private var isExpanded: Bool { tasks.contains { expanded.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.quick) {
                    if isExpanded { expanded.subtract(tasks.map(\.id)) }
                    else { expanded.formUnion(tasks.map(\.id)) }
                }
            } label: {
                HStack(spacing: 7) {
                    Text(dates[0].formatted(.dateTime.month(.twoDigits).day(.twoDigits)))
                    if dates.count > 1 {
                        Text("–")
                        Text(dates[dates.count - 1].formatted(.dateTime.month(.twoDigits).day(.twoDigits)))
                    }
                    let completed = tasks.filter(\.task.isDone).count
                    let dropped = tasks.filter(\.task.isDropped).count
                    if completed > 0 { Text("已完成 \(completed) 项") }
                    if dropped > 0 { Text("已放弃 \(dropped) 项") }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    Spacer(minLength: 0)
                }
                .font(.system(size: typography.pt(11)))
                .padding(.horizontal, 6).frame(minHeight: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Palette.muted).raisedOnHover()
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, TaskTimelineLayout.cardInset(typography))
            .padding(.vertical, 6)
            .help(isExpanded ? "收起这段已结束事项" : "展开已结束事项")
            .background { TimelineAxisStroke(highlighted: false) }
            if isExpanded {
                ForEach(dates, id: \.self) { date in
                    if let index = dates.firstIndex(of: date), index > 0,
                       (JournalDates.calendar.dateComponents([.day], from: dates[index - 1], to: date).day ?? 0) > 1 {
                        TimelineGapView(before: dates[index - 1], after: date)
                    }
                    TimelineDayView(store: store, date: date,
                        tasks: tasks.filter { $0.task.dueDate.map { JournalDates.calendar.isDate($0, inSameDayAs: date) } == true },
                        selectedDate: selectedDate, expanded: $expanded, requestedEdit: $requestedEdit,
                        navigate: navigate, selectTask: selectTask, next: next, showsFinishedTasks: true)
                        .id(TaskTimelineSection.dayID(date))
                }
            }
        }
    }
}

struct TimelineDateMarker: View {
    @Environment(\.typography) private var typography
    let date: Date?
    let selectedDate: Date
    var compact = false
    let navigate: (Date) -> Void
    @State private var showingDate = false

    private var isToday: Bool { date.map { JournalDates.calendar.isDateInToday($0) } == true }

    /// 日期是线上的「结」：普通日子是空心小环，今天是带光晕的实心结，未设日期是一段短横。
    @ViewBuilder private var knot: some View {
        if date == nil {
            Capsule().fill(Palette.line).frame(width: 10, height: 2)
        } else if isToday {
            ZStack {
                Circle().fill(Palette.accent.opacity(0.18)).frame(width: 16, height: 16)
                Circle().fill(Palette.accent).frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Palette.background, lineWidth: 1.5))
            }
        } else {
            Circle().fill(Palette.background).frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Palette.muted.opacity(0.8), lineWidth: 1.25))
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if date != nil {
                Button {
                    showingDate = true
                } label: {
                    Text(date.map { $0.formatted(.dateTime.month(.twoDigits).day(.twoDigits).locale(AppLanguage.current.locale)) } ?? "···")
                        .font(.system(size: typography.pt(11), weight: .semibold)).monospacedDigit()
                        .foregroundStyle(date.map { JournalDates.calendar.isDateInToday($0) } == true ? Palette.accent : Palette.muted)
                        .frame(width: TaskTimelineLayout.timeWidth(typography), alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("打开日期窗口")
                .popover(isPresented: $showingDate, arrowEdge: .trailing) {
                    TimelineDateWindow(initial: date ?? selectedDate) { date in navigate(date); showingDate = false }
                }
                Button { showingDate = true } label: {
                    knot.frame(width: 22, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).help("打开日期窗口")
            } else {
                Color.clear.frame(width: TaskTimelineLayout.timeWidth(typography))
                knot.frame(width: 22, height: 24)
            }
            Button { if let date { navigate(date) } } label: {
                Text(date.map { JournalDates.calendar.isDateInToday($0) ? AppLocalized("今天") : "" } ?? AppLocalized("未设日期"))
                    .font(.system(size: typography.pt(11), weight: isToday ? .semibold : .regular))
                    .foregroundStyle(isToday ? Palette.accent : Palette.muted)
            }.buttonStyle(.plain).disabled(date == nil)
            Spacer(minLength: 0)
        }
        .frame(height: typography.pt(compact ? 24 : 30))
    }
}

struct TimelineDateWindow: View {
    let navigate: (Date) -> Void
    @State private var date: Date
    @State private var timed = false

    init(initial: Date, navigate: @escaping (Date) -> Void) {
        self.navigate = navigate
        _date = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("时间轴日期").font(.headline)
            DeadlineSelectionView(due: $date, timed: $timed)
            HStack {
                Button("今天") { date = Date() }
                Spacer()
                Button("前往日期") { navigate(date) }.keyboardShortcut(.defaultAction)
            }
        }.padding(16)
    }
}

struct TimelineGapView: View {
    @Environment(\.typography) private var typography
    let before: Date?
    let after: Date?

    private var omittedDays: Int? {
        guard let before, let after else { return nil }
        return max(0, (JournalDates.calendar.dateComponents([.day], from: before, to: after).day ?? 1) - 1)
    }

    var body: some View {
        Color.clear
        .frame(height: typography.pt(18))
        .help(omittedDays.map { AppLocalizedFormat("省略 %d 天", $0) } ?? "")
        .background(alignment: .leading) {
            TimelineAxisStroke(highlighted: false, dashed: true)
        }
        .allowsHitTesting(false)
    }
}
