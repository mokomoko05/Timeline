import SwiftUI
import TimelineCore

struct TaskTimelinePosition {
    let hasPrevious: Bool
    let hasNext: Bool
}

struct TaskTimelineConnector: Shape {
    let position: TaskTimelinePosition
    var nodeRadius: CGFloat = 6
    var branch = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let halfGap = TaskReorderModel.spacing / 2
        if position.hasPrevious {
            path.move(to: CGPoint(x: rect.midX, y: rect.minY - halfGap))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.midY - nodeRadius))
        }
        if position.hasNext {
            path.move(to: CGPoint(x: rect.midX, y: rect.midY + nodeRadius))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY + halfGap))
        }
        if branch {
            path.move(to: CGPoint(x: rect.midX + nodeRadius, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX + 6, y: rect.midY))
        }
        return path
    }
}

/// 连续的已结束事项在原来的时间位置折叠，不改变任务顺序。
struct TaskTimelineItem: Identifiable {
    let tasks: [ScheduledTask]
    let folded: Bool
    var id: UUID { tasks[0].id }

    static func items(for tasks: [ScheduledTask], expanded: Set<UUID> = []) -> [Self] {
        var result: [Self] = []
        var finished: [ScheduledTask] = []
        func flush() {
            guard !finished.isEmpty else { return }
            result.append(Self(tasks: finished, folded: true))
            finished = []
        }
        for task in tasks {
            if task.task.completed && !expanded.contains(task.id) {
                finished.append(task)
            } else {
                flush()
                result.append(Self(tasks: [task], folded: false))
            }
        }
        flush()
        return result
    }
}

struct FoldedTaskTimelineRow: View {
    @Environment(\.typography) private var typography
    let tasks: [ScheduledTask]
    let position: TaskTimelinePosition
    let expand: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("···")
                .font(.system(size: typography.pt(10), design: .monospaced))
                .foregroundStyle(Palette.muted)
                .frame(width: TaskTimelineLayout.timeWidth(typography), alignment: .trailing)
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
                .frame(width: 22).frame(maxHeight: .infinity)
                .background {
                    TaskTimelineConnector(position: position)
                        .stroke(Palette.line, lineWidth: 1).allowsHitTesting(false)
                }
            Button(action: expand) {
                HStack(spacing: 6) {
                    let completed = tasks.filter(\.task.isDone).count
                    let dropped = tasks.filter(\.task.isDropped).count
                    if completed > 0 { Text("已完成 \(completed) 项") }
                    if dropped > 0 { Text("已放弃 \(dropped) 项") }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                }
                .font(.system(size: typography.pt(11)))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 8).frame(height: typography.pt(26))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("展开已结束事项")
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

enum TaskTimelineLayout {
    static func timeWidth(_ typography: AppTypography) -> CGFloat { typography.pt(62) }
}
