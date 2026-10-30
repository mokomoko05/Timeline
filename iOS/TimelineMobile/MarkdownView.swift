import QuartzCore
import UIKit
import Markdown
import SwiftUI
import TimelineCore
import UIKit

/// 页面把滚动交给 Markdown：长段落末尾的「收起」要把标题滚回视野里。
private struct ScrollToKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var scrollToMarkdownAnchor: ((String) -> Void)? {
        get { self[ScrollToKey.self] }
        set { self[ScrollToKey.self] = newValue }
    }
}

extension View {
    /// 放在 `ScrollViewReader` 里：Markdown 的标题可以被滚动到顶部。
    func markdownScrolling(_ proxy: ScrollViewProxy) -> some View {
        environment(\.scrollToMarkdownAnchor) { id in
            proxy.scrollTo(id, anchor: .top)
        }
    }
}

/// Markdown 正文（CommonMark/GFM，和 Mac 用同一个解析器）。
/// 标题下面有内容时可以点标题收起，收起到下一个同级或更高级标题为止；`foldScope` 不为 nil 时记住收起状态。
/// 展开的长段落末尾有一个「收起」，收起后滚回标题，不用往回翻找。
/// `toggleTask` 不为 nil 时任务勾选可以点（参数是源码里的行号，从 1 开始）。
///
/// 折叠不做布局动画：长文本整段跟着动画重排很卡，只让箭头转一下。每个块用它在全文里的序号做标识。
/// 展开过的块收起时不从视图里拿掉，只把高度压成 0：再展开时文字不用重新排版（长段落排一次要好几帧）。
/// 块之间的间距放在每块自己的上边距里，压成 0 的块不留空隙。
/// Markdown 正文。`size` 是默认字号下的大小，跟着系统的「文字大小」缩放（最多放大到 1.8 倍，长文排版还放得下）。
struct MarkdownView: View {
    let source: String
    var foldScope: String?
    var size: CGFloat = 16
    var toggleTask: ((Int) -> Void)?
    /// 只用来在系统文字大小改变时重新计算。
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        MarkdownContent(source: source, foldScope: foldScope, size: Self.scaled(size, typeSize), toggleTask: toggleTask)
    }

    static func scaled(_ size: CGFloat, _ typeSize: DynamicTypeSize) -> CGFloat {
        let category = UIContentSizeCategory(typeSize)
        let scaled = UIFontMetrics(forTextStyle: .body).scaledValue(for: size, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
        return min(scaled, size * 1.8).rounded()
    }
}

private struct MarkdownContent: View {
    let source: String
    var foldScope: String?
    var size: CGFloat = 16
    var toggleTask: ((Int) -> Void)?
    @State private var folded: Set<String> = []
    @State private var loaded = false
    /// 这次显示期间展开过的标题：它们下面的块已经排过版，收起后留在视图里。
    @State private var opened: Set<String> = []
    @Environment(\.scrollToMarkdownAnchor) private var scrollTo

    var body: some View {
        MarkdownColumn(document: MarkdownBlock.parse(source), cacheSource: source, size: size, toggleTask: toggleTask,
                       folds: MarkdownFolds(folded: folded, opened: opened, toggle: toggleFold, setDisclosure: setDisclosure),
                       scope: foldScope ?? String(source.hashValue), scrollTo: scrollTo)
        .onAppear(perform: loadFolds)
        // 编辑器里收起 / 展开的，正文也跟着变。
        .onReceive(NotificationCenter.default.publisher(for: BoardWebSession.markdownFoldsChanged)) { note in
            if let defaultsKey, note.object as? String == defaultsKey { folded = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []) }
        }
    }

    private var defaultsKey: String? { foldScope.map { "markdownFolds." + $0 } }

    private func loadFolds() {
        guard !loaded else { return }
        loaded = true
        if let defaultsKey { folded = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []) }
    }

    private func toggleFold(_ key: String) {
        opened.insert(key)
        if folded.contains(key) { folded.remove(key) } else { folded.insert(key) }
        if let defaultsKey { UserDefaults.standard.set(Array(folded), forKey: defaultsKey) }
    }

    private func setDisclosure(_ key: String, open: Bool) {
        opened.insert(key)
        FoldRecords.set(key, value: open, in: &folded)
        if let defaultsKey { UserDefaults.standard.set(Array(folded), forKey: defaultsKey) }
    }
}

/// 一层块：整篇正文，或折叠块里的内容（折叠块里也能再有标题和折叠块）。
private struct MarkdownColumn: View {
    let document: MarkdownDocument
    /// 排版缓存用的原文：折叠块里的内容在原文后面带上折叠键，序号不会和外层撞。
    let cacheSource: String
    let size: CGFloat
    let toggleTask: ((Int) -> Void)?
    let folds: MarkdownFolds
    let scope: String
    let scrollTo: ((String) -> Void)?
    /// 在折叠块里：比正文窄，不当成这种字号的常用宽度记下。
    var nested = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(visible, id: \.id) { item in
                Group {
                switch item.kind {
                case .block(let block):
                    if case .disclosure(let disclosure) = block {
                        DisclosureView(disclosure: disclosure, cacheSource: cacheSource, size: size, toggleTask: toggleTask, folds: folds, scope: scope, scrollTo: scrollTo)
                    } else if case .heading(let level, let text, let key, _) = block, document.sections[item.index] != nil {
                        // 标题文字是正文的一部分；收起 / 展开用标题右边的按钮。
                        HStack(alignment: .center, spacing: 8) {
                            headingText(level, text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HeadingFoldButton(folded: folds.folded.contains(key), size: size) { folds.toggle(key) }
                        }
                        .id(anchor(key))
                    } else {
                        BlockView(block: block, size: size, toggleTask: toggleTask, folds: folds)
                    }
                case .flow(let run):
                    RichTextView(text: RichText.make(document, run: run, source: cacheSource, size: size), size: size, remembersWidth: !nested)
                case .collapse(let key, let title):
                    Button {
                        folds.toggle(key)
                        let id = anchor(key)
                        DispatchQueue.main.async { scrollTo?(id) }
                    } label: {
                        Label("收起「\(title)」", systemImage: "chevron.up")
                            .font(.system(size: size * 0.8))
                            .foregroundStyle(Palette.accent)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
                }
                .padding(.top, item.index == 0 ? 0 : size * 0.55)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: item.hidden ? 0 : nil, alignment: .top)
                .clipped()
                .opacity(item.hidden ? 0 : 1)
                .allowsHitTesting(!item.hidden)
                .accessibilityHidden(item.hidden)
            }
        }
    }

    private func headingText(_ level: Int, _ text: AttributedString) -> some View {
        Text(markdown: text, size: size + CGFloat(max(1, 7 - level)) * 1.6)
            .font(.system(size: size + CGFloat(max(1, 7 - level)) * 1.6, weight: .bold))
            .foregroundStyle(Palette.heading(level))
            .padding(.top, level <= 2 ? size * 0.3 : 0)
    }

    private func anchor(_ key: String) -> String { scope + "|" + key }

    private struct Visible: Identifiable {
        enum Kind { case block(MarkdownBlock), flow(Range<Int>), collapse(key: String, title: String) }
        let id: String
        let index: Int
        let kind: Kind
        /// 在收起的标题下面、但之前展开过：留着排好的版，只是不显示。
        var hidden = false
    }

    /// 要放进视图的块：收起的标题下面没展开过的内容不放；展开过的标成隐藏；展开的长段落末尾补一个「收起」。
    private var visible: [Visible] {
        var result: [Visible] = []
        var open: [(end: Int, key: String, title: String, folded: Bool, long: Bool, hidden: Bool)] = []
        for (index, block) in document.blocks.enumerated() {
            while let last = open.last, last.end <= index {
                if !last.folded, last.long, !last.hidden {
                    result.append(Visible(id: "collapse-\(last.key)", index: -1, kind: .collapse(key: last.key, title: last.title)))
                }
                open.removeLast()
            }
            let hidden = open.contains { $0.folded }
            let kept = open.allSatisfy { !$0.folded || folds.opened.contains($0.key) }
            if kept, !document.inRun.contains(index) {
                let kind: Visible.Kind = document.runs[index].map { .flow($0) } ?? .block(block)
                result.append(Visible(id: "\(index)", index: index, kind: kind, hidden: hidden))
            }
            if case .heading(_, let text, let key, _) = block, let section = document.sections[index] {
                open.append((section.end, key, String(text.characters), folds.folded.contains(key), section.long, hidden))
            }
        }
        for last in open.reversed() where !last.folded && last.long && !last.hidden {
            result.append(Visible(id: "collapse-\(last.key)", index: -1, kind: .collapse(key: last.key, title: last.title)))
        }
        return result
    }
}

/// `<details>` 折叠块：点标题行展开 / 收起，内容缩进、左边一道竖线（和 Mac 一样）。
/// 和标题一样，展开过的内容收起时留在视图里、只把高度压成 0，再展开不用重新排版。
private struct DisclosureView: View {
    let disclosure: MarkdownBlock.Disclosure
    let cacheSource: String
    let size: CGFloat
    let toggleTask: ((Int) -> Void)?
    let folds: MarkdownFolds
    let scope: String
    let scrollTo: ((String) -> Void)?

    var body: some View {
        let open = folds.isOpen(disclosure)
        VStack(alignment: .leading, spacing: 0) {
            Button { folds.setDisclosure(disclosure.key, !open) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: size * 0.7, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .animation(Motion.adapt(.easeOut(duration: 0.15)), value: open)
                        .frame(width: MarkdownDocument.disclosureIndent, alignment: .leading)
                    Text(disclosure.title)
                        .font(.system(size: size, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -10)
            .accessibilityValue(open ? "已展开" : "已收起")
            .accessibilityHint(open ? "收起" : "展开")
            .onReceive(NotificationCenter.default.publisher(for: PerfProbe.action)) { note in
                if note.object as? String == "toggleDisclosure" { folds.setDisclosure(disclosure.key, !folds.isOpen(disclosure)) }
            }
            if open || folds.opened.contains(disclosure.key) {
                MarkdownColumn(document: disclosure.document, cacheSource: disclosure.cacheSource(cacheSource), size: size, toggleTask: toggleTask,
                               folds: folds, scope: scope, scrollTo: scrollTo, nested: true)
                    .padding(.top, size * 0.45)
                    .padding(.leading, MarkdownDocument.disclosureIndent)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Palette.line).frame(width: 1.5).padding(.top, size * 0.45).padding(.leading, 4)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: open ? nil : 0, alignment: .top)
                    .clipped()
                    .opacity(open ? 1 : 0)
                    .allowsHitTesting(open)
                    .accessibilityHidden(!open)
            }
        }
    }
}

/// 标题右边的收起 / 展开按钮。
private struct HeadingFoldButton: View {
    let folded: Bool
    let size: CGFloat
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "chevron.down")
                .font(.system(size: size * 0.85, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .rotationEffect(.degrees(folded ? -90 : 0))
                .animation(Motion.adapt(.easeOut(duration: 0.15)), value: folded)
                .frame(width: size * 1.9, height: size * 1.9)
                .background(Palette.muted.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.55, style: .continuous))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(folded ? "展开" : "收起")
        .padding(.vertical, -8)
    }
}

/// 收起了哪些标题、怎么切换：引用里的标题和顶层的共用一份（折叠键在整篇里唯一，也和编辑器一样）。
private struct MarkdownFolds {
    /// 折叠记忆的记录，格式见 `FoldRecords`。
    let folded: Set<String>
    /// 这次显示期间切换过的：内容已经排过版，收起后留在视图里。
    let opened: Set<String>
    let toggle: (String) -> Void
    let setDisclosure: (String, Bool) -> Void

    func isOpen(_ disclosure: MarkdownBlock.Disclosure) -> Bool {
        FoldRecords.isOpen(disclosure.key, initially: disclosure.initiallyOpen, in: folded)
    }
}

/// 解析结果：顶层块，以及每个可以收起的标题管到哪里、内容长不长。
struct MarkdownDocument {
    /// 折叠块内容的缩进：和标题文字对齐（箭头占这么宽）。
    static let disclosureIndent: CGFloat = 19

    let blocks: [MarkdownBlock]
    /// 标题序号 → 它的段落结束位置（不含），和段落是否够长（需要末尾的「收起」）。
    let sections: [Int: (end: Int, long: Bool)]
    /// 连着的、能拼成一段 `RichText` 的块：起点 → 范围。标题不在里面，所以一段不会跨过收起的边界。
    /// 太长的一串切成几段（每段不超过一两屏），画的时候不用一次铺一整张大图。
    let runs: [Int: Range<Int>]
    /// 在某段里、但不是起点的块。
    let inRun: Set<Int>

    init(blocks: [MarkdownBlock], sections: [Int: (end: Int, long: Bool)]) {
        self.blocks = blocks
        self.sections = sections
        var runs: [Int: Range<Int>] = [:]
        var start: Int?
        var weight = 0
        func close(_ end: Int) {
            if let first = start { runs[first] = first..<end }
            start = nil
            weight = 0
        }
        for (index, block) in blocks.enumerated() {
            guard block.flows else { close(index); continue }
            if start != nil, weight > 1200 { close(index) }
            if start == nil { start = index }
            weight += block.weight
        }
        close(blocks.count)
        self.runs = runs
        inRun = Set(runs.values.flatMap { $0.dropFirst() })
    }
}

/// 行内公式：这段文字是哪个公式（`RichText` 排版时换成公式图）。
enum MathFormulaAttribute: AttributedStringKey {
    typealias Value = MarkdownMath.Formula
    static let name = "timeline.math"
}

extension AttributedString {
    var containsMath: Bool { runs[MathFormulaAttribute.self].contains { $0.0 != nil } }
}

/// 解析后的块。
indirect enum MarkdownBlock {
    case heading(Int, AttributedString, key: String, line: Int)
    case paragraph(AttributedString)
    case list([Item], start: Int?)
    case quote([MarkdownBlock])
    case code(language: String?, String)
    case table(header: [AttributedString], rows: [[AttributedString]])
    case rule
    case html(String)
    case disclosure(Disclosure)

    /// `<details>`：内容自成一层（里面的标题收起时不会跨出这个折叠块）。
    struct Disclosure {
        let title: String
        let key: String
        let initiallyOpen: Bool
        let document: MarkdownDocument

        func cacheSource(_ outer: String) -> String { outer + "\u{0}" + key }
    }

    struct Item {
        let checkbox: Bool?
        let line: Int
        let blocks: [MarkdownBlock]
    }

    var headingLevel: Int? {
        if case .heading(let level, _, _, _) = self { return level }
        return nil
    }

    /// 大致的文字量，用来判断一段算不算长。
    var weight: Int {
        switch self {
        case .heading(_, let text, _, _), .paragraph(let text): return text.characters.count + 40
        case .list(let items, _): return items.reduce(0) { $0 + $1.blocks.reduce(30) { $0 + $1.weight } }
        case .quote(let blocks): return blocks.reduce(0) { $0 + $1.weight }
        case .code(_, let code): return code.count + code.filter { $0 == "\n" }.count * 40
        case .table(_, let rows): return rows.count * 80
        case .rule: return 20
        case .html(let text): return text.count
        case .disclosure(let disclosure): return disclosure.document.blocks.reduce(disclosure.title.count + 40) { $0 + $1.weight }
        }
    }

    // 解析结果按原文缓存；预读（后台）和显示（主线程）都会用到，所以加锁。
    private static var cache: [String: MarkdownDocument] = [:]
    private static let lock = NSLock()

    static func parse(_ source: String) -> MarkdownDocument {
        lock.lock()
        let cached = cache[source]
        lock.unlock()
        if let cached { return cached }
        let started = CACurrentMediaTime()
        defer { if Thread.isMainThread { MainActor.assumeIsolated { PerfProbe.parsed(CACurrentMediaTime() - started) } } }
        // 公式先换成占位符再解析（见 `MarkdownMath`），行内拼字时再换回来。
        let math = MarkdownMath.extract(source)
        var context = Context(seen: [:], formulas: math.formulas)
        let blocks = topLevel(Document(parsing: math.source), source: math.source, context: &context)
        let document = MarkdownDocument(blocks: blocks, sections: sections(of: blocks))
        lock.lock()
        if cache.count > 600 { cache.removeAll() }
        cache[source] = document
        lock.unlock()
        return document
    }

    /// 同一层的块里，每个标题管到哪里：到下一个同级或更高级标题为止（引用里的标题只在这个引用里算）。
    static func sections(of blocks: [MarkdownBlock]) -> [Int: (end: Int, long: Bool)] {
        var sections: [Int: (end: Int, long: Bool)] = [:]
        for (index, block) in blocks.enumerated() {
            guard let level = block.headingLevel else { continue }
            var end = index + 1
            var weight = 0
            while end < blocks.count, (blocks[end].headingLevel ?? 7) > level { weight += blocks[end].weight; end += 1 }
            if end > index + 1 { sections[index] = (end, weight > 900) }
        }
        return sections
    }

    /// 在后台先解析好、把正文按上次的宽度排好版，翻到时直接用（日记里的正文是 15 号字）。
    static func prewarm(_ sources: [String], size: CGFloat = 15) {
        guard !sources.isEmpty else { return }
        Task.detached(priority: .utility) { for source in sources { warm(source, size: size) } }
    }

    static func warm(_ source: String, size: CGFloat = 15) {
        RichText.prewarm(parse(source), source: source, size: size)
    }

    /// 解析时一路带着的东西：同名标题出现了几次（折叠键用），和这篇正文里的公式。
    private struct Context {
        var seen: [String: Int]
        let formulas: [MarkdownMath.Formula]
    }

    private static func blocks(_ node: Markup, context: inout Context) -> [MarkdownBlock] {
        node.children.compactMap { block($0, context: &context) }
    }

    /// 顶层的块：配好对的 `<details>` 收成折叠块（一个 HTML 块里可能连着开头、标题、内容和结尾，所以按行看）。
    private static func topLevel(_ document: Document, source: String, context: inout Context) -> [MarkdownBlock] {
        guard source.range(of: "<details", options: .caseInsensitive) != nil else { return blocks(document, context: &context) }
        let spans = MarkdownDisclosures.spans(source.components(separatedBy: "\n"), untitled: L("折叠内容"))
        guard !spans.isEmpty else { return blocks(document, context: &context) }
        let openings = Dictionary(spans.map { ($0.line, $0) }, uniquingKeysWith: { first, _ in first })
        let closings = Dictionary(spans.map { ($0.closing, $0) }, uniquingKeysWith: { first, _ in first })
        var root: [MarkdownBlock] = []
        var stack: [(span: MarkdownDisclosures.Span, blocks: [MarkdownBlock])] = []
        func add(_ block: MarkdownBlock) {
            if stack.isEmpty { root.append(block) } else { stack[stack.count - 1].blocks.append(block) }
        }
        func close() {
            let (span, children) = stack.removeLast()
            add(.disclosure(Disclosure(title: MarkdownMath.restore(span.title, formulas: context.formulas), key: span.key, initiallyOpen: span.initiallyOpen,
                                       document: MarkdownDocument(blocks: children, sections: sections(of: children)))))
        }
        var bodyStart = 0
        for child in document.children {
            let raw = (child as? HTMLBlock)?.rawHTML.components(separatedBy: "\n") ?? []
            // 没有折叠块标签的 HTML 照旧原样显示。
            guard let first = child.range?.lowerBound.line,
                  raw.indices.contains(where: { openings[first + $0] != nil || closings[first + $0] != nil || first + $0 < bodyStart }) else {
                if let block = block(child, context: &context) { add(block) }
                continue
            }
            var pending: [String] = []
            func flush() {
                let text = pending.joined(separator: "\n")
                pending = []
                // 和标签连着写的内容按正文显示（和 Mac 一样）。
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let text = disclosureFree(text) {
                    add(.paragraph(AttributedString(MarkdownMath.restore(text, formulas: context.formulas))))
                }
            }
            for (offset, line) in raw.enumerated() {
                let number = first + offset
                if let span = openings[number] {
                    flush()
                    stack.append((span, []))
                    bodyStart = span.bodyStart
                } else if number < bodyStart {
                    continue
                } else if let span = closings[number] {
                    flush()
                    if stack.contains(where: { $0.span.line == span.line }) {
                        while let last = stack.last, last.span.line != span.line { close() }
                        close()
                    }
                } else {
                    pending.append(line)
                }
            }
            flush()
        }
        while !stack.isEmpty { close() }
        return root
    }

    /// 没配好对的 `<details>` 和引用、列表里的不折叠：标签不显示，标题留下来，内容是后面的块，照常显示。
    private static func disclosureFree(_ raw: String) -> String? {
        guard raw.range(of: "<details", options: .caseInsensitive) != nil || raw.range(of: "</details", options: .caseInsensitive) != nil
                || raw.range(of: "<summary", options: .caseInsensitive) != nil else { return raw }
        let text = raw.replacingOccurrences(of: #"</?(details|summary)\b[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private static func block(_ node: Markup, context: inout Context) -> MarkdownBlock? {
        let formulas = context.formulas
        switch node {
        case let heading as Heading:
            // 折叠键和 Mac 一样：级别 + 标题文字 + 同名标题的出现次序。
            let name = "h\(heading.level):\(MarkdownMath.restore(heading.plainText, formulas: formulas).trimmingCharacters(in: .whitespaces))"
            let occurrence = context.seen[name, default: 0]
            context.seen[name] = occurrence + 1
            return .heading(heading.level, inline(heading, formulas: formulas), key: "\(name)#\(occurrence)", line: heading.range?.lowerBound.line ?? 0)
        case let paragraph as Paragraph:
            return .paragraph(inline(paragraph, formulas: formulas))
        case let list as OrderedList:
            return .list(items(list, context: &context), start: Int(list.startIndex))
        case let list as UnorderedList:
            return .list(items(list, context: &context), start: nil)
        case let quote as BlockQuote:
            return .quote(blocks(quote, context: &context))
        case let code as CodeBlock:
            return .code(language: code.language?.nilIfEmpty, code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code)
        case let table as Markdown.Table:
            let header = table.head.children.map { inline($0, formulas: formulas) }
            let rows = table.body.children.map { row in row.children.map { inline($0, formulas: formulas) } }
            return .table(header: header, rows: rows)
        case is ThematicBreak:
            return .rule
        case let html as HTMLBlock:
            return disclosureFree(html.rawHTML).map { .html($0) }
        default:
            let nested = blocks(node, context: &context)
            return nested.isEmpty ? nil : .quote(nested)
        }
    }

    private static func items(_ list: Markup, context: inout Context) -> [Item] {
        list.children.compactMap { child in
            guard let item = child as? ListItem else { return nil }
            return Item(checkbox: item.checkbox.map { $0 == .checked }, line: item.range?.lowerBound.line ?? 0, blocks: blocks(item, context: &context))
        }
    }

    // MARK: 行内

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func inline(_ node: Markup, formulas: [MarkdownMath.Formula] = []) -> AttributedString {
        detectLinks(spans(node, intent: [], formulas: formulas))
    }

    private static func spans(_ node: Markup, intent: InlinePresentationIntent, formulas: [MarkdownMath.Formula]) -> AttributedString {
        var value = AttributedString()
        let children = Array(node.children)
        for (index, child) in children.enumerated() {
            // 跨行公式后面几行只剩续行字符：它前面的换行也不要。
            if child is SoftBreak || child is LineBreak, index + 1 < children.count,
               (children[index + 1] as? Markdown.Text)?.string.first == MarkdownMath.continuation { continue }
            value += span(child, intent: intent, formulas: formulas)
        }
        return value
    }

    private static func span(_ node: Markup, intent: InlinePresentationIntent, formulas: [MarkdownMath.Formula]) -> AttributedString {
        if let text = node as? Markdown.Text {
            guard !formulas.isEmpty || text.string.contains(MarkdownMath.continuation) else { return styled(text.string, intent) }
            var value = AttributedString()
            for piece in MarkdownMath.pieces(text.string, formulas: formulas) {
                switch piece {
                case .text(let string): value += styled(string, intent)
                case .formula(let formula):
                    // 字面上是公式原文（SwiftUI 的 `Text` 画不了公式时显示它），`RichText` 认这个属性排成公式。
                    var math = styled(formula.source, intent)
                    math[MathFormulaAttribute.self] = formula
                    value += math
                }
            }
            return value
        }
        if node is SoftBreak || node is LineBreak { return styled("\n", intent) }
        if let code = node as? InlineCode {
            var value = styled(code.code, intent.union(.code))
            value.backgroundColor = Palette.muted.opacity(0.15)
            return value
        }
        if let html = node as? InlineHTML { return styled(html.rawHTML, intent) }
        var childIntent = intent
        if node is Strong { childIntent.insert(.stronglyEmphasized) }
        if node is Emphasis { childIntent.insert(.emphasized) }
        if node is Strikethrough { childIntent.insert(.strikethrough) }
        var value = spans(node, intent: childIntent, formulas: formulas)
        if let image = node as? Markdown.Image {
            value = styled("🖼 " + (value.characters.isEmpty ? (image.source ?? "") : String(value.characters)), intent)
        }
        let destination = (node as? Markdown.Link)?.destination ?? (node as? Markdown.Image)?.source
        if let destination, let url = TaskText.linkURL(destination) {
            if value.characters.isEmpty { value = styled(destination, intent) }
            value.link = url
            value.foregroundColor = Palette.accent
        }
        return value
    }

    private static func styled(_ text: String, _ intent: InlinePresentationIntent) -> AttributedString {
        var value = AttributedString(text)
        if !intent.isEmpty { value.inlinePresentationIntent = intent }
        return value
    }

    /// 正文里裸写的网址也能点。
    private static func detectLinks(_ value: AttributedString) -> AttributedString {
        guard let detector = linkDetector else { return value }
        let text = String(value.characters)
        guard text.contains("."), text.contains(where: { $0 == ":" || $0 == "/" || $0 == "." }) else { return value }
        var result = value
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url.flatMap({ TaskText.linkURL($0.absoluteString) }),
                  let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result),
                  result[lower..<upper].link == nil, result[lower..<upper].runs[MathFormulaAttribute.self].allSatisfy({ $0.0 == nil }) else { continue }
            result[lower..<upper].link = url
            result[lower..<upper].foregroundColor = Palette.accent
        }
        return result
    }
}

private struct BlockView: View {
    let block: MarkdownBlock
    let size: CGFloat
    let toggleTask: ((Int) -> Void)?
    var folds: MarkdownFolds?

    var body: some View {
        switch block {
        case .heading(let level, let text, _, _):
            Text(markdown: text, size: size + CGFloat(max(1, 7 - level)) * 1.6)
                .font(.system(size: size + CGFloat(max(1, 7 - level)) * 1.6, weight: .bold))
                .foregroundStyle(Palette.heading(level))
        case .paragraph(let text):
            if text.characters.count > LongParagraph.threshold, text.characters.contains("\n") {
                LongParagraph(text: text, size: size)
            } else if text.containsMath {
                // 引用、待办列表里的段落：公式只有 `RichText` 排得出来。按第一行的基线和列表记号对齐。
                let rich = RichText.lines(text, size: size)
                RichTextView(text: rich, size: size)
                    .alignmentGuide(.firstTextBaseline) { rich.layout(width: $0.width).firstBaseline }
            } else {
                Text(text).font(.system(size: size)).foregroundStyle(Palette.ink).lineSpacing(size * 0.25)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .list(let items, let start):
            VStack(alignment: .leading, spacing: size * 0.35) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(item, index: index, start: start)
                        VStack(alignment: .leading, spacing: size * 0.35) {
                            ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, child in
                                if item.checkbox == true, case .paragraph(let text) = child {
                                    Text(markdown: text, size: size).font(.system(size: size)).strikethrough().foregroundStyle(Palette.muted)
                                } else {
                                    BlockView(block: child, size: size, toggleTask: toggleTask, folds: folds)
                                }
                            }
                        }
                    }
                }
            }
        case .quote(let blocks):
            VStack(alignment: .leading, spacing: size * 0.4) {
                let sections = MarkdownBlock.sections(of: blocks)
                ForEach(quoteVisible(blocks, sections: sections), id: \.self) { index in
                    if let folds, case .heading(_, _, let key, _) = blocks[index], sections[index] != nil {
                        HStack(alignment: .center, spacing: 8) {
                            BlockView(block: blocks[index], size: size, toggleTask: toggleTask)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HeadingFoldButton(folded: folds.folded.contains(key), size: size) { folds.toggle(key) }
                        }
                        .onReceive(NotificationCenter.default.publisher(for: PerfProbe.action)) { note in
                            if note.object as? String == "foldQuotedHeading" { folds.toggle(key) }
                        }
                    } else {
                        BlockView(block: blocks[index], size: size, toggleTask: toggleTask, folds: folds)
                    }
                }
            }
            // 灰底引用框（像论坛里的引用）：左边一道竖线。连着的 > 行是一块，隔着空行就是两块。
            .padding(.vertical, 8).padding(.leading, 14).padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.muted.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .leading) { UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6).fill(Palette.muted.opacity(0.45)).frame(width: 4) }
        case .code(let language, let code):
            CodeBlockView(language: language, code: code, size: size)
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in tableCell(cell, header: true) }
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in tableCell(cell, header: false) }
                        }
                    }
                }
                .overlay(Rectangle().stroke(Palette.line, lineWidth: 1))
            }
        case .rule:
            Rectangle().fill(Palette.line).frame(height: 1).padding(.vertical, 4)
        case .disclosure:
            // 由 `MarkdownColumn` 画（只出现在顶层和折叠块里）。
            EmptyView()
        case .html(let text):
            Text(text).font(.system(size: size * 0.9, design: .monospaced)).foregroundStyle(Palette.muted)
        }
    }

    /// 引用里要显示的块：跳过收起的标题下面的内容。引用通常很短，收起时不留排好的版。
    private func quoteVisible(_ blocks: [MarkdownBlock], sections: [Int: (end: Int, long: Bool)]) -> [Int] {
        var result: [Int] = []
        var index = 0
        while index < blocks.count {
            result.append(index)
            if case .heading(_, _, let key, _) = blocks[index], folds?.folded.contains(key) == true, let section = sections[index] {
                index = section.end
            } else {
                index += 1
            }
        }
        return result
    }

    @ViewBuilder private func marker(_ item: MarkdownBlock.Item, index: Int, start: Int?) -> some View {
        if let checked = item.checkbox {
            let symbol = Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: size * 0.95))
                .foregroundStyle(checked ? Palette.success : Palette.muted)
            if let toggleTask {
                Button { toggleTask(item.line) } label: { symbol }.buttonStyle(.plain)
            } else {
                symbol
            }
        } else if let start {
            Text("\(start + index).").font(.system(size: size).monospacedDigit()).foregroundStyle(Palette.muted)
        } else {
            Text("•").font(.system(size: size, weight: .bold)).foregroundStyle(Palette.muted)
        }
    }

    private func tableCell(_ text: AttributedString, header: Bool) -> some View {
        Text(markdown: text, size: size * 0.9)
            .font(.system(size: size * 0.9, weight: header ? .semibold : .regular))
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(minWidth: 60, maxWidth: 240, alignment: .leading)
            .background(header ? Palette.muted.opacity(0.1) : .clear)
            .border(Palette.line.opacity(0.7), width: 0.5)
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String
    let size: CGFloat
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? L("代码")).font(.caption2.weight(.semibold)).foregroundStyle(Palette.muted)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Palette.success : Palette.muted)
            }
            .padding(.horizontal, 10).padding(.top, 7)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(Self.highlighted(code, language: language)).font(.system(size: size * 0.82, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.muted.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 按语言着色（注释、字符串、关键字…），结果按代码缓存。
    private static func highlighted(_ code: String, language: String?) -> AttributedString {
        var result = AttributedString(code)
        let utf16 = code.utf16
        for token in CodeHighlight.tokens(code, language: language) {
            guard let lower = utf16.index(utf16.startIndex, offsetBy: token.range.location, limitedBy: utf16.endIndex),
                  let upper = utf16.index(lower, offsetBy: token.range.length, limitedBy: utf16.endIndex),
                  let from = AttributedString.Index(lower, within: result), let to = AttributedString.Index(upper, within: result) else { continue }
            result[from..<to].foregroundColor = color(token.kind)
        }
        return result
    }

    /// 和 Mac 一样的配色（接近 GitHub），深浅色各一套。
    private static func color(_ kind: CodeHighlight.Kind) -> Color {
        let (light, dark): (UInt32, UInt32)
        switch kind {
        case .comment: (light, dark) = (0x6e7781, 0x8b949e)
        case .string: (light, dark) = (0x0a3069, 0xa5d6ff)
        case .number, .attribute: (light, dark) = (0x0550ae, 0x79c0ff)
        case .keyword: (light, dark) = (0xcf222e, 0xff7b72)
        case .type: (light, dark) = (0x953800, 0xffa657)
        case .function: (light, dark) = (0x8250df, 0xd2a8ff)
        }
        return Color(UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}




/// 很长、又按行断开的段落（整篇贴进来的文章）：每几十行切成一块，先排第一块，其余每帧补一块。
/// 每块交给 `RichText`（TextKit 排版、按宽度记住结果）：用 SwiftUI 的 `Text` 时，每次切回页面、开关面板都要把一万多字重新量一遍。
struct LongParagraph: View {
    static let threshold = 600
    let size: CGFloat
    private let chunks: [AttributedString]
    @State private var shown = 1

    private static let linesPerChunk = 24

    init(text: AttributedString, size: CGFloat) {
        // 带格式（加粗、链接）的部分按原样切开，每块保留自己的属性。
        var chunks: [AttributedString] = []
        var start = text.startIndex
        var index = text.startIndex
        var lines = 0
        while index < text.endIndex {
            if text.characters[index] == "\n" {
                lines += 1
                if lines == Self.linesPerChunk {
                    chunks.append(AttributedString(text[start..<index]))
                    start = text.characters.index(after: index)
                    lines = 0
                }
            }
            index = text.characters.index(after: index)
        }
        if start < text.endIndex || chunks.isEmpty { chunks.append(AttributedString(text[start..<text.endIndex])) }
        self.chunks = chunks
        self.size = size
    }

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.25) {
            ForEach(0..<min(shown, chunks.count), id: \.self) { index in
                RichTextView(text: RichText.lines(chunks[index], size: size), size: size)
            }
        }
        .task {
            while shown < chunks.count {
                try? await Task.sleep(nanoseconds: 16_000_000)
                shown += 1
            }
        }
    }
}
