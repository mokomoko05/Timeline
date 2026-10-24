import AppKit
import SwiftUI
import TimelineCore
import UniformTypeIdentifiers

enum TaskDragPayload {
    static let type = UTType(exportedAs: "local.timeline.task", conformingTo: .data)
    static var pasteboardType: NSPasteboard.PasteboardType { .init(type.identifier) }

    static func encode(_ id: UUID) -> Data { Data(id.uuidString.utf8) }

    static func decode(_ data: Data) -> UUID? {
        guard data.count == 36, let value = String(data: data, encoding: .utf8) else { return nil }
        return UUID(uuidString: value)
    }

    static func provider(_ id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = encode(id)
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}



struct TaskDragHandle: View {
    let task: Todo
    let enabled: Bool
    var select: () -> Void = {}
    /// 上下拖动仅在当前日期分组中排序，横向离开清单可拖至日历。
    var reorder: TaskReorderHooks?

    var body: some View {
        NativeTaskHandle(task: task, enabled: enabled, select: select, reorder: reorder)
            .frame(width: 30, height: 30)
            .help("同一日期内上下排序；拖到日历修改日期")
            .accessibilityLabel("排序任务或拖到日历修改日期")
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
    var dragOrigin: TaskDragOrigin = .taskList

    func makeNSView(context: Context) -> TaskHandleView {
        let view = TaskHandleView()
        // 平移时由图层合成，不每帧重画珠子。
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        return view
    }
    func updateNSView(_ view: TaskHandleView, context: Context) {
        view.priorityItems = priorityItems
        view.dragOrigin = dragOrigin
        view.priorityColor = priorityColor
        view.reorder = reorder
        view.taskID = enabled ? task.id : nil
        view.titleSource = (task.title, task.calendarName)
        view.drawsHandle = drawsHandle
        view.onSelect = select
        view.appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

final class TaskHandleView: NSView, NSDraggingSource {
    var dragOrigin: TaskDragOrigin = .taskList
    var titleSource: (title: String, alias: String) = ("", "")
    var title: String { String(TaskText.rendered(titleSource.title, alias: titleSource.alias).characters) }
    var startNativeDrag: (UUID, String, TaskHandleView, NSEvent) -> Void = { id, title, view, event in
        NativeTaskDrag.begin(id: id, title: title, view: view, source: view, event: event)
    }
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
            // 时间轴是一根线，每个待办是穿在线上的一颗珠子：底色挡住轴线，外圈是优先级色的细环，中间一粒实心。
            let outer: CGFloat = isPressed ? 6.5 : 5.5
            let ring = NSRect(x: bounds.midX - outer, y: bounds.midY - outer, width: outer * 2, height: outer * 2)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                NativePalette.background.setFill()
                NSBezierPath(ovalIn: ring).fill()
                priorityColor.withAlphaComponent(0.22).setFill()
                NSBezierPath(ovalIn: ring).fill()
                priorityColor.withAlphaComponent(0.85).setStroke()
                let border = NSBezierPath(ovalIn: ring.insetBy(dx: 0.6, dy: 0.6))
                border.lineWidth = 1.2
                border.stroke()
                priorityColor.setFill()
                let inner: CGFloat = isPressed ? 3 : 2.5
                NSBezierPath(ovalIn: NSRect(x: bounds.midX - inner, y: bounds.midY - inner, width: inner * 2, height: inner * 2)).fill()
            }
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
        addCursorRect(bounds, cursor: .openHand)
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
        NSCursor.closedHand.set()
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
            // 横向离开清单、或拖进左侧的日期一栏，就切换为改日期的拖放（可以放在日历或时间轴的日期结上）；
            // 越过日期分组仍按组内排序。
            if leftList(event.locationInWindow) || inDateGutter(event.locationInWindow)
                || reorder?.escaped(translation(event.locationInWindow)) == true, let id = taskID {
                endReorder(commit: false)
                startNativeDrag(id, title, self, event)
                return
            }
            track(event.locationInWindow)
            return
        }
        guard let id = taskID, let initial = initialEvent,
              hypot(event.locationInWindow.x - initial.locationInWindow.x,
                    event.locationInWindow.y - initial.locationInWindow.y) > 3 else { return }
        if reorder == nil || leftList(event.locationInWindow) || inDateGutter(event.locationInWindow) {
            initialEvent = nil
            startNativeDrag(id, title, self, event)
            return
        }
        if let reorder, reorder.begin() {
            startReorder(from: initial)
            track(event.locationInWindow)
            return
        }
        // 这一天只有它一项：纵向拖出一段距离就是要换日期。
        if abs(event.locationInWindow.y - initial.locationInWindow.y) > 24 {
            initialEvent = nil
            startNativeDrag(id, title, self, event)
        }
    }

    // MARK: - 清单内排序

    private var reordering = false
    var isReordering: Bool { reordering }
    private var startY: CGFloat = 0
    private var startScroll: CGFloat = 0
    private var autoscroll: Timer?

    deinit { autoscroll?.invalidate() }

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

    /// 指针进了时间轴左侧的日期一栏（轴线左边）。
    private func inDateGutter(_ point: NSPoint) -> Bool {
        guard let scroll = scrollView else { return false }
        let frame = scroll.convert(scroll.bounds, to: nil)
        return point.x < frame.minX + 46 * UIScale.factor && point.x >= frame.minX - 70
    }

    private func leftList(_ point: NSPoint) -> Bool {
        guard let scroll = scrollView else { return false }
        let frame = scroll.convert(scroll.bounds, to: nil)
        return point.x < frame.minX - 70 || point.x > frame.maxX + 70
    }

    /// 指针（窗口坐标）相对按下位置在清单内容里向下的位移 = 指针本身向下移动的距离 + 清单滚动的距离。
    private func translation(_ point: NSPoint) -> CGFloat { -(point.y - startY) + (scrollOffset() - startScroll) }

    private func track(_ point: NSPoint) {
        reorder?.update(translation(point))
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
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    /// 拖到别的日期时，靠近清单上下边缘也会自动滚动，长时间轴也能一路拖到远处的日期。
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        NSCursor.closedHand.set()
        guard let scroll = scrollView, let window = scroll.window, let document = scroll.documentView else { return }
        let point = window.convertPoint(fromScreen: screenPoint)
        let frame = scroll.convert(scroll.bounds, to: nil)
        guard point.x >= frame.minX - 40, point.x <= frame.maxX + 40 else { return }
        let zone: CGFloat = 44
        var delta: CGFloat = 0
        if point.y > frame.maxY - zone { delta = -min(16, (point.y - (frame.maxY - zone)) / 2 + 2) }
        else if point.y < frame.minY + zone { delta = min(16, ((frame.minY + zone) - point.y) / 2 + 2) }
        guard delta != 0 else { return }
        let clip = scroll.contentView
        let maxY = max(0, document.bounds.height - clip.bounds.height)
        let sign: CGFloat = document.isFlipped ? 1 : -1
        let newY = min(max(clip.bounds.origin.y + delta * sign, document.isFlipped ? 0 : -maxY), document.isFlipped ? maxY : 0)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: newY))
        scroll.reflectScrolledClipView(clip)
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        initialEvent = nil
        TaskDragSession.shared.end()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
}


@MainActor
enum NativeTaskDrag {
    static func begin(id: UUID, title: String, view: NSView, source: NSDraggingSource, event: NSEvent) {
        guard view.window != nil else { return }
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        TaskDragSession.shared.begin(id, origin: (view as? TaskHandleView)?.dragOrigin ?? .taskList)
        let pasteboard = NSPasteboardItem()
        pasteboard.setData(TaskDragPayload.encode(id), forType: TaskDragPayload.pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        let titleWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        let size = NSSize(width: min(290, max(120, titleWidth + 42)), height: 38)
        let preview = NSImage(size: size, flipped: false) { rect in
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            shadow.shadowBlurRadius = 5
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.set()
            NSColor.windowBackgroundColor.withAlphaComponent(0.88).setFill()
            let card = rect.insetBy(dx: 6, dy: 6)
            NSBezierPath(roundedRect: card, xRadius: 7, yRadius: 7).fill()
            NSShadow().set()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let color = (view as? TaskHandleView)?.priorityColor ?? NativePalette.accent
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: card.minX + 9, y: card.midY - 3, width: 6, height: 6)).fill()
            (title as NSString).draw(in: NSRect(x: card.minX + 22, y: card.minY + 5, width: card.width - 28, height: 17), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
            ])
            return true
        }
        let point = view.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 18, y: point.y - size.height / 2, width: size.width, height: size.height), contents: preview)
        let session = view.beginDraggingSession(with: [item], event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }
}
