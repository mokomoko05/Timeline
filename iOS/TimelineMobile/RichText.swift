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

        init(_ string: NSAttributedString, width: CGFloat) {
            storage = NSTextStorage(attributedString: string)
            container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            manager.allowsNonContiguousLayout = false
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
            height = ceil(manager.usedRect(for: container).height)
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

    private static func build(_ blocks: ArraySlice<MarkdownBlock>, size: CGFloat) -> NSAttributedString {
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

        for block in blocks {
            let spacing = size * 0.55
            switch block {
            case .paragraph(let text): paragraph(inline(text, size: size, color: ink), indent: 0, head: 0, spacing: spacing, marker: nil)
            case .list(let items, let start): list(items, start: start, indent: 0, spacing: spacing)
            case .html(let raw): paragraph(html(raw), indent: 0, head: 0, spacing: spacing, marker: nil)
            default: break
            }
        }
        return result
    }

    /// 行内格式：加粗、斜体、删除线、行内代码、链接。段落里的换行换成行分隔符，不另起一段（缩进和段距不乱）。
    private static func inline(_ text: AttributedString, size: CGFloat, color: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in text.runs {
            let value = String(text.characters[run.range]).replacingOccurrences(of: "\n", with: "\u{2028}")
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

    func makeUIView(context: Context) -> RichTextCanvas { RichTextCanvas() }

    func updateUIView(_ view: RichTextCanvas, context: Context) {
        view.open = context.environment.openURL
        view.text = text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RichTextCanvas, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        // 外层排版时会拿很窄的宽度（几个点）来试探：真按那么窄排一遍，长正文要几十毫秒，还会排出几千点高。
        // 这种试探给上次正常宽度的高度就行，不排、也不当成常用宽度记下。
        if width < Self.probeWidth, let usual = RichText.width(for: size) {
            return CGSize(width: width, height: text.layout(width: usual).height)
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
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: RichTextCanvas, _: UITraitCollection) in view.setNeedsDisplay() }
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
