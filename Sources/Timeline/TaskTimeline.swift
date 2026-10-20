import SwiftUI

struct TaskTimelinePosition {
    let hasPrevious: Bool
    let hasNext: Bool
}

struct TaskTimelineConnector: Shape {
    let position: TaskTimelinePosition
    var nodeRadius: CGFloat = 12

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
        return path
    }
}
