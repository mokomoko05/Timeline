import AppKit
import Combine
import SwiftUI
import TimelineCore

private struct TimelineViewportKey: EnvironmentKey { static let defaultValue = CGRect.zero }
extension EnvironmentValues {
    var timelineViewport: CGRect {
        get { self[TimelineViewportKey.self] }
        set { self[TimelineViewportKey.self] = newValue }
    }
}

/// 统一的圆柱投影：条目只缩小和平移，始终保持平直。
enum TimelineWheelProjection {
    static func depth(y: CGFloat, viewport: CGRect) -> CGFloat {
        guard viewport.height > 0 else { return 0 }
        return min(1, abs((y - viewport.midY) / (viewport.height * 0.55)))
    }
    static func scale(y: CGFloat, viewport: CGRect) -> CGFloat {
        let d = depth(y: y, viewport: viewport)
        return 1 - 0.16 * d * d
    }
    static func inset(y: CGFloat, viewport: CGRect) -> CGFloat {
        let d = depth(y: y, viewport: viewport)
        return 10 * d * d
    }
}

struct TimelineWheelDepth: ViewModifier {
    @Environment(\.timelineViewport) private var viewport
    @Environment(\.typography) private var typography
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.visualEffect { effect, geometry in
                let frame = geometry.frame(in: .global)
                let d = TimelineWheelProjection.depth(y: frame.midY, viewport: viewport)
                return effect
                    .scaleEffect(TimelineWheelProjection.scale(y: frame.midY, viewport: viewport),
                                 anchor: UnitPoint(x: TaskTimelineLayout.axisX(typography) / max(1, frame.width), y: 0.5))
                    .offset(x: -TimelineWheelProjection.inset(y: frame.midY, viewport: viewport))
                    .opacity(1 - 0.45 * d * d)
            }
        } else {
            content.modifier(LegacyTimelineWheelDepth())
        }
    }
}

private struct LegacyTimelineWheelDepth: ViewModifier {
    @Environment(\.timelineViewport) private var viewport
    @Environment(\.typography) private var typography
    @State private var frame = CGRect.zero
    func body(content: Content) -> some View {
        let d = TimelineWheelProjection.depth(y: frame.midY, viewport: viewport)
        content
            .scaleEffect(TimelineWheelProjection.scale(y: frame.midY, viewport: viewport),
                         anchor: UnitPoint(x: TaskTimelineLayout.axisX(typography) / max(1, frame.width), y: 0.5))
            .offset(x: -TimelineWheelProjection.inset(y: frame.midY, viewport: viewport))
            .opacity(1 - 0.45 * d * d)
            .background(GeometryReader { geometry in
                Color.clear.onAppear { frame = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { frame = $0 }
            })
    }
}

struct TimelineWheelAxis: Shape {
    let x: CGFloat
    let originY: CGFloat
    let viewport: CGRect
    func path(in rect: CGRect) -> Path {
        Path { path in
            for step in 0...24 {
                let y = rect.height * CGFloat(step) / 24
                let point = CGPoint(x: x - TimelineWheelProjection.inset(y: originY + y, viewport: viewport), y: y)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }
}

/// 单独更新轴线的投影，滚动时不使整个日期段及其任务重新求值。
struct TimelineWheelAxisStroke: View {
    @Environment(\.timelineViewport) private var viewport
    @Environment(\.typography) private var typography
    let highlighted: Bool
    var targeted = false
    var dashed = false
    @State private var originY: CGFloat = 0

    var body: some View {
        TimelineWheelAxis(x: TaskTimelineLayout.axisX(typography), originY: originY, viewport: viewport)
            .stroke(highlighted ? Palette.accent : Palette.line.opacity(0.65),
                    style: StrokeStyle(lineWidth: targeted ? 1.5 : 1, dash: dashed ? [3, 4] : []))
            .background(GeometryReader { geometry in
                Color.clear.onAppear { originY = geometry.frame(in: .global).minY }
                    .onChange(of: geometry.frame(in: .global).minY) { originY = $0 }
            })
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
