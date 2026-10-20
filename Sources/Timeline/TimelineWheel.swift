import AppKit
import Combine
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

/// 桥接原生拖放事件循环：拿起任务时滚轮仍滚动整条轴，边缘停留可自动滚动。
struct TimelineWheelScrollBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> TimelineWheelScrollBridgeView {
        TimelineWheelScrollBridgeView()
    }
    func updateNSView(_ view: TimelineWheelScrollBridgeView, context: Context) {}
    static func dismantleNSView(_ view: TimelineWheelScrollBridgeView, coordinator: ()) { view.remove() }
}

final class TimelineWheelScrollBridgeView: NSView {
    private var monitor: Any?
    private var timer: Timer?
    private var dragObservation: AnyCancellable?
    var isAutoScrollRunning: Bool { timer != nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        remove()
        guard window != nil else { return }
        dragObservation = TaskDragSession.shared.$activeID.removeDuplicates().sink { [weak self] id in
            self?.setDragging(id != nil)
        }
    }
    private func setDragging(_ dragging: Bool) {
        stopDragging()
        guard dragging else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, TaskDragSession.shared.activeID != nil, event.window === self.window,
                  self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            self.scroll(by: -event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12))
            return nil
        }
        // 普通滚动完全交给系统；仅在原生拖放期间检测边缘停留。
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoScroll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }
    func remove() {
        dragObservation?.cancel(); dragObservation = nil
        stopDragging()
    }
    private func stopDragging() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        timer?.invalidate(); timer = nil
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) }; timer?.invalidate() }
    func scroll(by delta: CGFloat) {
        guard let scroll = enclosingScrollView, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let maxY = max(0, document.bounds.height - clip.bounds.height)
        let y = min(document.isFlipped ? maxY : 0,
                    max(document.isFlipped ? 0 : -maxY,
                        clip.bounds.origin.y + delta * (document.isFlipped ? 1 : -1)))
        guard abs(y - clip.bounds.origin.y) > 0.01 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
    }
    private func autoScroll() {
        guard TaskDragSession.shared.activeID != nil, let window, let scroll = enclosingScrollView else { return }
        let point = scroll.contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let bounds = scroll.contentView.bounds
        guard bounds.contains(point) else { return }
        let distance = scroll.documentView?.isFlipped == false ? bounds.maxY - point.y : point.y - bounds.minY
        if distance < 32 { self.scroll(by: -min(14, (32 - distance) / 3.5)) }
        else if distance > bounds.height - 32 { self.scroll(by: min(14, (distance - bounds.height + 32) / 3.5)) }
    }
}
