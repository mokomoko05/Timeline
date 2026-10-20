import AppKit
import SwiftUI
import TimelineCore

struct TaskDragHandle: View {
    let task: Todo
    let enabled: Bool
    var select: () -> Void = {}
    /// 仅在当前日期分组中上下调整顺序。
    var reorder: TaskReorderHooks?

    var body: some View {
        NativeTaskHandle(task: task, enabled: enabled, select: select, reorder: reorder)
            .frame(width: 30, height: 30)
            .help("在同一日期内拖动排序")
            .accessibilityLabel("在同一日期内拖动任务排序")
    }
}

struct NativeTaskHandle: NSViewRepresentable {
    let task: Todo
    let enabled: Bool
    var drawsHandle = true
    var select: () -> Void = {}
    var reorder: TaskReorderHooks?
    var priorityItems: [RadialItem]?
    var priorityColor: NSColor?

    func makeNSView(context: Context) -> TaskHandleView { TaskHandleView() }
    func updateNSView(_ view: TaskHandleView, context: Context) {
        view.priorityItems = priorityItems
        view.priorityColor = priorityColor
        view.reorder = reorder
        view.taskID = enabled ? task.id : nil
        view.drawsHandle = drawsHandle
        view.onSelect = select
        view.appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

final class TaskHandleView: NSView {
    var taskID: UUID?
    var drawsHandle = true
    var onSelect: (() -> Void)?
    var isPressed: Bool { initialEvent != nil }
    private var available: Bool { taskID != nil }
    var reorder: TaskReorderHooks?
    var priorityItems: [RadialItem]?
    var priorityColor: NSColor?
    private var initialEvent: NSEvent?

    override func draw(_ dirtyRect: NSRect) {
        if let priorityColor {
            priorityColor.setFill()
            let radius: CGFloat = isPressed ? 4.5 : 3.5
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - radius, y: bounds.midY - radius, width: radius * 2, height: radius * 2)).fill()
            return
        }
        guard drawsHandle else { return }
        NSColor.secondaryLabelColor.setFill()
        for column in 0..<2 {
            for row in 0..<3 {
                NSBezierPath(ovalIn: NSRect(x: bounds.midX - 4 + CGFloat(column) * 5,
                                           y: bounds.midY - 6.5 + CGFloat(row) * 5, width: 3, height: 3)).fill()
            }
        }
    }

    override func resetCursorRects() {
        guard available else { return }
        addCursorRect(bounds, cursor: reorder == nil ? .arrow : .openHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        available ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard available else { return }
        if event.modifierFlags.contains(.control), priorityItems != nil {
            rightMouseDown(with: event)
            return
        }
        PriorityPaletteController.shared.dismiss()
        initialEvent = event
        needsDisplay = true
        if reorder != nil { NSCursor.closedHand.set() }
        onSelect?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard available, let priorityItems else { return }
        initialEvent = nil
        needsDisplay = true
        onSelect?()
        PriorityPaletteController.shared.present(items: priorityItems, anchor: self)
    }

    override func mouseUp(with event: NSEvent) {
        initialEvent = nil
        needsDisplay = true
        if reordering { endReorder(commit: true) }
        else { NSCursor.arrow.set(); window?.invalidateCursorRects(for: self) }
    }

    override func mouseDragged(with event: NSEvent) {
        if reordering {
            NSCursor.closedHand.set()
            track(event.locationInWindow)
            return
        }
        guard taskID != nil, let initial = initialEvent,
              hypot(event.locationInWindow.x - initial.locationInWindow.x,
                    event.locationInWindow.y - initial.locationInWindow.y) > 3 else { return }
        // 圆点只负责当前日期分组内重排；单项分组不发起拖放。
        if let reorder, reorder.begin() {
            startReorder(from: initial)
            track(event.locationInWindow)
            return
        }
        initialEvent = nil
        needsDisplay = true
        NSCursor.arrow.set()
    }

    // MARK: - 清单内排序

    private var reordering = false
    var isReordering: Bool { reordering }
    private var startY: CGFloat = 0
    private var startScroll: CGFloat = 0
    private var autoscroll: Timer?

    private var scrollView: NSScrollView? { enclosingScrollView }

    private func scrollOffset() -> CGFloat {
        guard let scroll = scrollView else { return 0 }
        let y = scroll.contentView.bounds.origin.y
        return (scroll.documentView?.isFlipped ?? true) ? y : -y
    }

    private func startReorder(from event: NSEvent) {
        reordering = true
        startY = event.locationInWindow.y
        startScroll = scrollOffset()
        NSCursor.closedHand.set()
        autoscroll = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscrollTick() }
        }
    }

    private func endReorder(commit: Bool) {
        autoscroll?.invalidate()
        autoscroll = nil
        reordering = false
        initialEvent = nil
        if commit { reorder?.end() } else { reorder?.cancel() }
        NSCursor.arrow.set()
        window?.invalidateCursorRects(for: self)
    }

    /// 指针（窗口坐标）相对按下位置在清单内容里向下的位移 = 指针本身向下移动的距离 + 清单滚动的距离。
    private func track(_ point: NSPoint) {
        reorder?.update(-(point.y - startY) + (scrollOffset() - startScroll))
    }

    /// 拖到清单上下边缘附近时自动滚动，按住不动也会继续。
    private func autoscrollTick() {
        guard reordering, let window, let scroll = scrollView else { return }
        let point = window.mouseLocationOutsideOfEventStream
        let frame = scroll.convert(scroll.bounds, to: nil)
        let zone: CGFloat = 40
        var delta: CGFloat = 0
        if point.y > frame.maxY - zone { delta = -min(14, (point.y - (frame.maxY - zone)) / 2.5 + 1) }
        else if point.y < frame.minY + zone { delta = min(14, ((frame.minY + zone) - point.y) / 2.5 + 1) }
        guard delta != 0, let document = scroll.documentView else { track(point); return }
        let clip = scroll.contentView
        let maxY = max(0, document.bounds.height - clip.bounds.height)
        let sign: CGFloat = document.isFlipped ? 1 : -1
        let newY = min(max(clip.bounds.origin.y + delta * sign, document.isFlipped ? 0 : -maxY), document.isFlipped ? maxY : 0)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: newY))
        scroll.reflectScrolledClipView(clip)
        track(point)
    }
}
