import SwiftUI

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
