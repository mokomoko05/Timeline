import AppKit
import SwiftUI
import TimelineCore
import UniformTypeIdentifiers

struct DeadlineDayCell: View {
    @Environment(\.typography) private var typography
    @ObservedObject var store: JournalStore
    let date: Date
    let selectedDate: Date
    let displayedMonth: Date
    let height: CGFloat
    let items: [ScheduledTask]
    let select: () -> Void
    let open: () -> Void
    /// 打开这一天的日志（选中的那一格常驻显示按钮，其他格子悬停时出现）。
    var openLog: () -> Void = {}
    let editTask: (ScheduledTask) -> Void
    @State private var targeted = false
    @State private var checkboxFrames: [String: CGRect] = [:]
    @State private var after = false
    @State private var hovered = false
    /// 日志按钮在 preference 里的固定标识：和勾选框一样，点它只打开日志，不触发「选中日期」。
    static let logButtonID = UUID(uuidString: "00000000-0000-0000-0000-00000000106E")!
    @ObservedObject private var dragSession = TaskDragSession.shared

    /// 日历只在任务的截止日期那天显示它。
    static func previewItems(dueItems: [ScheduledTask], hideCompleted: Bool) -> [ScheduledTask] {
        dueItems.sorted(by: TaskSortMode.deadline.precedes)
            .filter { !hideCompleted || !$0.task.completed }
    }
    private var dueToday: [ScheduledTask] { store.calendarDeadlines[JournalDates.key(date)] ?? [] }
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
        let summary = due.isEmpty ? "没有截止事项" : "\(due.count) 项截止，已完成 \(due.filter(\.task.isDone).count) 项"
        return "\(formatter.string(from: date))，\(summary)\(today ? "，今天" : "")"
    }
    private var selected: Bool { JournalDates.calendar.isDate(date, inSameDayAs: selectedDate) }
    private var today: Bool { JournalDates.calendar.isDateInToday(date) }
    private var inMonth: Bool { JournalDates.calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month) }

    private var logCount: Int { store.entry(for: date).logs.count }

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
        .help(logCount > 0 ? "打开这一天的日志（\(logCount) 条）· ⌘J" : "打开这一天的日志 · ⌘J")
        .accessibilityLabel("打开这一天的日志")
    }

    var body: some View {
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Text("\(JournalDates.calendar.component(.day, from: date))")
                    .font(.system(size: typography.pt(12), weight: selected || today ? .bold : .medium, design: .rounded))
                    .foregroundStyle(today ? Palette.accent : (inMonth ? Palette.ink : Palette.muted))
                Spacer(minLength: 0)
                if selected || hovered { logButton }
                if !dueToday.isEmpty {
                    Text("\(dueToday.filter(\.task.isDone).count)/\(dueToday.filter { !$0.task.isDropped }.count)")
                        .font(.system(size: typography.pt(10), design: .monospaced)).foregroundStyle(Palette.muted)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .help("已完成 / 当天截止的事项")
                }
            }
            .frame(height: ceil(max(18, typography.pt(15))))
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 0) {
                    Button { store.toggleTodo(item.id, on: item.date) } label: {
                        Image(systemName: item.task.isDropped ? "xmark.circle.fill" : (item.task.completed ? "checkmark.circle.fill" : "circle"))
                            .foregroundStyle(item.task.isDropped ? Palette.muted : (item.task.completed ? Palette.success : Palette.deadline))
                            .frame(width: 16, alignment: .trailing)
                    }.buttonStyle(HitAreaButtonStyle(compact: true)).disabled(store.isReadOnly)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: CheckboxFramesKey.self, value: [item.id.uuidString: proxy.frame(in: .named(Self.space))])
                        })
                        .accessibilityLabel((item.task.isDropped ? "恢复已放弃的待办：" : (item.task.completed ? "标记未完成：" : "标记完成：")) + item.task.title)
                    TaskPriorityButton(store: store, task: item.task)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: CheckboxFramesKey.self, value: [item.id.uuidString + "-priority": proxy.frame(in: .named(Self.space))])
                        })
                    if item.task.dueHasTime {
                        TaskDeadlineButton(store: store, task: item.task, compact: true)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: CheckboxFramesKey.self, value: [item.id.uuidString + "-time": proxy.frame(in: .named(Self.space))])
                            })
                    }
                    TaskLinkText(source: item.task.title, completed: item.task.completed, color: Palette.ink, fontSize: 11,
                                 edit: { editTask(item) },
                                 open: SafariLinks.open,
                                 maxLines: 1, displayName: item.task.calendarName, dragTaskID: item.id, compactLines: true)
                        .disabled(store.isReadOnly)
                }.font(.system(size: typography.pt(11))).frame(height: typography.pt(22))
                    .background(Palette.background, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(RoundedRectangle(cornerRadius: 4))
                    .modifier(TaskDragSource(task: item.task, enabled: !store.isReadOnly, edgeDragging: false))
            }
            Spacer(minLength: 0)
        }
        .padding(6).frame(maxWidth: .infinity, alignment: .topLeading).frame(height: height, alignment: .topLeading)
        .background(selected || today || targeted ? Palette.soft : (inMonth ? Palette.card : Palette.background), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected || targeted ? Palette.accent : Palette.line.opacity(hovered ? 1 : 0.55), lineWidth: selected || targeted ? 1.5 : 0.5))
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
        .onDrop(of: [TaskDragPayload.type], delegate: TaskDropTarget(store: store, destination: date, targeted: $targeted, after: $after))
        .onChange(of: dragSession.activeID) { if $0 == nil { targeted = false } }
    }
}

private struct CheckboxFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
