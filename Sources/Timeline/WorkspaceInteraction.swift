import AppKit
import SwiftUI

enum WorkspacePane: String {
    case tasks = "待办清单", summary = "总结", calendar = "日历"
}

@MainActor
final class WorkspaceInteraction: ObservableObject {
    @Published var activePane: WorkspacePane = .tasks
    var suppressNextTaskScroll = false
    @Published var selectedTaskID: UUID?
    /// 请某一行打开它的面板（键盘或菜单触发）；行打开后清掉。
    @Published var taskPopover: TaskPopoverRequest?
}

struct TaskPopoverRequest: Equatable {
    enum Kind { case details, deadline, tags }
    let id: UUID
    let kind: Kind
}
