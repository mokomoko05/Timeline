import AppKit
import SwiftUI
import TimelineCore

@MainActor
final class TaskDragSession: ObservableObject {
    static let shared = TaskDragSession()
    @Published private(set) var activeID: UUID?

    func begin(_ id: UUID) {
        activeID = id
        NSCursor.closedHand.set()
    }

    func end() {
        activeID = nil
        NSCursor.arrow.set()
    }
}

@MainActor
enum TaskDragDrop {
    static func receive(_ providers: [NSItemProvider], store: JournalStore, destination: Date) -> Bool {
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

    static func move(_ id: UUID, store: JournalStore, destination: Date) {
        guard !store.isReadOnly else { return }
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        guard let task = store.locate(id) else { return }
        if let due = task.task.dueDate, JournalDates.calendar.isDate(due, inSameDayAs: destination) { return }
        withAnimation(Motion.quick) { store.setDeadline(id, to: destination) }
    }
}

/// 只有日历日期格接受改日期拖放，时间线不注册放置目标。
struct CalendarTaskDropTarget: DropDelegate {
    let store: JournalStore
    let destination: Date
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        !store.isReadOnly && info.hasItemsConforming(to: [TaskDragPayload.type])
    }

    func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard validateDrop(info: info) else { return false }
        return TaskDragDrop.receive(info.itemProviders(for: [TaskDragPayload.type]), store: store, destination: destination)
    }
}
