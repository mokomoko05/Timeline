import AppKit
import Combine
import SwiftUI
import TimelineCore

/// 展开、定位只让时间轴订阅；主窗口和月历不订阅这些变化。
@MainActor
final class TaskTimelineNavigation: ObservableObject {
    struct Navigation: Equatable {
        let token = UUID()
        let target: AnyHashable
        let anchor: UnitPoint?
        let section: String?
    }

    @Published private(set) var request: Navigation?

    func scroll(to target: AnyHashable, anchor: UnitPoint? = .top, section: String? = nil) {
        request = Navigation(target: target, anchor: anchor, section: section)
    }
}

@MainActor
final class TaskTimelinePresentation: ObservableObject {
    @Published var expanded: Set<UUID> = []
    @Published var revealedDates: Set<Date> = []
    let navigation = TaskTimelineNavigation()

    func scroll(to target: AnyHashable, anchor: UnitPoint? = .top, section: String? = nil) {
        navigation.scroll(to: target, anchor: anchor, section: section)
    }

    func scroll(to task: UUID, anchor: UnitPoint? = .top, section: String? = nil) {
        scroll(to: AnyHashable(TaskTimelineAnchor.task(task)), anchor: anchor, section: section)
    }

    func reveal(near date: Date, index: TaskTimelineIndex) {
        let dates = TaskTimelineSection.datesNear(date)
        let revealed = revealedDates.union(dates)
        let finished = expanded.union(dates.flatMap { index.byDay[$0] ?? [] }.map(\.id))
        if revealedDates != revealed { revealedDates = revealed }
        if expanded != finished { expanded = finished }
        scroll(to: TaskTimelineSection.dayID(date))
    }

    func reset(today: Date) {
        if !expanded.isEmpty { expanded = [] }
        if !revealedDates.isEmpty { revealedDates = [] }
        scroll(to: TaskTimelineSection.dayID(today))
    }
}

struct TaskTimelinePane: View {
    let store: JournalStore
    let tasks: [ScheduledTask]
    let today: Date
    let selectedDate: Date
    @ObservedObject var presentation: TaskTimelinePresentation
    @Binding var requestedEdit: UUID?
    @Binding var scrollTarget: UUID?
    @Binding var scrollGroup: String?
    let rowRegions: TaskRowRegions
    let navigate: (Date) -> Void
    let next: () -> Void
    @EnvironmentObject private var interaction: WorkspaceInteraction
    @State private var index = TaskTimelineIndexCache()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                TaskTimelineView(store: store, tasks: tasks, today: today, selectedDate: selectedDate,
                    expanded: $presentation.expanded, requestedEdit: $requestedEdit, navigate: navigate,
                    selectTask: { interaction.activePane = .tasks }, next: next,
                    revealedDates: $presentation.revealedDates, usesLazyLayout: true)
                    .padding(.vertical, 12)
                    .onPreferenceChange(TaskRowGlobalFramesKey.self) { rowRegions.rows = $0 }
            }
            .background(GeometryReader { geometry in
                Color.clear.onAppear { rowRegions.viewport = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { rowRegions.viewport = $0 }
            })
            .onAppear {
                if presentation.navigation.request == nil { presentation.scroll(to: TaskTimelineSection.dayID(selectedDate)) }
            }
            .onChange(of: scrollTarget) { id in
                guard let id else { return }
                revealTask(id, anchor: .center, selectDate: true)
                scrollTarget = nil
            }
            .onChange(of: scrollGroup) { group in
                guard let group else { return }
                if group == "undated" { presentation.scroll(to: "undated") }
                else if group == "today" { presentation.scroll(to: TaskTimelineSection.dayID(today)) }
                else if let task = tasks.first(where: { !$0.task.completed && (group == "overdue" ? ($0.task.effectiveDeadline ?? .distantFuture) < Date() : JournalDates.calendar.isDateInToday($0.task.timelineDate ?? .distantPast)) }) {
                    revealTask(task.id, anchor: .top)
                }
                scrollGroup = nil
            }
            .onChange(of: requestedEdit) { id in
                if let id { revealTask(id, anchor: .center) }
            }
            .onChange(of: interaction.selectedTaskID) { id in
                if interaction.suppressNextTaskScroll { interaction.suppressNextTaskScroll = false; return }
                if let id, presentation.navigation.request?.target != AnyHashable(TaskTimelineAnchor.task(id)) {
                    if rowRegions.rows[id] != nil { presentation.scroll(to: id, anchor: nil) }
                    else { revealTask(id, anchor: nil) }
                }
            }
            .background(TaskTimelineScrollDriver(navigation: presentation.navigation, proxy: proxy))
        }
    }

    private func revealTask(_ id: UUID, anchor: UnitPoint?, selectDate: Bool = false) {
        var section: String?
        if let item = store.locate(id) {
            if let date = item.task.timelineDate {
                if selectDate { navigate(date) }
                presentation.reveal(near: date, index: index.index(for: tasks))
                if rowRegions.rows[id] == nil { section = TaskTimelineSection.dayID(date) }
            }
            if item.task.completed { presentation.expanded.insert(id) }
        }
        presentation.scroll(to: id, anchor: anchor, section: section)
    }
}

/// 定位信号只刷新这个透明节点，不让所有任务和月历重新排版。
private struct TaskTimelineScrollDriver: View {
    @ObservedObject var navigation: TaskTimelineNavigation
    let proxy: ScrollViewProxy
    @State private var layout = TaskTimelineLayoutBarrier()

    var body: some View {
        Color.clear.allowsHitTesting(false)
            .background(TaskTimelineLayoutView(barrier: layout))
            .task(id: navigation.request) {
                guard let request = navigation.request else { return }
                await Task.yield()
                guard !Task.isCancelled, navigation.request == request else { return }
                layout.flush()
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                // 远处任务还没创建时，先让它所属的日期进入懒布局，再精确定位到任务。
                if let section = request.section {
                    withTransaction(transaction) { proxy.scrollTo(section, anchor: .top) }
                    await Task.yield()
                    guard !Task.isCancelled, navigation.request == request else { return }
                    layout.flush()
                }
                withTransaction(transaction) { proxy.scrollTo(request.target, anchor: request.anchor) }
                if case .task(let id) = request.target.base as? TaskTimelineAnchor {
                    await Task.yield()
                    guard !Task.isCancelled, navigation.request == request else { return }
                    layout.flush()
                    layout.ensureTaskVisible(id)
                }
            }
    }
}

/// 展开和收起改变原生文档高度后，先完成这次布局，再读取 ScrollViewReader 的锚点。
@MainActor
private final class TaskTimelineLayoutBarrier {
    weak var view: NSView?
    func flush() { view?.window?.contentView?.layoutSubtreeIfNeeded() }

    func ensureTaskVisible(_ id: UUID) {
        guard let root = view?.window?.contentView else { return }
        func find(_ view: NSView) -> TaskHandleView? {
            if let handle = view as? TaskHandleView, handle.taskID == id, handle.reorder != nil { return handle }
            for child in view.subviews { if let handle = find(child) { return handle } }
            return nil
        }
        // 懒布局估算高度变成真实高度时，SwiftUI 可能把目标移出视口；用最终原生坐标补齐可见范围。
        guard let handle = find(root), handle.visibleRect.intersection(handle.bounds).isEmpty,
              let scroll = handle.enclosingScrollView, let document = scroll.documentView else { return }
        document.scrollToVisible(handle.convert(handle.bounds, to: document).insetBy(dx: 0, dy: -12))
    }
}

private struct TaskTimelineLayoutView: NSViewRepresentable {
    let barrier: TaskTimelineLayoutBarrier
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        barrier.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { barrier.view = view }
}
