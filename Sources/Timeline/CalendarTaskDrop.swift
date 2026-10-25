import AppKit
import SwiftUI
import TimelineCore

enum TaskDragOrigin {
    case taskList, calendar
}

@MainActor
final class TaskDragSession: ObservableObject {
    static let shared = TaskDragSession()
    @Published private(set) var activeID: UUID?
    private(set) var origin: TaskDragOrigin = .taskList

    func begin(_ id: UUID, origin: TaskDragOrigin = .taskList) {
        self.origin = origin
        activeID = id
        NSCursor.closedHand.set()
    }

    func end() {
        activeID = nil
        origin = .taskList
        NSCursor.arrow.set()
    }
}

/// 任务放下（或用快捷键改日期）后，在落点那一行闪一下。
/// 数据本身一次到位、不进动画事务：整窗重排时日历格子和每一行的原生文本都会跟着插值，帧率很低。
@MainActor
final class TaskLanding: ObservableObject {
    struct Mark: Equatable {
        let id: UUID
        let time: Date
    }

    static let shared = TaskLanding()
    @Published private(set) var mark: Mark?

    func land(_ id: UUID, _ change: () -> Void) {
        _ = landing(change)
        mark = Mark(id: id, time: Date())
    }

    /// 改动返回落点（比如新建的任务），结果不在动画里排版，再让落点闪一下。
    @discardableResult
    func landing<T>(_ change: () -> T, at id: (T) -> UUID? = { _ in nil }) -> T {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        let result = withTransaction(transaction, change)
        if let target = id(result) { mark = Mark(id: target, time: Date()) }
        return result
    }

    /// 跨日期移动时这一行会在新的分组里重新创建，出现时看一下是不是刚落下的那一项。
    func isFresh(_ id: UUID) -> Bool {
        guard let mark, mark.id == id else { return false }
        return Date().timeIntervalSince(mark.time) < 0.5
    }
}

/// 落点高亮：只是一层底色和细边的透明度变化，不牵动布局。
struct TaskLandingFlash: View {
    let id: UUID
    var radius: CGFloat = 8
    @ObservedObject private var landing = TaskLanding.shared
    @State private var glow = 0.0

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Palette.accent.opacity(0.14 * glow))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Palette.accent.opacity(0.55 * glow), lineWidth: Metrics.hairline))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { if landing.isFresh(id) { flash() } }
            .onChange(of: landing.mark) { mark in if mark?.id == id { flash() } }
    }

    private func flash() {
        guard !Motion.reduced else { return }
        withAnimation(.easeOut(duration: 0.12)) { glow = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { withAnimation(.easeOut(duration: 0.7)) { glow = 0 } }
    }
}

@MainActor
enum TaskDragDrop {
    static func receive(_ providers: [NSItemProvider], store: JournalStore, destination: Date?) -> Bool {
        guard !store.isReadOnly,
              let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(TaskDragPayload.type.identifier) }) else { return false }
        if let id = TaskDragSession.shared.activeID {
            move(id, store: store, destination: destination)
            TaskDragSession.shared.end()
        } else {
            _ = provider.loadDataRepresentation(forTypeIdentifier: TaskDragPayload.type.identifier) { data, error in
                guard error == nil, let data, let id = TaskDragPayload.decode(data) else { return }
                Task { @MainActor in move(id, store: store, destination: destination) }
            }
        }
        return true
    }

    static func move(_ id: UUID, store: JournalStore, destination: Date?) {
        guard !store.isReadOnly else { return }
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        guard let task = store.locate(id) else { return }
        if let due = task.task.dueDate, let destination, JournalDates.calendar.isDate(due, inSameDayAs: destination) { return }
        if task.task.dueDate == nil && destination == nil { return }
        TaskLanding.shared.land(id) { store.setDeadline(id, to: destination) }
    }
}

/// 日历接受任意任务；左侧分组只接受从日历拿起的任务。
struct CalendarTaskDropTarget: DropDelegate {
    let store: JournalStore
    let destination: Date?
    var calendarSourceOnly = false
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        acceptsSource && !store.isReadOnly && info.hasItemsConforming(to: [TaskDragPayload.type])
    }

    var acceptsSource: Bool {
        !calendarSourceOnly || (TaskDragSession.shared.activeID != nil && TaskDragSession.shared.origin == .calendar)
    }

    func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard validateDrop(info: info) else { return false }
        return receive(info.itemProviders(for: [TaskDragPayload.type]))
    }

    func receive(_ providers: [NSItemProvider]) -> Bool {
        guard acceptsSource else { return false }
        return TaskDragDrop.receive(providers, store: store, destination: destination)
    }
}
