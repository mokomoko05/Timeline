import AppKit
import SwiftUI
import TimelineCore

/// 轴线只随日期区间高度伸缩，滚动时保持笔直。
/// 时间轴的「线」：今天这一段用强调色加粗，过去的日子淡一些，未设日期和省略的区间是虚线。
struct TimelineAxisStroke: View {
    enum Tone { case past, today, future }
    @Environment(\.typography) private var typography
    let highlighted: Bool
    var targeted = false
    var dashed = false
    var tone: Tone = .future

    private var color: Color {
        if highlighted || tone == .today { return Palette.accent.opacity(0.75) }
        return Palette.line.opacity(tone == .past ? 0.45 : 0.85)
    }

    var body: some View {
        TaskTimelineAxis(x: TaskTimelineLayout.axisX(typography))
            .stroke(color, style: StrokeStyle(lineWidth: targeted || tone == .today ? 1.75 : 1.1,
                                              lineCap: .round, dash: dashed ? [2, 4] : []))
            .allowsHitTesting(false)
    }
}
