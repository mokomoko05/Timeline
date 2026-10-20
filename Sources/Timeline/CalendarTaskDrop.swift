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
        withAnimation(Motion.quick) { store.setDeadline(id, to: destination) }
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
