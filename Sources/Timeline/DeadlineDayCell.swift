import AppKit
import SwiftUI
import TimelineCore

struct DeadlineDayCell: View, Equatable {
    @Environment(\.typography) private var typography
    /// 只用来执行操作。格子不观察仓库：显示需要的数据都由月历传进来，
    /// 配合 `Equatable`，与这一格无关的修改不会让 42 个格子全部重算。
    let store: JournalStore
    let date: Date
    let selectedDate: Date
    let displayedMonth: Date
    let height: CGFloat
    let items: [ScheduledTask]
    /// 这一天截止的全部事项（`items` 是其中要显示的部分）。
    let dueToday: [ScheduledTask]
    let logCount: Int
    /// 这一天的专注时长：格子底部一条细线，满格 = 4 小时。
    var focusSeconds: TimeInterval = 0
    let readOnly: Bool
    /// 由月历传入（跨日时月历会刷新），这样 `Equatable` 比较能感知「今天」的变化。
    let today: Bool
    let select: () -> Void
    let open: () -> Void
    /// 打开这一天的日志（选中的那一格常驻显示按钮，其他格子悬停时出现）。
    var openLog: () -> Void = {}
    let editTask: (ScheduledTask) -> Void
    @State private var targeted = false
    @ObservedObject private var dragSession = TaskDragSession.shared
    @State private var checkboxFrames: [String: CGRect] = [:]
    @State private var hovered = false
    /// 日志按钮在 preference 里的固定标识：和勾选框一样，点它只打开日志，不触发「选中日期」。
    static let logButtonID = UUID(uuidString: "00000000-0000-0000-0000-00000000106E")!

    /// 日历只在任务的截止日期那天显示它，顺序与时间轴里这一天的顺序一致（含手动排序）。
    static func previewItems(dueItems: [ScheduledTask], hideCompleted: Bool) -> [ScheduledTask] {
        dueItems.sorted(by: ScheduledTask.listOrder)
            .filter { !hideCompleted || !$0.task.completed }
    }
    private static let space = "dayCell"
    /// 创建 DateFormatter 很贵，而 42 个格子每次重绘都要用：只建一次。
    private static let accessibilityFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter
    }()
    private var accessibilityDescription: String {
        let formatter = Self.accessibilityFormatter
        let due = dueToday
        let summary = due.isEmpty ? AppLocalized("没有截止事项") : AppLocalizedFormat("%lld 项截止，已完成 %lld 项", due.count, due.filter(\.task.isDone).count)
        return formatter.string(from: date) + AppLocalized("，") + summary + (today ? AppLocalized("，今天") : "")
    }
    private var selected: Bool { JournalDates.calendar.isDate(date, inSameDayAs: selectedDate) }
    private var inMonth: Bool { JournalDates.calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month) }


    private var logButton: some View {
        Button(action: openLog) {
            HStack(spacing: 2) {
                Image(systemName: "text.alignleft")
                if logCount > 0 { Text("\(logCount)").monospacedDigit() }
            }
            .font(.system(size: typography.pt(10), weight: .medium))
            .foregroundStyle(selected ? Palette.accent : Palette.muted)
            .padding(.horizontal, 4).frame(height: 18)
            .background(Palette.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: CheckboxFramesKey.self, value: [Self.logButtonID.uuidString: proxy.frame(in: .named(Self.space))])
        })
        .help(logCount > 0 ? AppLocalizedFormat("打开这一天的日志（%lld 条）· ⌘J", logCount) : AppLocalized("打开这一天的日志 · ⌘J"))
        .accessibilityLabel("打开这一天的日志")
    }

    /// 有事项的日子用卡片底色，空白日只留细线：一眼看出哪些天有安排，今天与选中再用强调色区分。
    private var cellFill: Color {
        if selected || targeted { return Palette.soft }
        if today { return Palette.soft.opacity(0.6) }
        guard inMonth else { return .clear }
        return dueToday.isEmpty ? .clear : Palette.card
    }

    /// 空白日几乎不画边（悬停时才出现），整张月历不再是一格格的重框；有事项的日子是一张浮起的小卡片。
    private var cellStroke: Color {
        if selected || targeted { return Palette.accent }
        if hovered { return Palette.line }
        if today { return Palette.accent.opacity(0.35) }
        if !dueToday.isEmpty { return Palette.line.opacity(0.7) }
        return Palette.line.opacity(inMonth ? 0.28 : 0.15)
    }

    /// 只比较影响显示的数据；动作闭包每次都是新的，但行为由同一份状态决定。
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.date == rhs.date && lhs.selectedDate == rhs.selectedDate && lhs.displayedMonth == rhs.displayedMonth
            && lhs.height == rhs.height && lhs.items == rhs.items && lhs.dueToday == rhs.dueToday
            && lhs.logCount == rhs.logCount && lhs.focusSeconds == rhs.focusSeconds && lhs.readOnly == rhs.readOnly && lhs.today == rhs.today && lhs.store === rhs.store
    }

    /// 格子里放得下几行事项；放不下时最后一行换成「还有 N 项」。
    static func visibleCount(total: Int, cellHeight: CGFloat, headerHeight: CGFloat, rowHeight: CGFloat) -> Int {
        let available = cellHeight - 12 - headerHeight
        let rows = max(0, Int(floor((available + 3) / (rowHeight + 3))))
        return total <= rows ? total : max(0, rows - 1)
    }

    var body: some View {
        let headerHeight = ceil(max(18, typography.pt(15)))
        let shown = Self.visibleCount(total: items.count, cellHeight: height, headerHeight: headerHeight, rowHeight: typography.pt(22))
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                // 今天的日期是一颗实心的「结」，和时间轴上今天的标记一致。
                Text("\(JournalDates.calendar.component(.day, from: date))")
                    .font(.system(size: typography.pt(12), weight: selected || today ? .bold : .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(today ? Palette.onAccent : (inMonth ? Palette.ink : Palette.muted.opacity(0.7)))
                    .padding(.horizontal, today ? 5 : 0)
                    .frame(minWidth: today ? typography.pt(20) : 0, minHeight: typography.pt(18))
                    .background { if today { Capsule().fill(Palette.accent) } }
                Spacer(minLength: 0)
                if selected || hovered { logButton }
                if !dueToday.isEmpty {
                    Text("\(dueToday.filter(\.task.isDone).count)/\(dueToday.filter { !$0.task.isDropped }.count)")
                        .font(.system(size: typography.pt(10), weight: .medium)).monospacedDigit().foregroundStyle(Palette.muted)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .help("已完成 / 当天截止的事项")
                }
            }
            .frame(height: headerHeight)
            ForEach(items.prefix(shown)) { item in
                HStack(alignment: .top, spacing: 0) {
                    TaskPriorityButton(store: store, task: item.task, dragOrigin: .calendar)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: CheckboxFramesKey.self, value: [item.id.uuidString + "-priority": proxy.frame(in: .named(Self.space))])
                        })
                    if item.task.dueHasTime {
                        TaskDeadlineButton(store: store, task: item.task, compact: true, stacksRange: false)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: CheckboxFramesKey.self, value: [item.id.uuidString + "-time": proxy.frame(in: .named(Self.space))])
                            })
                    }
                    TaskLinkText(source: item.task.title, completed: item.task.isDone, color: item.task.isDropped ? Palette.muted : Palette.ink, fontSize: 11,
                                 edit: { editTask(item) },
                                 open: SafariLinks.open,
                                 maxLines: 1, displayName: item.task.calendarName, dragTaskID: item.id, compactLines: true)
                        .disabled(readOnly)
                    Button { store.toggleTodo(item.id, on: item.date) } label: {
                        Image(systemName: item.task.isDropped ? "xmark.circle.fill" : (item.task.completed ? "checkmark.circle.fill" : "circle"))
                            .foregroundStyle(item.task.isDropped ? Palette.muted : (item.task.completed ? Palette.success : Palette.deadline))
                            .frame(width: 16, alignment: .trailing)
                    }.buttonStyle(HitAreaButtonStyle(compact: true)).disabled(readOnly)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: CheckboxFramesKey.self, value: [item.id.uuidString: proxy.frame(in: .named(Self.space))])
                        })
                        .accessibilityLabel((item.task.isDropped ? "恢复已放弃的待办：" : (item.task.completed ? "标记未完成：" : "标记完成：")) + item.task.title)
                }.font(.system(size: typography.pt(11))).frame(height: typography.pt(22))
                    .background(Palette.background, in: RoundedRectangle(cornerRadius: 4))
                    .overlay { TaskLandingFlash(id: item.id, radius: 4) }
                    .contentShape(RoundedRectangle(cornerRadius: 4))
            }
            if shown < items.count {
                Button(action: select) {
                    Text("还有 \(items.count - shown) 项")
                        .font(.system(size: typography.pt(10), weight: .medium)).foregroundStyle(Palette.muted)
                        .padding(.horizontal, 4).frame(height: typography.pt(18))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("选中这一天，在左侧清单里看全部事项")
            }
            Spacer(minLength: 0)
        }
        .padding(6).frame(maxWidth: .infinity, alignment: .topLeading).frame(height: height, alignment: .topLeading)
        .overlay(alignment: .bottomLeading) {
            if focusSeconds > 0 {
                GeometryReader { proxy in
                    Capsule().fill(Palette.accent.opacity(0.55))
                        .frame(width: max(6, (proxy.size.width - 12) * min(1, focusSeconds / (4 * 3600))), height: 2.5)
                        .offset(x: 6, y: proxy.size.height - 6)
                }
                .allowsHitTesting(false)
                .help(AppLocalizedFormat("专注 %@", FocusSession.brief(focusSeconds)))
            }
        }
        .background(cellFill, in: RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)
            .strokeBorder(cellStroke, lineWidth: selected || targeted ? 1.5 : Metrics.hairline))
        // 悬停的格子浮起一点：能点的感觉。
        .shadow(color: .black.opacity(hovered && !selected ? 0.18 : 0), radius: hovered ? 4 : 0, x: 0, y: hovered ? 2 : 0)
        .animation(Motion.quick, value: hovered)
        .contentShape(Rectangle())
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(CheckboxFramesKey.self) { if checkboxFrames != $0 { checkboxFrames = $0 } }
        .background(CalendarCellClicks(select: select, expand: open, excluded: Array(checkboxFrames.values)))
        .onHover { hovered = $0 }
        .help("单击选择 · 双击添加事项")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityAction(named: "选择这一天", select)
        .accessibilityAction(named: "添加事项", open)
        .accessibilityAction(named: "打开这一天的日志", openLog)
        .onDrop(of: [TaskDragPayload.type], delegate: CalendarTaskDropTarget(store: store, destination: date, targeted: $targeted))
        .onChange(of: dragSession.activeID) { if $0 == nil { targeted = false } }
    }
}

private struct CheckboxFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
