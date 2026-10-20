import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TimelineCore

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

@MainActor
final class TaskDragSession: ObservableObject {
    static let shared = TaskDragSession()
    static var animation: Animation? { Motion.reduced ? nil : .interactiveSpring(response: 0.22, dampingFraction: 0.92) }
    @Published private(set) var activeID: UUID?
    @Published var timelineTarget: String?
    private var lastDateTarget: String?

    func focusDate(_ date: Date?) {
        guard activeID != nil else { return }
        let key = date.map(JournalDates.key) ?? "undated"
        guard key != lastDateTarget else { return }
        lastDateTarget = key
        if !Headless.active {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func begin(_ id: UUID) {
        lastDateTarget = nil
        withAnimation(.easeOut(duration: 0.14)) { activeID = id }
        NSCursor.closedHand.set()
    }

    func end() {
        lastDateTarget = nil
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { activeID = nil; timelineTarget = nil }
        NSCursor.arrow.set()
    }
}

@MainActor
enum TaskDragDrop {
    static func receive(_ providers: [NSItemProvider], store: JournalStore, destination: Date?,
                        anchorID: UUID? = nil, after: Bool = false, reorder: Bool = false) -> Bool {
        guard !store.isReadOnly,
              let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(TaskDragPayload.type.identifier) }) else { return false }
        if let id = TaskDragSession.shared.activeID {
            move(id, store: store, destination: destination, anchorID: anchorID, after: after, reorder: reorder)
            TaskDragSession.shared.end()
            return true
        }
        _ = provider.loadDataRepresentation(forTypeIdentifier: TaskDragPayload.type.identifier) { data, error in
            guard error == nil, let data, let id = TaskDragPayload.decode(data) else { return }
            Task { @MainActor in move(id, store: store, destination: destination, anchorID: anchorID, after: after, reorder: reorder) }
        }
        return true
    }

    /// 拖到日历的某一天，就是把那天设为任务的截止日期（保留原来的时分）。清单按截止时间排序，不再手动排序。
    static func move(_ id: UUID, store: JournalStore, destination: Date?,
                     anchorID: UUID? = nil, after: Bool = false, reorder: Bool = false) {
        guard !store.isReadOnly, !reorder, let task = store.locate(id) else { return }
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        if let due = task.task.dueDate, let destination, JournalDates.calendar.isDate(due, inSameDayAs: destination) { return }
        if task.task.dueDate == nil && destination == nil { return }
        withAnimation(TaskDragSession.animation) {
            store.setDeadline(id, to: destination)
        }
    }
}

struct TaskDragSource: ViewModifier {
    let task: Todo
    let enabled: Bool
    var edgeDragging = true
    var placementPreview = false
    var select: () -> Void = {}
    @ObservedObject private var session = TaskDragSession.shared

    func body(content: Content) -> some View {
        content.opacity(!placementPreview && session.activeID == task.id ? 0.25 : 1)
            .animation(Motion.quick, value: session.activeID)
            .overlay {
                if edgeDragging {
                    NativeTaskHandle(task: task, enabled: enabled, drawsHandle: false, edgeOnly: true, select: select)
                }
            }
    }
}

struct TaskDragHandle: View {
    let task: Todo
    let enabled: Bool
    var select: () -> Void = {}
    /// 在清单里时，上下拖动是排序；没有（比如搜索面板）就只能拖到日历上。
    var reorder: TaskReorderHooks?

    var body: some View {
        NativeTaskHandle(task: task, enabled: enabled, select: select, reorder: reorder)
            .frame(width: 30, height: 30)
            .help(reorder == nil ? "拖到日历上更改截止日期" : "拖动排序或更改截止日期")
            .accessibilityLabel("拖动任务排序或更改日期")
    }
}

struct NativeTaskHandle: NSViewRepresentable {
    let task: Todo
    let enabled: Bool
    var drawsHandle = true
    var edgeOnly = false
    var select: () -> Void = {}
    var reorder: TaskReorderHooks?
    var priorityItems: [RadialItem]?
    var priorityColor: NSColor?
    var prepareTask: (() -> Todo?)?

    func makeNSView(context: Context) -> TaskHandleView { TaskHandleView() }
    func updateNSView(_ view: TaskHandleView, context: Context) {
        view.priorityItems = priorityItems
        if prepareTask == nil || view.taskID == nil { view.priorityColor = priorityColor }
        view.restingPriorityColor = priorityColor
        view.reorder = reorder
        if prepareTask == nil { view.taskID = enabled ? task.id : nil }
        view.prepareTask = prepareTask
        view.draftEnabled = enabled
        view.drawsHandle = drawsHandle
        view.edgeOnly = edgeOnly
        view.onSelect = select
        // 标题只在开始拖动时才用到：解析 Markdown 和链接检测不便宜，缩放窗口时每帧都会走到这里，所以只存原文。
        if prepareTask == nil || view.taskID == nil { view.titleSource = (task.title, task.calendarName) }
        view.appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

final class TaskHandleView: NSView, NSDraggingSource {
    var taskID: UUID?
    var titleSource: (title: String, alias: String) = ("", "")
    /// 拖到日历时显示的标题。
    var title: String { String(TaskText.rendered(titleSource.title, alias: titleSource.alias).characters) }
    var drawsHandle = true
    var edgeOnly = false
    var onSelect: (() -> Void)?
    /// 输入框圆点在按下时提交草稿；创建后继续使用同一原生视图拖动。
    var prepareTask: (() -> Todo?)?
    var draftEnabled = false
    var isPressed: Bool { initialEvent != nil }
    private var available: Bool { taskID != nil || (prepareTask != nil && draftEnabled) }
    var reorder: TaskReorderHooks?
    /// 开始「拖到日历」的系统拖拽（会一直占着事件循环到松手）；测试里替换掉。
    var startNativeDrag: (UUID, String, TaskHandleView, NSEvent) -> Void = { id, title, view, event in
        NativeTaskDrag.begin(id: id, title: title, view: view, source: view, event: event)
    }
    var priorityItems: [RadialItem]?
    var priorityColor: NSColor?
    var restingPriorityColor: NSColor?
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
        if edgeOnly {
            addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: 6), cursor: .openHand)
            addCursorRect(NSRect(x: 0, y: bounds.height - 6, width: bounds.width, height: 6), cursor: .openHand)
            addCursorRect(NSRect(x: 0, y: 0, width: 6, height: bounds.height), cursor: .openHand)
            addCursorRect(NSRect(x: bounds.width - 6, y: 0, width: 6, height: bounds.height), cursor: .openHand)
        } else { addCursorRect(bounds, cursor: .openHand) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard available else { return nil }
        let local = convert(point, from: superview)
        if edgeOnly, bounds.insetBy(dx: 6, dy: 6).contains(local) { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard available else { return }
        if event.modifierFlags.contains(.control), priorityItems != nil {
            rightMouseDown(with: event)
            return
        }
        PriorityPaletteController.shared.dismiss()
        if let prepareTask {
            guard draftEnabled, let task = prepareTask() else { return }
            taskID = task.id
            titleSource = (task.title, task.calendarName)
        }
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
        if prepareTask != nil { taskID = nil; priorityColor = restingPriorityColor }
        needsDisplay = true
        if reordering { endReorder(commit: true) }
        else { NSCursor.arrow.set(); window?.invalidateCursorRects(for: self) }
    }

    override func mouseDragged(with event: NSEvent) {
        if reordering {
            NSCursor.closedHand.set()
            // 向右（或向左）拖出了清单：改成拖到日历上设置截止日期。
            let translation = -(event.locationInWindow.y - startY) + (scrollOffset() - startScroll)
            if (leftList(event.locationInWindow) || reorder?.leavesGroup(translation) == true), let id = taskID {
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
        // 清单里的把手：先按排序拖动；清单外或没有清单（搜索面板）走原来的拖到日历。
        if !edgeOnly, let reorder, reorder.begin() {
            startReorder(from: initial)
            track(event.locationInWindow)
            return
        }
        initialEvent = nil
        startNativeDrag(id, title, self, initial)
    }

    // MARK: - 清单内排序

    private var reordering = false
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

    private func leftList(_ point: NSPoint) -> Bool {
        guard let scroll = scrollView else { return false }
        let frame = scroll.convert(scroll.bounds, to: nil)
        // 必须明显拖出清单才切换为系统拖拽，避免左右晃动打断排序。
        return point.x < frame.minX - 70 || point.x > frame.maxX + 70
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

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) { NSCursor.closedHand.set() }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        TaskDragSession.shared.end()
        if prepareTask != nil { taskID = nil; priorityColor = restingPriorityColor }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
}

@MainActor
enum NativeTaskDrag {
    static func begin(id: UUID, title: String, view: NSView, source: NSDraggingSource, event: NSEvent) {
        guard view.window != nil else { return }
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        TaskDragSession.shared.begin(id)
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
            let color = (view as? TaskHandleView)?.priorityColor ?? NSColor.controlAccentColor
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

struct TaskDropTarget: DropDelegate {
    let store: JournalStore
    let destination: Date
    var anchorID: UUID?
    var height: CGFloat = 0
    var reorder = false
    @Binding var targeted: Bool
    @Binding var after: Bool

    func validateDrop(info: DropInfo) -> Bool {
        !store.isReadOnly && info.hasItemsConforming(to: [TaskDragPayload.type])
    }

    func dropEntered(info: DropInfo) {
        targeted = validateDrop(info: info) && (anchorID == nil || anchorID != TaskDragSession.shared.activeID)
    }
    func dropExited(info: DropInfo) { targeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        after = anchorID != nil && info.location.y > height / 2
        return DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard validateDrop(info: info) else { return false }
        let below = anchorID != nil && info.location.y > height / 2
        return TaskDragDrop.receive(info.itemProviders(for: [TaskDragPayload.type]), store: store,
                                    destination: destination, anchorID: anchorID, after: below, reorder: reorder)
    }
}

struct TaskReorderTarget: ViewModifier {
    let store: JournalStore
    let date: Date
    var anchorID: UUID?
    @ObservedObject private var session = TaskDragSession.shared
    @State private var targeted = false
    @State private var after = false
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geometry in
                Color.clear.onAppear { height = geometry.size.height }
                    .onChange(of: geometry.size.height) { height = $0 }
            })
            .overlay(alignment: after || anchorID == nil ? .bottom : .top) {
                if targeted, session.activeID != nil {
                    Capsule().fill(Palette.accent).frame(height: 2).allowsHitTesting(false)
                }
            }
            .onDrop(of: [TaskDragPayload.type], delegate: TaskDropTarget(store: store, destination: date,
                     anchorID: anchorID, height: height, reorder: true, targeted: $targeted, after: $after))
            .onChange(of: session.activeID) { if $0 == nil { targeted = false } }
    }
}


struct TimelineDateDropTarget: DropDelegate {
    let store: JournalStore
    let date: Date?
    @Binding var targeted: Bool
    var didDrop: () -> Void = {}

    func validateDrop(info: DropInfo) -> Bool {
        !store.isReadOnly && info.hasItemsConforming(to: [TaskDragPayload.type])
    }
    func dropEntered(info: DropInfo) {
        targeted = validateDrop(info: info)
        if targeted { TaskDragSession.shared.focusDate(date) }
    }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let accepted = validateDrop(info: info)
        if accepted && !targeted {
            targeted = true
            TaskDragSession.shared.focusDate(date)
        }
        return DropProposal(operation: accepted ? .move : .forbidden)
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard validateDrop(info: info) else { return false }
        let accepted = TaskDragDrop.receive(info.itemProviders(for: [TaskDragPayload.type]), store: store, destination: date)
        if accepted { didDrop() }
        return accepted
    }
}
