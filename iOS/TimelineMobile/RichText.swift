import SwiftUI
import UIKit

/// Markdown 正文里连着的段落、普通列表拼成一个 `NSAttributedString`，交给 TextKit 排版、自己画。
/// SwiftUI 里每个列表项是一组 HStack / VStack / Text，几十项的长笔记排一次要一百多毫秒；这里一段只是一个视图。
/// 排版结果按宽度记住，而且可以在后台先排好（`prewarm`）：翻到那天时主线程只需要画。
final class RichText: @unchecked Sendable {
    static let linkKey = NSAttributedString.Key("timeline.link")

    let string: NSAttributedString
    private var layouts: [CGFloat: Layout] = [:]

    /// 一个宽度下排好的版。排好以后只读：后台排、主线程画。
    final class Layout {
        let storage: NSTextStorage
        let manager = NSLayoutManager()
        let container: NSTextContainer
        let height: CGFloat
        /// 第一行基线离顶边的距离：放在列表记号旁边时按它对齐。
        let firstBaseline: CGFloat
        /// 太宽、要左右滑动的独立公式：占的位置和公式本身（画布在这些位置放滑动条）。
        let scrollingMath: [(rect: CGRect, math: MathAttachment)]

        init(_ string: NSAttributedString, width: CGFloat) {
            storage = NSTextStorage(attributedString: string)
            container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            manager.allowsNonContiguousLayout = false
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
            height = ceil(manager.usedRect(for: container).height)
            firstBaseline = storage.length == 0 ? 0
                : manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY + manager.location(forGlyphAt: 0).y
            var scrolling: [(rect: CGRect, math: MathAttachment)] = []
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { [manager, container] value, range, _ in
                guard let math = value as? MathAttachment, math.formula.display else { return }
                let glyph = manager.glyphIndexForCharacter(at: range.location)
                let size = manager.attachmentSize(forGlyphAt: glyph)
                guard math.scrolls(in: size) else { return }
                let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let origin = manager.location(forGlyphAt: glyph)
                let x = line.minX + origin.x
                // 附件的底边在基线下面 `-bounds.minY`（按缩放比例算）处。
                let scale = size.height / max(1, math.bounds.height)
                let bottom = line.minY + origin.y - math.bounds.minY * scale
                scrolling.append((CGRect(x: x, y: bottom - size.height, width: min(size.width, container.size.width - x), height: size.height), math))
            }
            scrollingMath = scrolling
        }

        func draw(_ rect: CGRect) {
            let glyphs = manager.glyphRange(forBoundingRect: rect, in: container)
            manager.drawBackground(forGlyphRange: glyphs, at: .zero)
            manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
        }

        func link(at point: CGPoint) -> URL? {
            guard storage.length > 0 else { return nil }
            let glyph = manager.glyphIndex(for: point, in: container)
            let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            guard rect.insetBy(dx: -4, dy: -4).contains(point) else { return nil }
            return storage.attribute(RichText.linkKey, at: manager.characterIndexForGlyph(at: glyph), effectiveRange: nil) as? URL
        }
    }

    private init(_ string: NSAttributedString) { self.string = string }

    func layout(width: CGFloat) -> Layout {
        let width = max(1, (width * 2).rounded(.down) / 2)
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if let cached = layouts[width] { return cached }
        let started = CACurrentMediaTime()
        let layout = Layout(string, width: width)
        if Thread.isMainThread { MainActor.assumeIsolated { PerfProbe.typeset(CACurrentMediaTime() - started) } }
        if layouts.count > 3 { layouts.removeAll() }
        layouts[width] = layout
        return layout
    }

    // MARK: 缓存

    private static let lock = NSRecursiveLock()
    nonisolated(unsafe) private static var cache: [String: RichText] = [:]
    /// 每种字号最近一次排版的宽度：后台预排用它。
    nonisolated(unsafe) private static var widths: [CGFloat: CGFloat] = [:]

    static func make(_ document: MarkdownDocument, run: Range<Int>, source: String, size: CGFloat) -> RichText {
        let key = "\(size)|\(run.lowerBound)|" + source
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let text = RichText(build(document.blocks[run], size: size))
        if cache.count > 800 { cache.removeAll() }
        cache[key] = text
        return text
    }

    /// 长文章（`LongParagraph`）里的一块：几十行，行间距和普通段落一样。
    static func lines(_ text: AttributedString, size: CGFloat) -> RichText {
        let key = "\(size)|lines|\(text.runs.count)|" + String(text.characters)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let string = NSMutableAttributedString(attributedString: inline(text, size: size, color: UIColor(Palette.ink)))
        let style = NSMutableParagraphStyle()
        style.lineSpacing = size * 0.25
        string.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: string.length))
        MathAttachment.centerDisplayMath(string, size: size)
        let result = RichText(string)
        if cache.count > 800 { cache.removeAll() }
        cache[key] = result
        return result
    }

    static func width(for size: CGFloat) -> CGFloat? {
        lock.lock()
        defer { lock.unlock() }
        return widths[size]
    }

    static func remember(width: CGFloat, size: CGFloat) {
        lock.lock()
        widths[size] = width
        lock.unlock()
    }

    /// 后台把正文拼好、按上次的宽度排好版。
    static func prewarm(_ document: MarkdownDocument, source: String, size: CGFloat) {
        let width = width(for: size)
        for run in document.runs.values {
            let text = make(document, run: run, source: source, size: size)
            if let width { _ = text.layout(width: width) }
        }
    }

    // MARK: 拼字

    /// 整篇正文拼成一段可选中的文字（「选择文字」页）：标题、引用、代码、表格也拼进来，链接换成系统的 `.link`。
    static func selectable(_ source: String, size: CGFloat) -> NSAttributedString {
        let document = MarkdownBlock.parse(source)
        let text = NSMutableAttributedString(attributedString: build(document.blocks[...], size: size, complete: true))
        text.enumerateAttribute(linkKey, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let url = value as? URL { text.addAttribute(.link, value: url, range: range) }
        }
        return text
    }

    private static func build(_ blocks: ArraySlice<MarkdownBlock>, size: CGFloat, complete: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let ink = UIColor(Palette.ink), muted = UIColor(Palette.muted)
        let body = UIFont.systemFont(ofSize: size)

        func paragraph(_ text: NSAttributedString, indent: CGFloat, head: CGFloat, spacing: CGFloat, marker: NSAttributedString?) {
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = indent
            style.headIndent = head
            style.lineSpacing = size * 0.25
            style.paragraphSpacingBefore = result.length == 0 ? 0 : spacing
            style.tabStops = [NSTextTab(textAlignment: .left, location: head)]
            style.defaultTabInterval = 28
            let line = NSMutableAttributedString()
            if result.length > 0 { line.append(NSAttributedString(string: "\n", attributes: [.font: body])) }
            if let marker {
                line.append(marker)
                line.append(NSAttributedString(string: "\t", attributes: [.font: body]))
            }
            line.append(text)
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            MathAttachment.centerDisplayMath(line, size: size)
            result.append(line)
        }

        func list(_ items: [MarkdownBlock.Item], start: Int?, indent: CGFloat, spacing: CGFloat) {
            let markers = items.indices.map { index in
                start.map { NSAttributedString(string: "\($0 + index).", attributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: size, weight: .regular), .foregroundColor: muted]) }
                    ?? NSAttributedString(string: "•", attributes: [.font: UIFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: muted])
            }
            let head = indent + ceil(markers.map { $0.size().width }.max() ?? 0) + 8
            var gap = spacing
            for (index, item) in items.enumerated() {
                if item.blocks.isEmpty { paragraph(NSAttributedString(), indent: indent, head: head, spacing: gap, marker: markers[index]) }
                for (position, child) in item.blocks.enumerated() {
                    switch child {
                    case .paragraph(let text):
                        paragraph(inline(text, size: size, color: ink), indent: position == 0 ? indent : head, head: head,
                                  spacing: gap, marker: position == 0 ? markers[index] : nil)
                    case .list(let nested, let nestedStart):
                        if position == 0 { paragraph(NSAttributedString(), indent: indent, head: head, spacing: gap, marker: markers[index]) }
                        list(nested, start: nestedStart, indent: head, spacing: size * 0.35)
                    case .html(let raw):
                        paragraph(html(raw), indent: position == 0 ? indent : head, head: head, spacing: gap, marker: position == 0 ? markers[index] : nil)
                    default:
                        break
                    }
                    gap = size * 0.35
                }
                gap = size * 0.35
            }
        }

        func html(_ raw: String) -> NSAttributedString {
            NSAttributedString(string: raw.replacingOccurrences(of: "\n", with: "\u{2028}"),
                               attributes: [.font: UIFont.monospacedSystemFont(ofSize: size * 0.9, weight: .regular), .foregroundColor: muted])
        }

        func restyled(_ text: NSAttributedString, font: UIFont? = nil, color: UIColor? = nil) -> NSAttributedString {
            let copy = NSMutableAttributedString(attributedString: text)
            let range = NSRange(location: 0, length: copy.length)
            if let font { copy.addAttribute(.font, value: font, range: range) }
            if let color { copy.addAttribute(.foregroundColor, value: color, range: range) }
            return copy
        }

        // 平时只拼段落、列表和 HTML（标题、引用、代码、表格由 `MarkdownView` 单独画）；`complete` 时全部拼成一段。
        func add(_ blocks: ArraySlice<MarkdownBlock>, indent: CGFloat, color: UIColor) {
            for block in blocks {
                let spacing = size * 0.55
                switch block {
                case .paragraph(let text): paragraph(restyled(inline(text, size: size, color: ink), color: color == ink ? nil : color),
                                                     indent: indent, head: indent, spacing: spacing, marker: nil)
                case .list(let items, let start): list(items, start: start, indent: indent, spacing: spacing)
                case .html(let raw): paragraph(html(raw), indent: indent, head: indent, spacing: spacing, marker: nil)
                case .heading(let level, let text, _, _) where complete:
                    let scale: CGFloat = level == 1 ? 1.35 : (level == 2 ? 1.2 : 1.08)
                    paragraph(restyled(inline(text, size: size, color: ink), font: .systemFont(ofSize: size * scale, weight: .bold)),
                              indent: indent, head: indent, spacing: size * 0.8, marker: nil)
                case .quote(let children) where complete:
                    add(children[...], indent: indent + 14, color: muted)
                case .code(_, let code) where complete:
                    let text = NSAttributedString(string: code.replacingOccurrences(of: "\n", with: "\u{2028}"),
                                                  attributes: [.font: UIFont.monospacedSystemFont(ofSize: size * 0.9, weight: .regular),
                                                               .foregroundColor: ink, .backgroundColor: muted.withAlphaComponent(0.12)])
                    paragraph(text, indent: indent, head: indent, spacing: spacing, marker: nil)
                case .table(let header, let rows) where complete:
                    for (index, row) in ([header] + rows).enumerated() {
                        let line = NSMutableAttributedString()
                        for (column, cell) in row.enumerated() {
                            if column > 0 { line.append(NSAttributedString(string: "  ·  ", attributes: [.font: body, .foregroundColor: muted])) }
                            let text = inline(cell, size: size, color: ink)
                            line.append(index == 0 ? restyled(text, font: .systemFont(ofSize: size, weight: .semibold)) : text)
                        }
                        paragraph(line, indent: indent, head: indent, spacing: index == 0 ? spacing : size * 0.3, marker: nil)
                    }
                case .rule where complete:
                    paragraph(NSAttributedString(string: "———", attributes: [.font: body, .foregroundColor: muted]),
                              indent: indent, head: indent, spacing: spacing, marker: nil)
                default: break
                }
            }
        }

        add(blocks, indent: 0, color: ink)
        return result
    }

    /// 行内格式：加粗、斜体、删除线、行内代码、链接、公式。段落里的换行换成行分隔符，不另起一段（缩进和段距不乱）；
    /// 只有独立公式前后的换行是真的分段，公式自成一段才能居中。
    private static func inline(_ text: AttributedString, size: CGFloat, color: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var breakAfterDisplay = false
        for run in text.runs {
            var value = String(text.characters[run.range]).replacingOccurrences(of: "\n", with: "\u{2028}")
            if breakAfterDisplay, value.hasPrefix("\u{2028}") { value = "\n" + value.dropFirst() }
            breakAfterDisplay = false
            if let formula = run[MathFormulaAttribute.self] {
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size), .foregroundColor: color]
                if let math = MathAttachment.string(formula, size: size, color: color, attributes: attributes) {
                    if formula.display {
                        if result.string.hasSuffix("\u{2028}") { result.replaceCharacters(in: NSRange(location: result.length - 1, length: 1), with: "\n") }
                        breakAfterDisplay = true
                    }
                    result.append(math)
                } else {
                    // 排不出来：显示原文，样子和行内代码一样。
                    result.append(NSAttributedString(string: value, attributes: [.font: UIFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular),
                                                                                  .foregroundColor: color, .backgroundColor: UIColor(Palette.muted).withAlphaComponent(0.15)]))
                }
                continue
            }
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code) ? UIFont.monospacedSystemFont(ofSize: size, weight: .regular) : UIFont.systemFont(ofSize: size)
            var traits: UIFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            if !traits.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)) {
                font = UIFont(descriptor: descriptor, size: size)
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let foreground = run[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] { attributes[.foregroundColor] = UIColor(foreground) }
            if intent.contains(.code) { attributes[.backgroundColor] = UIColor(Palette.muted).withAlphaComponent(0.15) }
            if let url = run.link {
                attributes[linkKey] = url
                attributes[.foregroundColor] = UIColor(Palette.accent)
            }
            result.append(NSAttributedString(string: value, attributes: attributes))
        }
        return result
    }
}

extension MarkdownBlock {
    /// 能拼进 `RichText` 的块：普通段落（超长、按行断开的整篇文章仍交给 `LongParagraph` 分批排）、
    /// 没有勾选框的列表（里面也只有这些块）、HTML 原文。
    var flows: Bool {
        switch self {
        case .paragraph(let text): return !(text.characters.count > LongParagraph.threshold && text.characters.contains("\n"))
        case .list(let items, _): return items.allSatisfy { $0.checkbox == nil && $0.blocks.allSatisfy(\.flows) }
        case .html: return true
        default: return false
        }
    }
}

/// 画 `RichText` 的视图。点链接打开；其他的点按和长按都留给外面（日志的长按菜单）。
struct RichTextView: UIViewRepresentable {
    let text: RichText
    let size: CGFloat
    private static let probeWidth: CGFloat = 80
    private static let fallbackWidth: CGFloat = 320

    func makeUIView(context: Context) -> RichTextCanvas { RichTextCanvas() }

    func updateUIView(_ view: RichTextCanvas, context: Context) {
        view.open = context.environment.openURL
        view.text = text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RichTextCanvas, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        // 外层排版时会拿很窄的宽度（几个点）来试探：真按那么窄排一遍，长正文要几十毫秒，还会排出几千点高。
        // 这种试探给上次正常宽度的高度就行，不排、也不当成常用宽度记下。
        // 还没有记下常用宽度时（这种字号第一次排）按一个普通手机宽度估：真按几点宽排，一篇长文会排出几十万点高，
        // 滚动视图按这个高度算，跳到底部会落进一大片空白。
        if width < Self.probeWidth {
            return CGSize(width: width, height: text.layout(width: RichText.width(for: size) ?? Self.fallbackWidth).height)
        }
        RichText.remember(width: width, size: size)
        return CGSize(width: width, height: text.layout(width: width).height)
    }
}

final class RichTextCanvas: UIView, UIGestureRecognizerDelegate {
    var text: RichText? {
        didSet {
            guard text !== oldValue else { return }
            accessibilityLabel = text?.string.string
            setNeedsDisplay()
            setNeedsLayout()
        }
    }
    /// 太宽的独立公式：每个一条能左右滑动的条（只在有这种公式时才建）。
    private var mathStrips: [UIScrollView] = []

    override func layoutSubviews() {
        super.layoutSubviews()
        let scrolling = text.map { bounds.width > 0 ? $0.layout(width: bounds.width).scrollingMath : [] } ?? []
        while mathStrips.count > scrolling.count { mathStrips.removeLast().removeFromSuperview() }
        while mathStrips.count < scrolling.count {
            let strip = UIScrollView()
            strip.showsVerticalScrollIndicator = false
            strip.alwaysBounceHorizontal = true
            strip.addSubview(UIImageView())
            addSubview(strip)
            mathStrips.append(strip)
        }
        for (strip, item) in zip(mathStrips, scrolling) {
            let size = CGSize(width: item.math.rendered.image.size.width * MathAttachment.minimumScale, height: item.rect.height)
            strip.frame = item.rect
            strip.contentSize = size
            guard let image = strip.subviews.first as? UIImageView else { continue }
            image.frame = CGRect(origin: .zero, size: size)
            image.image = item.math.rendered.image(for: traitCollection, color: item.math.color)
        }
    }
    var open: OpenURLAction?
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        addGestureRecognizer(tap)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: RichTextCanvas, _: UITraitCollection) in
            view.setNeedsDisplay()
            view.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        let started = CACurrentMediaTime()
        text?.layout(width: bounds.width).draw(rect)
        PerfProbe.drew(CACurrentMediaTime() - started)
    }

    private func link(at point: CGPoint) -> URL? { text?.layout(width: bounds.width).link(at: point) }

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        recognizer === tap ? link(at: recognizer.location(in: self)) != nil : super.gestureRecognizerShouldBegin(recognizer)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let url = link(at: recognizer.location(in: self)) else { return }
        if let open { open(url) } else { UIApplication.shared.open(url) }
    }
}
