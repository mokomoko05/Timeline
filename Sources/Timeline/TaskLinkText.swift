import AppKit
import SwiftUI
import TimelineCore
import Markdown

struct TaskLinkText: NSViewRepresentable {
    @Environment(\.typography) private var typography
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
    var toggleMarkdownTask: ((Int) -> Void)?
    var compactLines = false
    var select: () -> Void = {}
    /// 单击正文（非链接）时调用。
    var click: (() -> Void)?
    /// 单击正文（没有拖选文字、不是链接 / 待办 / 折叠按钮）就地开始编辑，参数是点的位置（相对正文左上角）。
    var editAt: ((CGPoint) -> Void)?
    /// 右键菜单里的操作（没有就用系统默认菜单）。
    var menuItems: [TextMenuItem] = []
    /// Markdown 标题可以折叠（点标题收起 / 展开），折叠状态按这个标识记住（比如某条笔记）。
    var foldID: String?
    /// 工作板正文的一段：按工作板的折叠记忆画标题的收起 / 展开，点标题时调用 `toggleHeading`。
    var boardFolds: MarkdownText.BoardFoldMarks?
    var toggleHeading: ((String) -> Void)?
    @Environment(\.isEnabled) private var enabled
    @State private var foldRevision = 0

    func makeNSView(context: Context) -> InteractiveTaskText {
        let view = InteractiveTaskText()
        // 有图层、只在内容变了才重画：拖动排序时行只是平移，由图层合成，不再每帧重新排版、绘制文字。
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 5, height: 4)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.maximumNumberOfLines = maxLines
        view.textContainer?.lineBreakMode = .byTruncatingTail
        view.textContainer?.widthTracksTextView = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.linkTextAttributes = [.foregroundColor: NativePalette.accent,
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
        view.onEditAt = editAt
        view.onToggleMarkdownTask = toggleMarkdownTask
        view.menuItems = menuItems
        view.interactionEnabled = enabled
        let folds = markdown ? foldID.map { _ = foldRevision; return HeadingFolds.folded(in: $0) } : nil
        view.onToggleHeading = markdown ? toggleHeading ?? foldID.map { id in { key in
            HeadingFolds.toggle(key, in: id)
            foldRevision += 1
        } } : nil
        view.dragTaskID = dragTaskID
        view.textContainerInset = NSSize(width: compactLines ? 2 : 5, height: compactLines ? 0 : 4)
        let foreground = NSColor(completed ? Palette.muted : color)
        if view.source != source || view.displayName != displayName || view.completed != completed || view.pointSize != fontSize || view.foreground != foreground || view.monospaced != monospaced || view.compactLines != compactLines || view.markdown != markdown || view.interactiveTasks != (toggleMarkdownTask != nil) || view.uiScaleFactor != typography.scale || view.configuredLineSpacing != Double(typography.lineSpacing) || view.foldedHeadings != folds || view.boardFolds != boardFolds {
            let sourceChanged = view.source != source || view.displayName != displayName || view.markdown != markdown
            let selection = view.selectedRanges
            if sourceChanged {
                // 解析留到真要排版时（缓存里没有）再做：滚回来的行直接用缓存，不再解析。
                view.markdownDocument = nil
                view.inlineText = nil
            }
            view.source = source
            view.displayName = displayName
            view.completed = completed
            view.pointSize = fontSize
            view.foreground = foreground
            view.monospaced = monospaced
            view.compactLines = compactLines
            view.markdown = markdown
            view.interactiveTasks = toggleMarkdownTask != nil
            view.uiScaleFactor = typography.scale
            view.configuredLineSpacing = Double(typography.lineSpacing)
            view.foldedHeadings = folds
            view.boardFolds = boardFolds
            // 同样的正文和样式排出来的结果全局缓存：懒加载的列表滚回来时重新建行，不用再解析、排版、量高度。
            let key = boardFolds == nil ? TextRenderCache.Key(source: source, displayName: displayName, markdown: markdown, completed: completed, foreground: foreground,
                fontSize: fontSize, monospaced: monospaced, compactLines: compactLines, interactiveTasks: view.interactiveTasks, scale: typography.scale,
                lineSpacing: typography.lineSpacing, folds: folds, maxLines: maxLines) : nil
            let entry: TextRenderCache.Entry
            if let key, let hit = TextRenderCache.shared.entry(for: key) {
                entry = hit
            } else {
                if markdown, view.markdownDocument == nil { view.markdownDocument = MarkdownText.parse(source) }
                if !markdown, view.inlineText == nil { view.inlineText = NSAttributedString(TaskText.rendered(source, alias: displayName)) }
                let styled = markdown
                    ? MarkdownText.render(source, color: foreground, fontSize: fontSize, monospaced: monospaced, lineSpacing: typography.lineSpacing, scale: typography.scale, document: view.markdownDocument, interactiveTasks: view.interactiveTasks, folds: folds, boardFolds: boardFolds)
                    : Self.styledText(source, completed: completed, color: foreground, fontSize: fontSize, displayName: displayName, monospaced: monospaced, compactLines: compactLines, lineSpacing: compactLines ? 0 : typography.lineSpacing, scale: typography.scale, rendered: view.inlineText)
                entry = TextRenderCache.Entry(styled)
                if let key { TextRenderCache.shared.store(entry, for: key) }
            }
            view.textStorage?.setAttributedString(entry.styled)
            if !sourceChanged { view.selectedRanges = selection }
            view.rendered = entry
            view.measuredText = nil
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
        let height = nsView.measuredHeight(forWidth: textWidth, maxLines: maxLines)
        return CGSize(width: width, height: max(typography.pt(fontSize) + 4, height) + nsView.textContainerInset.height * 2)
    }

    static func styledText(_ source: String, completed: Bool, color: NSColor, fontSize: CGFloat, displayName: String? = nil, monospaced: Bool = false, compactLines: Bool = false, lineSpacing: CGFloat = UIScale.lineSpacing, scale: CGFloat = UIScale.factor, rendered: NSAttributedString? = nil) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: rendered ?? NSAttributedString(TaskText.rendered(source, alias: displayName)))
        let fullRange = NSRange(location: 0, length: text.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = compactLines ? 0 : lineSpacing
        let font = monospaced ? NSFont.monospacedSystemFont(ofSize: fontSize * scale, weight: .regular) : NSFont.systemFont(ofSize: fontSize * scale)
        text.addAttributes([.font: font, .foregroundColor: color, .paragraphStyle: paragraph], range: fullRange)
        if completed { text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: fullRange) }
        text.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            if value != nil {
                text.addAttributes([.foregroundColor: NativePalette.accent,
                                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                                    .cursor: NSCursor.pointingHand], range: range)
            }
        }
        return text
    }
}

/// 排好版的正文，按正文和样式缓存（最多几百份，按开销自动淘汰）。日记、笔记里很长的条目滚出去再滚回来，
/// 懒加载列表会重新建行；有缓存时不用再解析 Markdown、排版和量高度，滚动不掉帧，估算的行高也更快对上。
@MainActor
final class TextRenderCache {
    static let shared = TextRenderCache()

    struct Key: Hashable {
        let source: String
        let displayName: String?
        let markdown: Bool
        let completed: Bool
        let foreground: NSColor
        let fontSize: CGFloat
        let monospaced: Bool
        let compactLines: Bool
        let interactiveTasks: Bool
        let scale: CGFloat
        let lineSpacing: CGFloat
        let folds: Set<String>?
        let maxLines: Int
    }

    final class Entry {
        let styled: NSAttributedString
        /// 宽度（半点为单位）→ 高度。
        var heights: [Int: CGFloat] = [:]
        init(_ styled: NSAttributedString) { self.styled = styled.copy() as? NSAttributedString ?? styled }
    }

    private final class Box: NSObject {
        let key: Key
        init(_ key: Key) { self.key = key }
        override var hash: Int { key.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? Box)?.key == key }
    }

    private let cache: NSCache<Box, Entry> = {
        let cache = NSCache<Box, Entry>()
        cache.countLimit = 600
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    func entry(for key: Key) -> Entry? { cache.object(forKey: Box(key)) }

    func store(_ entry: Entry, for key: Key) {
        cache.setObject(entry, forKey: Box(key), cost: entry.styled.length * 16 + key.source.utf16.count * 2)
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
        // 输入框会按词／字符换行；截断模式会在接近行尾时算出不同的行数，
        // 导致 SwiftUI 高度在编辑器实际排版前后抖动一帧。
        container.lineBreakMode = .byWordWrapping
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
            let entry = NSMenuItem(title: AppLocalized(item.title), action: #selector(MenuActionTarget.fire), keyEquivalent: "")
            entry.target = target
            entry.representedObject = target
            if let symbol = item.symbol { entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(entry)
        }
        return menu
    }
}

final class InteractiveTaskText: NSTextView {
    // NSTextView 的继承初始化入口可能重入 Swift 的存储属性初始化，
    // 重复分配并遗失 measurer；直接实现指定初始化方法，保证只分配一次。
    override init(frame frameRect: NSRect = .zero, textContainer container: NSTextContainer? = nil) {
        // 指定初始化方法收到 nil 时不会像便捷初始化方法一样创建排版栈。
        // 必须提供完整的 TextKit 栈，否则 textStorage 为 nil，正文无法写入或绘制。
        let textContainer: NSTextContainer
        let ownedStorage: NSTextStorage?
        if let container {
            textContainer = container
            ownedStorage = nil
        } else {
            let storage = NSTextStorage()
            ownedStorage = storage
            let manager = NSLayoutManager()
            textContainer = NSTextContainer(containerSize: NSSize(width: max(1, frameRect.width), height: .greatestFiniteMagnitude))
            storage.addLayoutManager(manager)
            manager.addTextContainer(textContainer)
        }
        super.init(frame: frameRect, textContainer: textContainer)
        // NSLayoutManager 不持有 storage；交给 NSTextView 接管前不能提前释放。
        withExtendedLifetime(ownedStorage) {}
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    private struct RegionLayoutKey: Equatable {
        let storage: ObjectIdentifier
        let manager: ObjectIdentifier
        let container: ObjectIdentifier
        let bounds: NSRect
        let origin: NSPoint
        let containerSize: NSSize
        let padding: CGFloat
        let maxLines: Int
        let lineBreakMode: NSLineBreakMode
    }

    private var cachedLinks: (key: RegionLayoutKey, regions: [(url: URL, rect: NSRect)])?
    private var cachedTasks: (key: RegionLayoutKey, regions: [(line: Int, rect: NSRect)])?
    private var cachedCode: (key: RegionLayoutKey, regions: [(info: MarkdownText.CodeBlockInfo, block: NSRect, copy: NSRect)])?
    private var cachedHeadings: (key: RegionLayoutKey, regions: [(key: String, rect: NSRect, folded: Bool)])?
    private weak var observedRegionStorage: NSTextStorage?
    private var regionObservation: NSObjectProtocol?

    deinit {
        if let regionObservation { NotificationCenter.default.removeObserver(regionObservation) }
    }

    private func invalidateRegionCache() {
        cachedLinks = nil
        cachedTasks = nil
        cachedCode = nil
        cachedHeadings = nil
    }

    private func regionLayoutKey(storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer) -> RegionLayoutKey {
        if observedRegionStorage !== storage {
            if let regionObservation { NotificationCenter.default.removeObserver(regionObservation) }
            observedRegionStorage = storage
            invalidateRegionCache()
            regionObservation = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                                       object: storage, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidateRegionCache() }
            }
        }
        return RegionLayoutKey(storage: ObjectIdentifier(storage), manager: ObjectIdentifier(manager), container: ObjectIdentifier(container),
                               bounds: bounds, origin: textContainerOrigin, containerSize: container.containerSize,
                               padding: container.lineFragmentPadding, maxLines: container.maximumNumberOfLines, lineBreakMode: container.lineBreakMode)
    }

    var markdownDocument: Document?
    var inlineText: NSAttributedString?
    /// 现在显示的排版结果（和它在各个宽度下的高度，可能和别的行共用）。
    var rendered: TextRenderCache.Entry?
    /// 测量用的排版栈里现在放的是哪一份：换了正文才重新放进去，量过的宽度直接查缓存。
    var measuredText: TextRenderCache.Entry?

    func measuredHeight(forWidth width: CGFloat, maxLines: Int) -> CGFloat {
        let key = Int((min(width, 100_000) * 2).rounded())
        if let hit = rendered?.heights[key] { return hit }
        let measurement = measurer ?? TextMeasurer()
        measurer = measurement
        guard let rendered else { return measurement.height(forWidth: width) }
        if measuredText !== rendered {
            measurement.update(rendered.styled, maxLines: maxLines)
            measuredText = rendered
        }
        let height = measurement.height(forWidth: width)
        if rendered.heights.count > 32 { rendered.heights.removeAll() }
        rendered.heights[key] = height
        return height
    }
    var markdown = false
    var interactiveTasks = false
    var onToggleMarkdownTask: ((Int) -> Void)?
    private(set) var measurer: TextMeasurer?
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
    var uiScaleFactor = 1.0
    var configuredLineSpacing = 2.0
    /// 收起的 Markdown 标题（nil：标题不能折叠）。
    var foldedHeadings: Set<String>?
    var boardFolds: MarkdownText.BoardFoldMarks?
    var onToggleHeading: ((String) -> Void)?
    private var mouseDownEvent: NSEvent?
    private var dragged = false
    var onEdit: (() -> Void)?
    var onOpen: ((URL) -> Void)?
    var onSelect: (() -> Void)?
    var onClick: (() -> Void)?
    var onEditAt: ((CGPoint) -> Void)?
    /// 按下鼠标时交给了就地编辑器：这次的拖动、松开也转给它。
    private weak var forwardedMouse: NSView?
    private var hoveredURL: URL?
    private var hoveredHeading: String?
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
        let width = max(1, newSize.width - textContainerInset.width * 2)
        if frame.size == newSize, let container = textContainer, abs(container.containerSize.width - width) <= 0.5 { return }
        super.setFrameSize(newSize)
        if let container = textContainer, abs(container.containerSize.width - width) > 0.5 {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            needsLayout = true
        }
    }

    /// 太宽的独立公式：每个一条能左右滑动的条（只在有这种公式时才建）。
    private var mathStrips: [NSScrollView] = []

    override func layout() {
        super.layout()
        layoutMathStrips()
    }

    func layoutMathStrips() {
        var scrolling: [(rect: NSRect, cell: MathAttachment.Cell)] = []
        if let storage = textStorage, let manager = layoutManager, let container = textContainer,
           storage.length > 0, storage.string.contains("\u{FFFC}") {
            manager.ensureLayout(for: container)
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let cell = (value as? NSTextAttachment)?.attachmentCell as? MathAttachment.Cell, cell.display else { return }
                let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let size = manager.attachmentSize(forGlyphAt: glyphs.location)
                guard cell.scrolls(in: size.width) else { return }
                let line = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                let origin = manager.location(forGlyphAt: glyphs.location)
                let scale = size.height / max(1, cell.rendered.size.height)
                let bottom = line.minY + origin.y + cell.rendered.baseline * scale
                let x = line.minX + origin.x
                scrolling.append((NSRect(x: x + textContainerOrigin.x, y: bottom - size.height + textContainerOrigin.y,
                                         width: min(size.width, container.size.width - x), height: size.height), cell))
            }
        }
        while mathStrips.count > scrolling.count { mathStrips.removeLast().removeFromSuperview() }
        while mathStrips.count < scrolling.count {
            let strip = NSScrollView()
            strip.drawsBackground = false
            // 不显示滚动条：触控板 / 鼠标横向滑动就能左右移动。
            strip.hasHorizontalScroller = false
            strip.hasVerticalScroller = false
            strip.verticalScrollElasticity = .none
            strip.horizontalScrollElasticity = .allowed
            strip.documentView = MathStripContent()
            addSubview(strip)
            mathStrips.append(strip)
        }
        for (strip, item) in zip(mathStrips, scrolling) {
            strip.frame = item.rect
            guard let content = strip.documentView as? MathStripContent else { continue }
            content.cell = item.cell
            content.frame = NSRect(x: 0, y: 0, width: item.cell.rendered.size.width * MathAttachment.minimumScale, height: item.rect.height)
            content.needsDisplay = true
        }
    }

    func linkRegions() -> [(url: URL, rect: NSRect)] {
        guard let storage = textStorage, let manager = layoutManager, let container = textContainer else { return [] }
        let key = regionLayoutKey(storage: storage, manager: manager, container: container)
        if let cachedLinks, cachedLinks.key == key { return cachedLinks.regions }
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
        cachedLinks = (regionLayoutKey(storage: storage, manager: manager, container: container), regions)
        return regions
    }

    func link(at point: NSPoint) -> URL? {
        linkRegions().first { $0.rect.contains(point) }?.url
    }

    func taskRegions() -> [(line: Int, rect: NSRect)] {
        guard let storage = textStorage, let manager = layoutManager, let container = textContainer else { return [] }
        let key = regionLayoutKey(storage: storage, manager: manager, container: container)
        if let cachedTasks, cachedTasks.key == key { return cachedTasks.regions }
        manager.ensureLayout(for: container)
        var regions: [(line: Int, rect: NSRect)] = []
        storage.enumerateAttribute(MarkdownText.taskLineKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let line = value as? Int else { return }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
                .insetBy(dx: -3, dy: -3).intersection(self.bounds)
            if !rect.isEmpty { regions.append((line, rect)) }
        }
        cachedTasks = (regionLayoutKey(storage: storage, manager: manager, container: container), regions)
        return regions
    }

    /// 代码块：整块的底色区域和右上角「复制」按钮的位置。
    func codeRegions() -> [(info: MarkdownText.CodeBlockInfo, block: NSRect, copy: NSRect)] {
        guard markdown, let storage = textStorage, let manager = layoutManager, let container = textContainer, storage.length > 0 else { return [] }
        let key = regionLayoutKey(storage: storage, manager: manager, container: container)
        if let cachedCode, cachedCode.key == key { return cachedCode.regions }
        var regions: [(info: MarkdownText.CodeBlockInfo, block: NSRect, copy: NSRect)] = []
        var scanned = false
        storage.enumerateAttribute(MarkdownText.codeBlockKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let info = value as? MarkdownText.CodeBlockInfo else { return }
            if !scanned { manager.ensureLayout(for: container); scanned = true }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var union = NSRect.null
            var header = NSRect.null
            manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, used, _, _, _ in
                if header.isNull { header = used }
                union = union.union(rect)
            }
            guard !union.isNull else { return }
            let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let left = max(0, (style?.headIndent ?? 12) - 12)
            let width = min(container.size.width, self.bounds.width - self.textContainerOrigin.x * 2)
            let block = NSRect(x: self.textContainerOrigin.x + left, y: self.textContainerOrigin.y + union.minY + MarkdownText.codeBlockMargin,
                               width: width - left,
                               height: union.height - MarkdownText.codeBlockMargin * 2)
            let copyWidth: CGFloat = 64, copyHeight: CGFloat = 20
            // 和第一行的语言名对齐。
            let labelMid = self.textContainerOrigin.y + header.midY
            let copy = NSRect(x: block.maxX - copyWidth - 6, y: max(block.minY + 3, labelMid - copyHeight / 2), width: copyWidth, height: copyHeight)
            regions.append((info, block, copy))
        }
        cachedCode = (regionLayoutKey(storage: storage, manager: manager, container: container), regions)
        return regions
    }

    /// 刚复制过的代码块：按钮显示「已复制」一会儿。
    private var copiedCode: MarkdownText.CodeBlockInfo?

    private func copyCode(_ info: MarkdownText.CodeBlockInfo) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info.code, forType: .string)
        copiedCode = info
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.copiedCode === info else { return }
            self.copiedCode = nil
            self.needsDisplay = true
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let ink = foreground ?? .labelColor
        for region in codeRegions() where region.block.intersects(rect) {
            let path = NSBezierPath(roundedRect: region.block, xRadius: 8, yRadius: 8)
            ink.withAlphaComponent(0.06).setFill()
            path.fill()
            ink.withAlphaComponent(0.12).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }

    private func drawCopyButtons(in rect: NSRect) {
        let ink = foreground ?? .labelColor
        for region in codeRegions() where region.copy.intersects(rect) {
            let copied = copiedCode == region.info
            let tint = copied ? NSColor(Palette.success) : ink.withAlphaComponent(hoveredCopy == region.copy ? 0.85 : 0.55)
            if hoveredCopy == region.copy {
                ink.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: region.copy, xRadius: 5, yRadius: 5).fill()
            }
            let font = NSFont.systemFont(ofSize: 11, weight: .medium)
            let label = NSAttributedString(string: AppLocalized(copied ? "已复制" : "复制"), attributes: [.font: font, .foregroundColor: tint])
            let configuration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium).applying(.init(paletteColors: [tint]))
            let symbol = NSImage(systemSymbolName: copied ? "checkmark" : "doc.on.doc", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            let labelSize = label.size()
            let total = (symbol?.size.width ?? 0) + 4 + labelSize.width
            var x = region.copy.maxX - 6 - total
            if let symbol {
                symbol.draw(in: NSRect(x: x, y: region.copy.midY - symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += symbol.size.width + 4
            }
            label.draw(at: NSPoint(x: x, y: region.copy.midY - labelSize.height / 2))
        }
    }

    private var hoveredCopy: NSRect?

    /// 可折叠标题右边的收起 / 展开按钮（标题第一行的最右边；标题文字本身留给选择和编辑）。
    func headingRegions() -> [(key: String, rect: NSRect, folded: Bool)] {
        guard onToggleHeading != nil, let storage = textStorage, let manager = layoutManager, let container = textContainer else { return [] }
        let key = regionLayoutKey(storage: storage, manager: manager, container: container)
        if let cachedHeadings, cachedHeadings.key == key { return cachedHeadings.regions }
        manager.ensureLayout(for: container)
        var regions: [(key: String, rect: NSRect, folded: Bool)] = []
        storage.enumerateAttribute(MarkdownText.headingFoldKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let key = value as? String else { return }
            let folded = storage.attribute(MarkdownText.headingFoldedKey, at: range.location, effectiveRange: nil) as? Bool ?? false
            let tail = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.tailIndent ?? 0
            let side = max(16, -tail - 6)
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var first: NSRect?
            manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, stop in
                first = used
                stop.pointee = true
            }
            guard let line = first else { return }
            let right = self.textContainerOrigin.x + container.size.width - container.lineFragmentPadding
            let rect = NSRect(x: right - side, y: self.textContainerOrigin.y + line.midY - side / 2, width: side, height: side)
            if rect.intersects(self.bounds) { regions.append((key, rect, folded)) }
        }
        cachedHeadings = (regionLayoutKey(storage: storage, manager: manager, container: container), regions)
        return regions
    }

    func headingKey(at point: NSPoint) -> String? {
        headingRegions().first { $0.rect.insetBy(dx: -4, dy: -4).contains(point) }?.key
    }

    /// 收起 / 展开标题：标题留在滚动区域里原来的位置，内容在它下面展开、收起（滚到底时收起也不往下跳）。
    func toggleHeading(_ key: String) {
        if let scroll = enclosingScrollView {
            let folding = foldedHeadings?.contains(key) != true && boardFolds?.headings.values.first { $0.key == key }?.folded != true
            if folding { BottomSlack.reserve(in: scroll) } else { BottomSlack.trimAfterLayout(scroll) }
        }
        onToggleHeading?(key)
    }

    override func draw(_ dirtyRect: NSRect) {
        for region in linkRegions() where region.rect.intersects(dirtyRect) {
            NativePalette.accent.withAlphaComponent(hoveredURL == region.url ? 0.18 : 0.09).setFill()
            let path = NSBezierPath(roundedRect: region.rect, xRadius: 5, yRadius: 5)
            path.fill()
            NativePalette.accent.withAlphaComponent(0.18).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
        super.draw(dirtyRect)
        drawCopyButtons(in: dirtyRect)
        // 标题右边的收起 / 展开按钮画在文字上面（文字已经给它让出了位置）。
        for region in headingRegions() where region.rect.intersects(dirtyRect) {
            let color = foreground ?? .labelColor
            color.withAlphaComponent(hoveredHeading == region.key ? 0.14 : 0.07).setFill()
            NSBezierPath(roundedRect: region.rect, xRadius: region.rect.width * 0.3, yRadius: region.rect.width * 0.3).fill()
            MarkdownText.chevron(folded: region.folded, side: region.rect.width, color: color.withAlphaComponent(0.7))
                .draw(in: region.rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard interactionEnabled else { return }
        if dragTaskID != nil { addCursorRect(bounds, cursor: .openHand) }
        for region in linkRegions() { addCursorRect(region.rect, cursor: .pointingHand) }
        if onToggleMarkdownTask != nil {
            for region in taskRegions() { addCursorRect(region.rect, cursor: .pointingHand) }
        }
        for region in headingRegions() { addCursorRect(region.rect, cursor: .pointingHand) }
        for region in codeRegions() { addCursorRect(region.copy, cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let previous = hoveredURL
        let previousHeading = hoveredHeading
        let point = convert(event.locationInWindow, from: nil)
        hoveredURL = interactionEnabled ? link(at: point) : nil
        hoveredHeading = interactionEnabled && markdown ? headingKey(at: point) : nil
        if previousHeading != hoveredHeading { needsDisplay = true }
        let previousCopy = hoveredCopy
        hoveredCopy = interactionEnabled ? codeRegions().first { $0.copy.contains(point) }?.copy : nil
        if previousCopy != hoveredCopy { needsDisplay = true }
        if interactionEnabled, dragTaskID != nil {
            (TaskDragSession.shared.activeID != nil ? NSCursor.closedHand : (hoveredURL == nil ? NSCursor.openHand : NSCursor.pointingHand)).set()
        }
        // 只有悬停的链接变了才重画链接底色；鼠标在正文上移动不触发整段文字重绘。
        if previous != hoveredURL { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredURL = nil
        hoveredHeading = nil
        needsDisplay = true
    }

    func activate(at point: NSPoint, clickCount: Int = 1) {
        guard interactionEnabled else { return }
        onSelect?()
        if let task = taskRegions().first(where: { $0.rect.contains(point) }), let onToggleMarkdownTask {
            onToggleMarkdownTask(task.line)
        } else if clickCount == 1, let url = link(at: point) {
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
            // 点代码块的「复制」：复制整块代码。
            if let code = codeRegions().first(where: { $0.copy.contains(point) }) {
                copyCode(code.info)
                return
            }
            // 点标题右边的按钮：收起 / 展开；连续快点每一下都算，不当成双击进入编辑。
            if let heading = headingKey(at: point) {
                onSelect?()
                toggleHeading(heading)
                return
            }
            if event.clickCount == 2 || link(at: point) != nil || taskRegions().contains(where: { $0.rect.contains(point) }) {
                activate(at: point, clickCount: event.clickCount)
                return
            }
            onSelect?()
            onClick?()
            // 就地编辑器已经在这一条上面排好了（鼠标停在这里时）：这一下直接交给它，光标、拖选都由它处理，和在工作板里点一样。
            // 之后的拖动、松开还会送到这里（按下的是这个视图），一并转过去。
            if event.clickCount == 1, onEditAt != nil, interactionEnabled, let editor = InlineMarkdownEditor.shared.takeOver(event) {
                forwardedMouse = editor
                editor.mouseDown(with: event)
                return
            }
            super.mouseDown(with: event)
            // 系统的选择跟踪在松开鼠标后才返回：没有拖选文字就是点了一下，就地编辑。
            if event.clickCount == 1, selectedRange().length == 0, let onEditAt, interactionEnabled {
                onEditAt(NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y))
            }
            return
        }
        mouseDownEvent = event
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        if let forwardedMouse { forwardedMouse.mouseDragged(with: event); return }
        guard interactionEnabled, !dragged, let initial = mouseDownEvent,
              hypot(event.locationInWindow.x - initial.locationInWindow.x,
                    event.locationInWindow.y - initial.locationInWindow.y) > 4 else { return }
        dragged = true
        guard let id = dragTaskID, window != nil else { return }
        onSelect?()
        NativeTaskDrag.begin(id: id, title: string, view: self, source: self, event: initial)
    }

    override func mouseUp(with event: NSEvent) {
        if let forwardedMouse {
            self.forwardedMouse = nil
            forwardedMouse.mouseUp(with: event)
            return
        }
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

/// Markdown 标题的折叠记忆（笔记等原生渲染的正文）：只记收起的标题，按标识存进偏好。
@MainActor
enum HeadingFolds {
    static var defaults: UserDefaults = .standard

    static func key(_ id: String) -> String { "markdown.folds.\(id)" }

    static func folded(in id: String) -> Set<String> { Set(defaults.stringArray(forKey: key(id)) ?? []) }

    static func set(_ heading: String, folded: Bool, in id: String) {
        var current = self.folded(in: id)
        if folded { current.insert(heading) } else { current.remove(heading) }
        if current.isEmpty { defaults.removeObject(forKey: key(id)) } else { defaults.set(current.sorted(), forKey: key(id)) }
    }

    static func toggle(_ heading: String, in id: String) {
        var folded = folded(in: id)
        if folded.remove(heading) == nil { folded.insert(heading) }
        if folded.isEmpty { defaults.removeObject(forKey: key(id)) } else { defaults.set(folded.sorted(), forKey: key(id)) }
    }
}

/// 滚动区域底部临时多出的空白。收起标题时内容变短，已经滚到底的话系统会把内容往下拉，标题跟着往下跳；
/// 收起前先在底部留出空白撑住滚动位置，排版后只留下看得见的那部分，往上滚就逐渐收回。
@MainActor
enum BottomSlack {
    private static var slack: [ObjectIdentifier: (amount: CGFloat, observer: NSObjectProtocol)] = [:]

    static func amount(in scroll: NSScrollView) -> CGFloat { slack[ObjectIdentifier(scroll)]?.amount ?? 0 }

    /// 内容要变短之前调用：先留出一屏高的空白，排版完成后收到只剩看得见的部分。
    static func reserve(in scroll: NSScrollView) {
        guard scroll.documentView?.isFlipped == true else { return }
        let id = ObjectIdentifier(scroll)
        let observer = slack[id]?.observer ?? NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: nil) { [weak scroll] _ in
            MainActor.assumeIsolated { if let scroll { trim(scroll) } }
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        set(max(amount(in: scroll), scroll.contentView.bounds.height), observer: observer, on: scroll)
        trimAfterLayout(scroll)
    }

    /// 内容变了（比如展开）：排版完成后把看不到的空白收掉。
    static func trimAfterLayout(_ scroll: NSScrollView) {
        guard slack[ObjectIdentifier(scroll)] != nil else { return }
        Task { @MainActor [weak scroll] in
            // SwiftUI 在下一轮界面更新里才排版，两轮之后再量。
            for _ in 0..<2 { await Task.yield(); try? await Task.sleep(for: .milliseconds(16)) }
            if let scroll { scroll.documentView?.superview?.layoutSubtreeIfNeeded(); trim(scroll) }
        }
    }

    private static func trim(_ scroll: NSScrollView) {
        let id = ObjectIdentifier(scroll)
        guard let entry = slack[id], let documentView = scroll.documentView else { return }
        let visible = scroll.contentView.bounds.maxY - documentView.frame.height
        if visible < entry.amount - 0.5 { set(max(0, visible), observer: entry.observer, on: scroll) }
    }

    private static func set(_ amount: CGFloat, observer: NSObjectProtocol, on scroll: NSScrollView) {
        let id = ObjectIdentifier(scroll)
        let clip = scroll.contentView
        var insets = clip.contentInsets
        insets.bottom = max(0, insets.bottom + amount - (slack[id]?.amount ?? 0))
        if amount <= 0 {
            NotificationCenter.default.removeObserver(observer)
            slack[id] = nil
        } else {
            slack[id] = (amount, observer)
        }
        clip.automaticallyAdjustsContentInsets = false
        clip.contentInsets = insets
    }
}

/// 左右滑动条里的公式：按 `MathAttachment.minimumScale` 画。
final class MathStripContent: NSView {
    var cell: MathAttachment.Cell?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let cell else { return }
        cell.rendered.draw(in: bounds, color: cell.color, flipped: true)
    }
}
