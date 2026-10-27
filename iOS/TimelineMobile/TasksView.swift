import SwiftUI
import TimelineCore

/// 待办时间轴：和 Mac 主界面一样，左边一根时间线，按截止日期分组；逾期的排最前，今天标出现在的时刻，
/// 已完成的在当天收成一行，没有日期的排在最后。同一天里按手动顺序（和 Mac 共用），
/// 按住左边的圆点可以拖动：在同一天里调整先后，拖到别的日期就改截止日期。
/// 竖线和节点分开：竖线一次画在整列后面不动，拖起来的只是那一行（时间、圆点、卡片），别的行让出空位。
struct TasksView: View {
    let store: JournalStore
    @ObservedObject var feed: TabFeed
    let sync: SyncModel
    @State private var adding = false
    @State private var noting: UUID?
    @State private var query = ""
    @State private var expandedDone: Set<String> = []
    @State private var path: [UUID] = []
    /// 不订阅：拖动时只有让位的行和被拖的那一行重画，这一页不重算。
    @State private var reorder = TaskReorder()
    @Environment(\.openSettings) private var openSettings

    private static let space = "taskTimeline"

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if query.isEmpty { TaskHeader(tasks: store.tasks()) }
                    timeline
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .modifier(ScrollLock(model: reorder))
            .background(Palette.background)
            .searchable(text: $query, prompt: "搜索待办或 #标签")
            .navigationTitle("待办")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { TaskPage(store: store, id: $0) }
            .toolbar {
                if let openSettings {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { openSettings() } label: {
                            Image(systemName: sync.isConfigured ? "gearshape" : "exclamationmark.icloud")
                        }
                        .accessibilityLabel("设置")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("新建待办")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: PerfProbe.openEditor)) { note in
                if note.object as? String == "task" { adding = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: PerfProbe.action)) { note in
                switch note.object as? String {
                case "addTask": adding = true
                case "closeSheet": adding = false
                case "openTask": if let item = TaskSortMode.deadline.sorted(store.tasks()).first(where: { !$0.task.completed }) { path = [item.id] }
                case "popTask": path = []
                case "openNotedTask": if let item = store.tasks().max(by: { store.notes(for: $0.id).count < store.notes(for: $1.id).count }) { path = [item.id] }
                case "dragTask", "dragHold", "dragDrop": probeDrag(note.object as? String ?? "")
                case "dragEnd": if let id = reorder.activeID { reorder.cancel(id) }
                default: break
                }
            }
            .onReceive(QuickEntry.shared.$request) { _ in
                if QuickEntry.shared.take(.task) { path = []; adding = true }
            }
            .onReceive(Navigator.shared.$target) { _ in
                if let id = Navigator.shared.take({ if case .task(let id) = $0 { id } else { nil } }), store.locate(id) != nil { path = [id] }
            }
            .syncOnRefresh(sync)
            .safeAreaInset(edge: .bottom) { FocusBar() }
        }
        .environment(\.writeTaskNote, TaskNoteWriter { noting = $0 })
        .floatingEditor(isPresented: $adding) { AddTaskSheet(store: store) }
        .floatingEditor(item: $noting) { ComposeSheet(store: store, taskID: $0) }
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
        // 用 LazyVStack：只排看得到的行。整列一起排时，每次切回这一页都要把所有卡片重新量一遍。
        // 拖动排序只用得到屏幕上的行（拖动时不能滚动），没排出来的行没有位置也不影响。
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                ReorderSlot(id: row.id, model: reorder) { motion in
                    rowView(row, hasPrevious: index > 0, hasNext: index < rows.count - 1, motion: motion, rows: rows)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { [reorder] frame in reorder.frames[row.id] = frame }
            }
        }
        // 竖线一次画在整列后面：行挪动时线留在原地，首尾两行把伸出去的线头盖掉。
        .background(alignment: .topLeading) {
            RailRow<EmptyView, EmptyView>.segment(from: 0, to: nil).fill(Palette.line)
        }
        .coordinateSpace(name: Self.space)
        .overlay {
            if rows.isEmpty { ContentUnavailableView("没有找到", systemImage: "magnifyingglass").padding(.top, 60) }
        }
    }

    @ViewBuilder private func rowView(_ row: Row, hasPrevious: Bool, hasNext: Bool, motion: RowMotion, rows: [Row]) -> some View {
        switch row {
        case .day(_, _, let title, let subtitle, let kind):
            let color: Color = kind == .overdue ? Palette.deadline : (kind == .today ? Palette.accent : Palette.muted)
            // 和上一组之间的空隙放在行里面，竖线才会画过去，不在两组之间断开。
            let gap: CGFloat = hasPrevious ? 14 : 0
            RailRow(label: kind == .undated ? "" : title, labelColor: color, hasPrevious: hasPrevious, hasNext: hasNext, nodeY: 14 + gap,
                    drawsLine: false, shift: motion.shift, shiftAnimation: motion.animation) {
                if kind == .today { Dot(color: color, size: 7, ring: true) }
                else if kind == .undated { Rectangle().fill(Palette.line).frame(width: 12, height: 1.5).background(Palette.background) }
                else { Circle().stroke(color, lineWidth: 1.5).frame(width: 9, height: 9).background(Circle().fill(Palette.background)) }
            } content: {
                Text(subtitle)
                    .font(.subheadline.weight(kind == .today ? .semibold : .regular))
                    .foregroundStyle(color)
                    .padding(.top, 4 + gap)
                    .padding(.bottom, 10)
            }
        case .task(let item, _):
            RailRow(label: timeLabel(item.task), labelColor: item.task.dueHasTime ? Palette.accent : Palette.muted,
                    hasPrevious: hasPrevious, hasNext: hasNext, nodeY: 22,
                    drawsLine: false, shift: motion.shift, shiftAnimation: motion.animation) {
                Dot(color: item.task.completed ? Palette.muted : item.task.priority.color, size: motion.lifted ? 13 : 9,
                    ring: item.task.priority == .urgent || item.task.priority == .high)
                    .animation(Motion.adapt(.snappy), value: motion.lifted)
            } content: {
                TaskCard(store: store, item: item, highlighted: store.focusTaskID == item.id, notes: store.noteCount(for: item.id),
                         hasBoard: store.board(for: .task(item.id))?.hasContent == true) { path.append(item.id) }
                    .equatable()
                    .background {
                        // 拿起来的卡片：底下垫一块带阴影的底（不给卡片本身加 .shadow，那样每帧都要离屏画一遍整张卡）。
                        if motion.lifted {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card)
                                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                        }
                    }
                    .overlay {
                        // 放不下（拖进逾期分组）时描红边。
                        if motion.lifted, !motion.valid {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.danger, lineWidth: 1.5)
                        }
                    }
                    .scaleEffect(motion.lifted ? 1.02 : 1)
                    .padding(.bottom, 8)
            }
            .overlay(alignment: .topLeading) {
                // 左边时间和圆点这一块是拖动把手：按住一下再拖。
                if !item.task.completed, query.isEmpty {
                    ReorderHandle(model: reorder, id: row.id) {
                        reorder.begin(row.id, rows: rows.map(\.id)) { slots, active, target in
                            dropPlan(slots: slots, active: active, target: target, rows: rows)?.valid ?? false
                        }
                    } finish: {
                        drop(item.id, rows: rows)
                    }
                    .frame(width: RailRow<EmptyView, EmptyView>.labelWidth + RailRow<EmptyView, EmptyView>.railWidth + 12, height: 48)
                }
            }
        case .now(let date, _):
            RailRow(label: DayText.time(date), labelColor: Palette.accent, hasPrevious: hasPrevious, hasNext: hasNext, nodeY: 8,
                    drawsLine: false, shift: motion.shift, shiftAnimation: motion.animation) {
                Circle().fill(Palette.accent).frame(width: 6, height: 6)
            } content: {
                Rectangle().fill(Palette.accent.opacity(0.6)).frame(height: 1).padding(.top, 7).padding(.bottom, 8)
            }
        case .doneSummary(let key, let count):
            RailRow(hasPrevious: hasPrevious, hasNext: hasNext, nodeY: 12, drawsLine: false, shift: motion.shift, shiftAnimation: motion.animation) {
                EmptyView()
            } content: {
                Button {
                    withAnimation(Motion.adapt(.easeInOut(duration: 0.2))) {
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
            RailRow(hasPrevious: hasPrevious, hasNext: hasNext, nodeY: 12, drawsLine: false, shift: motion.shift, shiftAnimation: motion.animation) { EmptyView() } content: {
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

    /// 测速和截图用：拿起屏幕上第一个能拖的待办，往下拖过几行再拖回来（`hold` 时拖到一半停住）。
    private func probeDrag(_ mode: String) {
        let hold = mode != "dragTask"
        let rows = rows
        guard let row = rows.first(where: { $0.openTask != nil && reorder.frames[$0.id] != nil }),
              reorder.begin(row.id, rows: rows.map(\.id), validate: { slots, active, target in
                  dropPlan(slots: slots, active: active, target: target, rows: rows)?.valid ?? false
              }) else { print("[perf] 没有能拖的待办"); return }
        PerfProbe.drive(duration: hold ? 0.4 : 1.6) { progress in
            reorder.update(hold ? 160 * progress : 260 * sin(.pi * progress))
        } done: {
            if mode == "dragTask" { reorder.cancel(row.id) }
            if mode == "dragDrop", let id = row.openTask?.id {
                drop(id, rows: rows)
                PerfProbe.drive(duration: 0.4) { _ in } done: {}
            }
        }
    }

    /// 松手：按落点改截止日期和顺序。
    private func drop(_ id: UUID, rows: [Row]) {
        let committed = reorder.finish { slots, active, target in
            guard let plan = dropPlan(slots: slots, active: active, target: target, rows: rows), plan.valid, plan.changes else { return false }
            store.moveTask(id, to: plan.day, order: plan.order)
            return true
        }
        if committed { store.save() }
    }

    private struct DropPlan {
        var valid: Bool
        var changes: Bool
        var day: Date?
        var order: [UUID]
    }

    /// 把 `slots[active]` 放到第 `target` 个位置（别的行已经让开）的话：属于哪个分组、分组里的新顺序。
    private func dropPlan(slots: [String], active: Int, target: Int, rows: [Row]) -> DropPlan? {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard slots.indices.contains(active), let dragged = byID[slots[active]], let item = dragged.openTask else { return nil }
        // 去掉被拖的那一行后，它插在第 `target` 行之前（往上拖是插在原来那一行前面，往下拖是插在越过的那一行后面，下标正好相同）。
        let others = slots.enumerated().filter { $0.offset != active }.compactMap { byID[$0.element] }
        guard !others.isEmpty else { return nil }
        let position = min(max(0, target), others.count)
        // 落在某个日期标题之前，算上一个分组的末尾；否则算后面那一行的分组。
        let group: String
        if position < others.count, !others[position].isHeader {
            group = others[position].group
        } else if position > 0 {
            group = others[position - 1].group
        } else {
            group = others[0].group
        }
        var order = others.prefix(position).compactMap { $0.group == group ? $0.openTask?.id : nil }
        order.append(item.id)
        order += others.dropFirst(position).compactMap { $0.group == group ? $0.openTask?.id : nil }
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
        return DropPlan(valid: valid, changes: changes, day: day, order: order)
    }
}

/// 一行在拖动排序里的样子：内容相对原位挪多少、怎么挪，是不是被拿起来的那一行。
private struct RowMotion {
    var shift: CGFloat = 0
    var animation: Animation?
    var lifted = false
    var valid = true
}

/// 拖动排序的状态，和 Mac 清单的排序一样：被拖的那一行跟着手指走，别的行让出它的位置。
/// 手指的位移单独放在 `drag` 里，只有被拖的那一行订阅；别的行只在目标位置变了时重画一次（让位的动画由它们自己放）。
@MainActor
private final class TaskReorder: ObservableObject {
    final class Drag: ObservableObject {
        @Published var value: CGFloat = 0
    }

    static let idle = Drag()
    static let makeWay = Animation.spring(response: 0.28, dampingFraction: 0.82)
    static let settleDuration = 0.24
    static let settle = Animation.spring(response: settleDuration, dampingFraction: 0.86)

    /// 各行在时间轴里的位置（不随滚动变），由布局回传，不需要触发刷新。
    var frames: [String: CGRect] = [:]
    @Published private(set) var activeID: String?
    /// 松手后正在滑进新位置的那一行。
    @Published private(set) var settlingID: String?
    @Published private(set) var target = 0
    @Published private(set) var valid = true
    let drag = Drag()

    /// 拿起时屏幕上排出来的行（按顺序）和它们的位置。
    private var slots: [String] = []
    private var index: [String: Int] = [:]
    private var rects: [CGRect] = []
    private var active = 0
    private var translation: CGFloat = 0
    private var validate: ([String], Int, Int) -> Bool = { _, _, _ in true }
    private let selection = UISelectionFeedbackGenerator()
    private let impact = UIImpactFeedbackGenerator(style: .medium)

    func begin(_ id: String, rows: [String], validate: @escaping ([String], Int, Int) -> Bool) -> Bool {
        guard activeID == nil else { return false }
        let known = rows.compactMap { row in frames[row].map { (row, $0) } }
        guard let at = known.firstIndex(where: { $0.0 == id }) else { return false }
        slots = known.map(\.0)
        rects = known.map(\.1)
        index = Dictionary(uniqueKeysWithValues: slots.enumerated().map { ($1, $0) })
        active = at
        target = at
        translation = 0
        valid = true
        self.validate = validate
        settlingID = nil
        drag.value = 0
        withAnimation(Motion.adapt(.snappy(duration: 0.2))) { activeID = id }
        impact.impactOccurred()
        selection.prepare()
        return true
    }

    /// `translation`：手指相对按下时向下移动的距离。限制在排出来的行的范围内。
    func update(_ value: CGFloat) {
        guard activeID != nil, let first = rects.first, let last = rects.last else { return }
        let clamped = min(max(value, first.minY - rects[active].minY), last.maxY - rects[active].maxY)
        guard abs(clamped - translation) > 0.01 else { return }
        translation = clamped
        drag.value = clamped
        // 看前进方向上的边缘：往上拖看上沿、往下拖看下沿，越过哪一行的中线，就从那一行的位置插进去。
        let moved = rects[active].offsetBy(dx: 0, dy: clamped)
        let next = clamped < 0
            ? active - rects[..<active].filter { $0.midY > moved.minY }.count
            : active + rects[(active + 1)...].filter { $0.midY < moved.maxY }.count
        guard next != target else { return }
        target = next
        let ok = next == active || validate(slots, active, next)
        if ok != valid { valid = ok }
        selection.selectionChanged()
    }

    /// 别的行为被拖的那一行让位的距离：被越过的行朝反方向挪一个被拖行的高度。
    func shift(for id: String) -> CGFloat {
        guard activeID != nil, let at = index[id], at != active else { return 0 }
        let step = rects[active].height
        if target > active, at > active, at <= target { return -step }
        if target < active, at >= target, at < active { return step }
        return 0
    }

    /// 松手：`commit` 按落点改数据（放不下或没变时返回 false），被拖的那一行从松手处滑进新位置。
    @discardableResult
    func finish(_ commit: ([String], Int, Int) -> Bool) -> Bool {
        guard let id = activeID else { return false }
        if target != active, valid {
            var committed = false
            // 改数据和复位在同一刻、不带动画：别的行已经让在新位置上，看不到跳动；只补上被拖行和新位置的差距再滑过去。
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                committed = commit(slots, active, target)
                let slot = target > active ? rects[target].maxY - rects[active].maxY : rects[target].minY - rects[active].minY
                settle(id, from: committed ? translation - slot : translation)
            }
            if committed { slideHome(id); return true }
        }
        // 放不下或没挪：别的行退回原位，被拖的那一行滑回去。
        settle(id, from: translation)
        slideHome(id)
        return false
    }

    func cancel(_ id: String) {
        guard activeID == id else { return }
        settle(id, from: translation)
        slideHome(id)
    }

    private func settle(_ id: String, from offset: CGFloat) {
        activeID = nil
        settlingID = id
        drag.value = offset
        slots = []
        index = [:]
        rects = []
        translation = 0
    }

    /// 等补好差距的位置先画出一帧再归零；同一轮里改回去会和提交合并，动画从错的位置开始。
    private func slideHome(_ id: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self, self.settlingID == id else { return }
            self.drag.value = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDuration) { [weak self] in
                guard let self, self.settlingID == id else { return }
                withAnimation(Motion.adapt(.snappy(duration: 0.2))) { self.settlingID = nil }
            }
        }
    }
}

/// 一行：按拖动状态给出挪动的距离。只有被拖（或正在落位）的那一行订阅手指的位移。
private struct ReorderSlot<Content: View>: View {
    let id: String
    @ObservedObject var model: TaskReorder
    @ViewBuilder let content: (RowMotion) -> Content

    var body: some View {
        let active = model.activeID == id
        let settling = model.settlingID == id
        // 让位的距离作为参数传下去：只在里面读模型的话，SwiftUI 发现输入没变会跳过重算。
        FollowDrag(drag: active || settling ? model.drag : TaskReorder.idle, following: active || settling, shift: model.shift(for: id)) { offset in
            content(RowMotion(shift: offset,
                              animation: active ? nil : (settling ? TaskReorder.settle : TaskReorder.makeWay),
                              lifted: active || settling, valid: !active || model.valid))
        }
        .zIndex(active || settling ? 1 : 0)
    }
}

private struct FollowDrag<Content: View>: View {
    @ObservedObject var drag: TaskReorder.Drag
    let following: Bool
    let shift: CGFloat
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View { content(following ? drag.value : shift) }
}

/// 拖动把手（时间和圆点那一块）：按住 0.3 秒拿起，再拖。手势被系统打断（来电、切走）时放回原位。
private struct ReorderHandle: View {
    let model: TaskReorder
    let id: String
    let begin: () -> Bool
    let finish: () -> Void
    @GestureState private var holding = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                LongPressGesture(minimumDuration: 0.3)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .updating($holding) { value, state, _ in
                        if case .second(true, _) = value { state = true }
                    }
                    .onChanged { value in
                        guard case .second(true, let movement) = value else { return }
                        if model.activeID != id, !begin() { return }
                        model.update(movement?.translation.height ?? 0)
                    }
                    .onEnded { value in
                        guard case .second(true, _) = value else { return }
                        finish()
                    }
            )
            // 正常松手时 onEnded 已经收尾；这里只兜底被打断的情况，晚一轮再看，免得抢在 onEnded 前面。
            .onChange(of: holding) { _, now in
                if !now { DispatchQueue.main.async { model.cancel(id) } }
            }
    }
}

/// 拖动时锁住滚动。单独一个修饰器订阅拖动状态，拿起、放下时不用重算整页。
private struct ScrollLock: ViewModifier {
    @ObservedObject var model: TaskReorder

    func body(content: Content) -> some View {
        content.scrollDisabled(model.activeID != nil)
    }
}

/// 顶部：今天的日期、逾期 / 今天 / 未完成 / 未设日期的数量，和今天的完成进度。
private struct TaskHeader: View {
    let tasks: [ScheduledTask]

    var body: some View {
        let now = Date()
        let calendar = JournalDates.calendar
        let open = tasks.filter { !$0.task.completed }
        let overdue = open.filter { $0.task.effectiveDeadline.map { $0 < now } ?? false }.count
        let todayTasks = tasks.filter { $0.task.dueDate.map(calendar.isDateInToday) ?? false && !$0.task.isDropped }
        let todayDone = todayTasks.filter(\.task.isDone).count
        let undated = open.filter { $0.task.dueDate == nil }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(now.formatted(.dateTime.month(.defaultDigits).day()))
                    .font(.largeTitle.bold())
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
/// 不订阅数据：要显示的都从外面传进来，内容没变就不重算（勾一个待办只重画那一张）。
struct TaskCard: View, Equatable {
    let store: JournalStore
    let item: ScheduledTask
    var highlighted = false
    var notes = 0
    var hasBoard = false
    let open: () -> Void
    @State private var sheet: TaskSheet?
    @Environment(\.writeTaskNote) private var writeTaskNote

    var body: some View {
        let task = item.task
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(TaskText.rendered(task.title))
                    .font(.body.weight(task.completed ? .regular : .medium))
                    .foregroundStyle(task.completed ? Palette.muted : Palette.ink)
                    .strikethrough(task.completed, color: Palette.muted)
                    .multilineTextAlignment(.leading)
                TaskMeta(task: task, notes: notes, hasBoard: hasBoard)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withAnimation(Motion.adapt(.easeInOut(duration: 0.2))) { store.toggleTodo(item.id, on: item.date) }
            } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : (task.isDropped ? "xmark.circle" : "circle"))
                    .font(.title3)
                    .foregroundStyle(task.isDone ? Palette.success : Palette.muted)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "取消完成" : "完成")
            .accessibilityValue(task.isDone ? L("已完成") : (task.isDropped ? L("已放弃") : L("未完成")))
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 8)
        .card(highlighted: highlighted)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: open)
        .contextMenu {
            TaskActions(store: store, item: item) {
                if $0 == .note, let writeTaskNote { writeTaskNote(item.id) } else { sheet = $0 }
            }
        }
        .sheet(item: $sheet) { TaskSheetView(store: store, id: item.id, sheet: $0) }
    }

    static func == (a: TaskCard, b: TaskCard) -> Bool {
        a.item == b.item && a.highlighted == b.highlighted && a.notes == b.notes && a.hasBoard == b.hasBoard
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
    let task: Todo
    let notes: Int
    let hasBoard: Bool

    var body: some View {
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
        Button(role: .destructive) { UndoToast.deleteTodo(item.id, on: item.date, store: store) } label: { Label("删除", systemImage: "trash") }
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
    @Environment(\.closeEditor) private var closeEditor
    @State private var text = ""
    @State private var hasDue = false
    @State private var due = Date()
    @State private var priority = TaskPriority.normal

    var body: some View {
        if let close = closeEditor {
            VStack(alignment: .leading, spacing: 8) {
                EditorCardHeader(title: "新待办", confirm: "添加", canConfirm: canAdd, cancel: close.close, action: add)
                AutoFocusTextView(text: $text, placeholder: L("要做什么？可写「明天 下午3点」「#标签」"), maxLines: 4, submit: add)
                HStack(spacing: 14) {
                    Toggle(isOn: $hasDue.animation(.snappy(duration: 0.2))) { Label("截止", systemImage: "calendar") }
                        .toggleStyle(.button)
                    if hasDue { DatePicker("日期", selection: $due, displayedComponents: .date).labelsHidden() }
                    Menu {
                        Picker("优先级", selection: $priority) {
                            ForEach(TaskPriority.allCases) { Text(L($0.title)).tag($0) }
                        }
                    } label: {
                        Label(L(priority.title), systemImage: "flag")
                    }
                    Spacer()
                }
                .font(.subheadline)
            }
        } else {
            sheet
        }
    }

    private var canAdd: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var sheet: some View {
        NavigationStack {
            Form {
                AutoFocusTextView(text: $text, placeholder: L("要做什么？可写「明天 下午3点」「#标签」"), maxLines: 4, submit: add)
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
        }
        .presentationDetents([.medium, .large])
    }

    private func add() {
        guard let created = store.addParsedTodo(text, on: Date(), priority: priority) else { return }
        if hasDue { store.setDeadline(created.id, to: due) }
        if let closeEditor { closeEditor() } else { dismiss() }
    }
}
