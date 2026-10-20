import AppKit
import SwiftUI
import TimelineCore

/// 轴线只随日期区间高度伸缩，滚动时保持笔直。
struct TimelineAxisStroke: View {
    @Environment(\.typography) private var typography
    let highlighted: Bool
    var targeted = false
    var dashed = false

    var body: some View {
        TaskTimelineAxis(x: TaskTimelineLayout.axisX(typography))
            .stroke(highlighted ? Palette.accent : Palette.line.opacity(0.65),
                    style: StrokeStyle(lineWidth: targeted ? 1.5 : 1, dash: dashed ? [3, 4] : []))
            .allowsHitTesting(false)
    }
}
