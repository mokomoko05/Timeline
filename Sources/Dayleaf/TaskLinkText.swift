import AppKit
import SwiftUI
import DayleafCore

struct TaskLinkText: NSViewRepresentable {
    let source: String
    let completed: Bool
    let color: Color
    let fontSize: CGFloat
    let edit: () -> Void
    let open: (URL) -> Void
    var maxLines = 3
    var displayName: String?
    var monospaced = false
    var dragTaskID: UUID?
    var markdown = false
    var compactLines = false
    var select: () -> Void = {}
    /// 单击正文（非链接）时调用。
    var click: (() -> Void)?
    /// 右键菜单里的操作（没有就用系统默认菜单）。
    var menuItems: [TextMenuItem] = []
    @Environment(\.isEnabled) private var enabled

    func makeNSView(context: Context) -> InteractiveTaskText {
        let view = InteractiveTaskText()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 5, height: 4)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.maximumNumberOfLines = maxLines
        view.measurer.update(NSAttributedString(), maxLines: maxLines)
        view.textContainer?.lineBreakMode = .byTruncatingTail
        view.textContainer?.widthTracksTextView = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor,
                                   .underlineStyle: NSUnderlineStyle.single.rawValue,
                                   .cursor: NSCursor.pointingHand]
        return view
    }

    func updateNSView(_ view: InteractiveTaskText, context: Context) {
        view.appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        view.onEdit = edit
        view.onOpen = open
        view.onSelect = select
        view.onClick = click
        view.menuItems = menuItems
        view.interactionEnabled = enabled
        view.dragTaskID = dragTaskID
        view.textContainerInset = NSSize(width: compactLines ? 2 : 5, height: compactLines ? 0 : 4)
        let foreground = NSColor(completed ? Palette.muted : color)
        if view.source != source || view.displayName != displayName || view.completed != completed || view.pointSize != fontSize || view.foreground != foreground || view.monospaced != monospaced || view.compactLines != compactLines || view.markdown != markdown {
            view.source = source
            view.displayName = displayName
            view.completed = completed
            view.pointSize = fontSize
            view.foreground = foreground
            view.monospaced = monospaced
            view.compactLines = compactLines
            view.markdown = markdown
            let styled = markdown ? MarkdownText.render(source, color: foreground, fontSize: fontSize, monospaced: monospaced) : Self.styledText(source, completed: completed, color: foreground, fontSize: fontSize, displayName: displayName, monospaced: monospaced, compactLines: compactLines)
            view.textStorage?.setAttributedString(styled)
            view.measurer.update(styled, maxLines: maxLines)
            view.invalidateIntrinsicContentSize()
            view.needsDisplay = true
            view.window?.invalidateCursorRects(for: view)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: InteractiveTaskText, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 240)
        // 用单独的排版栈测量，不碰视图自己的文本容器（SwiftUI 会用很多个宽度试探，缩放窗口时每帧都是新宽度；
        // 之前是改容器、排版、再还原重排，一次测量要排两遍中文）。同一个宽度的结果缓存起来。
        let textWidth = max(1, width - nsView.textContainerInset.width * 2)
        let height = nsView.measurer.height(forWidth: textWidth)
        return CGSize(width: width, height: max(UIScale.pt(fontSize) + 4, height) + nsView.textContainerInset.height * 2)
    }

    static func styledText(_ source: String, completed: Bool, color: NSColor, fontSize: CGFloat, displayName: String? = nil, monospaced: Bool = false, compactLines: Bool = false) -> NSAttributedString {
        let rendered = TaskText.rendered(source, alias: displayName)
        let text = NSMutableAttributedString(attributedString: NSAttributedString(rendered))
        let fullRange = NSRange(location: 0, length: text.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = compactLines ? 0 : 6
        let font = monospaced ? NSFont.monospacedSystemFont(ofSize: UIScale.pt(fontSize), weight: .regular) : NSFont.systemFont(ofSize: UIScale.pt(fontSize))
        text.addAttributes([.font: font, .foregroundColor: color, .paragraphStyle: paragraph], range: fullRange)
        if completed { text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: fullRange) }
        text.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            if value != nil {
                text.addAttributes([.foregroundColor: NSColor.linkColor,
                                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                                    .cursor: NSCursor.pointingHand], range: range)
            }
        }
        return text
    }
}

/// 测量文字高度用的独立排版栈，结果按宽度缓存；文字或样式变了就清掉。
final class TextMeasurer {
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer()
    private var cache: [Int: CGFloat] = [:]

    init() {
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byTruncatingTail
        container.widthTracksTextView = false
    }

    func update(_ text: NSAttributedString, maxLines: Int) {
        storage.setAttributedString(text)
        container.maximumNumberOfLines = maxLines
        cache.removeAll(keepingCapacity: true)
    }

    func height(forWidth rawWidth: CGFloat) -> CGFloat {
        // SwiftUI 会用无限宽试探「最理想的大小」。
        let width = rawWidth.isFinite ? min(rawWidth, 100_000) : 100_000
        let key = Int((width * 2).rounded())
        if let hit = cache[key] { return hit }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let height = ceil(manager.usedRect(for: container).height)
        if cache.count > 64 { cache.removeAll(keepingCapacity: true) }
        cache[key] = height
        return height
    }
}

/// 右键菜单里的一项（`separator` 为分隔线）。
struct TextMenuItem {
    var title = ""
    var symbol: String?
    var destructive = false
    var separator = false
    var action: () -> Void = {}

    static let divider = TextMenuItem(separator: true)
}

/// NSMenuItem 的动作转发。
private final class MenuActionTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

extension NSMenu {
    /// 按 `TextMenuItem` 列表造一个菜单；动作对象挂在菜单项上，菜单存活期间不会被释放。
    static func make(_ items: [TextMenuItem]) -> NSMenu {
        let menu = NSMenu()
        for item in items {
            if item.separator { menu.addItem(.separator()); continue }
            let target = MenuActionTarget(item.action)
            let entry = NSMenuItem(title: item.title, action: #selector(MenuActionTarget.fire), keyEquivalent: "")
            entry.target = target
            entry.representedObject = target
            if let symbol = item.symbol { entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(entry)
        }
        return menu
    }
}

final class InteractiveTaskText: NSTextView {
    var markdown = false
    let measurer = TextMeasurer()
    var menuItems: [TextMenuItem] = []
    var source: String?
    var displayName: String?
    var completed = false
    var pointSize: CGFloat = 0
    var foreground: NSColor?
    var monospaced = false
    var interactionEnabled = true
    var dragTaskID: UUID?
    var compactLines = false
    private var mouseDownEvent: NSEvent?
    private var dragged = false
    var onEdit: (() -> Void)?
    var onOpen: ((URL) -> Void)?
    var onSelect: (() -> Void)?
    var onClick: (() -> Void)?
    private var hoveredURL: URL?
    private var tracking: NSTrackingArea?

    /// 有自定义操作时，右键菜单用它们；选中了文字就在最前面加「拷贝所选文字」。
    override func menu(for event: NSEvent) -> NSMenu? {
        guard !menuItems.isEmpty else { return markdown ? super.menu(for: event) : nil }
        var items = menuItems
        if selectedRange().length > 0 {
            items.insert(TextMenuItem(title: "拷贝所选文字", symbol: "text.cursor", action: { [weak self] in self?.copy(nil) }), at: 0)
            items.insert(.divider, at: 1)
        }
        return NSMenu.make(items)
    }

    /// 文本容器宽度始终跟随视图实际宽度。
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let width = max(1, newSize.width - textContainerInset.width * 2)
        if let container = textContainer, abs(container.containerSize.width - width) > 0.5 {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
    }

    func linkRegions() -> [(url: URL, rect: NSRect)] {
        guard let storage = textStorage, let manager = layoutManager, let container = textContainer else { return [] }
        manager.ensureLayout(for: container)
        var regions: [(url: URL, rect: NSRect)] = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) else { return }
            let linkedGlyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            manager.enumerateLineFragments(forGlyphRange: linkedGlyphs) { _, _, _, lineGlyphs, _ in
                var visible = NSIntersectionRange(linkedGlyphs, lineGlyphs)
                guard visible.length > 0 else { return }
                let truncated = manager.truncatedGlyphRange(inLineFragmentForGlyphAt: visible.location)
                if truncated.location != NSNotFound, truncated.location < NSMaxRange(visible) {
                    visible.length = max(0, truncated.location - visible.location)
                }
                guard visible.length > 0 else { return }
                let glyphRect = manager.boundingRect(forGlyphRange: visible, in: container)
                let rect = glyphRect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
                    .insetBy(dx: -3, dy: -2).intersection(self.bounds)
                if !rect.isEmpty { regions.append((url, rect)) }
            }
        }
        return regions
    }

    func link(at point: NSPoint) -> URL? {
        linkRegions().first { $0.rect.contains(point) }?.url
    }

    override func draw(_ dirtyRect: NSRect) {
        for region in linkRegions() where region.rect.intersects(dirtyRect) {
            NSColor.controlAccentColor.withAlphaComponent(hoveredURL == region.url ? 0.18 : 0.09).setFill()
            let path = NSBezierPath(roundedRect: region.rect, xRadius: 5, yRadius: 5)
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.18).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
        super.draw(dirtyRect)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard interactionEnabled else { return }
        if dragTaskID != nil { addCursorRect(bounds, cursor: .openHand) }
        for region in linkRegions() { addCursorRect(region.rect, cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredURL = interactionEnabled ? link(at: convert(event.locationInWindow, from: nil)) : nil
        if interactionEnabled, dragTaskID != nil {
            (TaskDragSession.shared.activeID != nil ? NSCursor.closedHand : (hoveredURL == nil ? NSCursor.openHand : NSCursor.pointingHand)).set()
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredURL = nil
        needsDisplay = true
    }

    func activate(at point: NSPoint, clickCount: Int = 1) {
        guard interactionEnabled else { return }
        onSelect?()
        if clickCount == 1, let url = link(at: point) {
            onOpen?(url)
        } else if clickCount == 1 {
            onClick?()
        } else if clickCount == 2 {
            onEdit?()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if markdown {
            let point = convert(event.locationInWindow, from: nil)
            if event.clickCount == 2 || link(at: point) != nil { activate(at: point, clickCount: event.clickCount); return }
            onSelect?()
            onClick?()
            super.mouseDown(with: event)
            return
        }
        mouseDownEvent = event
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard interactionEnabled, !dragged, let initial = mouseDownEvent,
              hypot(event.locationInWindow.x - initial.locationInWindow.x,
                    event.locationInWindow.y - initial.locationInWindow.y) > 4 else { return }
        dragged = true
        guard let id = dragTaskID, window != nil else { return }
        onSelect?()
        NativeTaskDrag.begin(id: id, title: string, view: self, source: self, event: initial)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard mouseDownEvent != nil, !dragged else { return }
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { activate(at: point, clickCount: event.clickCount) }
    }

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    override func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        NSCursor.closedHand.set()
    }

    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        mouseDownEvent = nil
        TaskDragSession.shared.end()
        window?.invalidateCursorRects(for: self)
    }

}
