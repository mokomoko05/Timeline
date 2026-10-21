import AppKit
import SwiftUI
import QuartzCore

struct BoardFavorite: Equatable, Identifiable {
    let id: UUID
    let title: String
}

struct BoardFavoritesBar: NSViewRepresentable {
    @Environment(\.typography) private var typography
    let boards: [BoardFavorite]
    let selection: UUID?
    let select: (UUID) -> Void
    let move: (UUID, Int) -> Void
    let remove: (UUID) -> Void

    func makeNSView(context: Context) -> BoardFavoritesScrollView { BoardFavoritesScrollView() }

    func updateNSView(_ view: BoardFavoritesScrollView, context: Context) {
        view.appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        view.onSelect = select
        view.onMove = move
        view.onRemove = remove
        view.configure(boards: boards, selection: selection, fontSize: typography.pt(11))
    }
}

private final class BoardFavoritesDocument: NSView {
    override var isFlipped: Bool { true }
}

final class BoardFavoritesScrollView: NSScrollView {
    private let document = BoardFavoritesDocument()
    private(set) var buttons: [UUID: BoardFavoriteButton] = [:]
    private(set) var boards: [BoardFavorite] = []
    private(set) var previewOrder: [UUID] = []
    private(set) var draggedID: UUID?
    var onSelect: (UUID) -> Void = { _ in }
    var onMove: (UUID, Int) -> Void = { _, _ in }
    var onRemove: (UUID) -> Void = { _ in }
    private var originalFrames: [NSRect] = []
    private var startPoint: NSPoint = .zero
    private var dragOrigin: CGFloat = 0
    private var targetIndex = 0
    private var autoscroll: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        documentView = document
        setAccessibilityLabel(AppLocalized("常用工作板"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(boards updated: [BoardFavorite], selection: UUID?, fontSize: CGFloat) {
        if boards.map(\.id) != updated.map(\.id) { cancelDrag() }
        let ids = Set(updated.map(\.id))
        for id in Array(buttons.keys) where !ids.contains(id) {
            buttons.removeValue(forKey: id)?.removeFromSuperview()
        }
        boards = updated
        if draggedID == nil { previewOrder = updated.map(\.id) }
        for board in updated {
            let button = buttons[board.id] ?? BoardFavoriteButton(id: board.id)
            if buttons[board.id] == nil {
                buttons[board.id] = button
                document.addSubview(button)
            }
            button.bar = self
            button.title = board.title
            button.font = .systemFont(ofSize: fontSize, weight: selection == board.id ? .semibold : .regular)
            button.selected = selection == board.id
            button.toolTip = board.title + " · " + AppLocalized("拖动调整顺序")
            button.setAccessibilityLabel(board.title)
            button.setAccessibilityValue(button.selected ? 1 : 0)
            button.needsDisplay = true
        }
        layoutButtons(animated: false)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        if draggedID != nil { cancelDrag() }
        layoutButtons(animated: false)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelDrag() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func layoutButtons(animated: Bool) {
        var origin: CGFloat = 14
        let height: CGFloat = 30
        let top = max(0, (contentSize.height - height) / 2)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.16 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for id in previewOrder {
                guard let button = buttons[id] else { continue }
                let font = button.font ?? .systemFont(ofSize: 11)
                let width = min(160, max(48, (button.title as NSString).size(withAttributes: [.font: font]).width + 20))
                let frame = NSRect(x: id == draggedID ? dragOrigin : origin, y: top, width: width, height: height)
                if animated && id != draggedID { button.animator().frame = frame }
                else { button.frame = frame }
                origin += width + 6
            }
        }
        document.setFrameSize(NSSize(width: max(contentSize.width, origin + 8), height: contentSize.height))
    }

    func beginDrag(_ id: UUID, at point: NSPoint) {
        guard draggedID == nil, boards.count > 1, let button = buttons[id],
              let index = boards.firstIndex(where: { $0.id == id }) else { return }
        originalFrames = boards.compactMap { buttons[$0.id]?.frame }
        guard originalFrames.count == boards.count else { return }
        startPoint = document.convert(point, from: nil)
        dragOrigin = button.frame.minX
        targetIndex = index
        draggedID = id
        button.dragging = true
        document.addSubview(button, positioned: .above, relativeTo: nil)
        NSCursor.closedHand.set()
        autoscroll = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscrollTick() }
        }
    }

    func updateDrag(at point: NSPoint) {
        guard let id = draggedID, let active = boards.firstIndex(where: { $0.id == id }),
              let first = originalFrames.first, let last = originalFrames.last else { return }
        let translation = document.convert(point, from: nil).x - startPoint.x
        let original = originalFrames[active]
        dragOrigin = min(max(original.minX + translation, first.minX), last.maxX - original.width)
        let moved = original.offsetBy(dx: dragOrigin - original.minX, dy: 0)
        let destination: Int
        if translation < 0 {
            destination = active - originalFrames[..<active].filter { $0.midX > moved.minX }.count
        } else {
            destination = active + originalFrames[(active + 1)...].filter { $0.midX < moved.maxX }.count
        }
        let changed = destination != targetIndex
        targetIndex = destination
        previewOrder = ReorderMath.moved(boards.map(\.id), from: active, to: destination)
        if changed { layoutButtons(animated: true) }
        else { buttons[id]?.setFrameOrigin(NSPoint(x: dragOrigin, y: original.minY)) }
    }

    func endDrag() {
        guard let id = draggedID else { return }
        let source = boards.firstIndex { $0.id == id }
        let destination = targetIndex
        boards = previewOrder.compactMap { boardID in boards.first { $0.id == boardID } }
        clearDrag()
        layoutButtons(animated: true)
        if source != destination { onMove(id, destination) }
    }

    func cancelDrag() {
        guard draggedID != nil else { return }
        previewOrder = boards.map(\.id)
        clearDrag()
        layoutButtons(animated: true)
    }

    private func clearDrag() {
        autoscroll?.invalidate()
        autoscroll = nil
        if let id = draggedID { buttons[id]?.dragging = false }
        draggedID = nil
        NSCursor.arrow.set()
        window?.invalidateCursorRects(for: self)
    }

    private func autoscrollTick() {
        guard draggedID != nil, let window else { return }
        guard window.isVisible else { cancelDrag(); return }
        let point = window.mouseLocationOutsideOfEventStream
        let local = contentView.convert(point, from: nil)
        let visible = contentView.bounds
        let zone: CGFloat = 28
        var delta: CGFloat = 0
        if local.x < visible.minX + zone { delta = -min(10, (visible.minX + zone - local.x) / 3) }
        else if local.x > visible.maxX - zone { delta = min(10, (local.x - visible.maxX + zone) / 3) }
        if delta != 0 {
            let offset = min(max(visible.minX + delta, 0), max(0, document.bounds.width - visible.width))
            contentView.scroll(to: NSPoint(x: offset, y: visible.minY))
            reflectScrolledClipView(contentView)
        }
        updateDrag(at: point)
    }

    func contextMenu(for id: UUID) -> NSMenu? {
        guard let index = boards.firstIndex(where: { $0.id == id }) else { return nil }
        let menu = NSMenu.make([
            TextMenuItem(title: AppLocalized("向左移"), action: { [weak self] in self?.onMove(id, index - 1) }),
            TextMenuItem(title: AppLocalized("向右移"), action: { [weak self] in self?.onMove(id, index + 1) }),
            .divider,
            TextMenuItem(title: AppLocalized("取消常用固定"), action: { [weak self] in self?.onRemove(id) })
        ])
        menu.autoenablesItems = false
        menu.items[0].isEnabled = index > 0
        menu.items[1].isEnabled = index < boards.count - 1
        return menu
    }
}

final class BoardFavoriteButton: NSButton {
    let boardID: UUID
    weak var bar: BoardFavoritesScrollView?
    var selected = false
    var dragging = false {
        didSet {
            layer?.shadowOpacity = dragging ? 0.3 : 0
            needsDisplay = true
        }
    }
    private var initialPoint: NSPoint?
    private var moved = false

    init(id: UUID) {
        boardID = id
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.shadowRadius = 4
        layer?.shadowOffset = NSSize(width: 0, height: -1)
        target = self
        action = #selector(selectBoard)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        NSColor(selected || dragging ? Palette.soft : Palette.card).setFill()
        shape.fill()
        if dragging {
            NSColor(Palette.accent).setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .center
        let labelFont = font ?? .systemFont(ofSize: 11)
        let textHeight = labelFont.ascender - labelFont.descender
        (title as NSString).draw(in: NSRect(x: 10, y: (bounds.height - textHeight) / 2 - 1,
                                          width: max(0, bounds.width - 20), height: textHeight + 2),
                                withAttributes: [.font: labelFont, .foregroundColor: NSColor(selected || dragging ? Palette.accent : Palette.muted),
                                                 .paragraphStyle: paragraph])
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: dragging ? .closedHand : .openHand) }

    override func mouseDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control) else { super.mouseDown(with: event); return }
        initialPoint = event.locationInWindow
        moved = false
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let initialPoint else { return }
        if !moved {
            guard hypot(event.locationInWindow.x - initialPoint.x, event.locationInWindow.y - initialPoint.y) > 4 else { return }
            moved = true
            bar?.beginDrag(boardID, at: initialPoint)
        }
        bar?.updateDrag(at: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        guard initialPoint != nil else { return }
        if moved { bar?.endDrag() }
        else if bounds.contains(convert(event.locationInWindow, from: nil)) { bar?.onSelect(boardID) }
        initialPoint = nil
        moved = false
    }

    override func cancelOperation(_ sender: Any?) {
        bar?.cancelDrag()
        initialPoint = nil
        moved = false
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) }
        else { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { bar?.contextMenu(for: boardID) }

    override func accessibilityPerformPress() -> Bool {
        selectBoard()
        return true
    }

    @objc private func selectBoard() { bar?.onSelect(boardID) }
}
