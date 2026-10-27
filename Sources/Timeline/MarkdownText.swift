import AppKit
import Markdown
import TimelineCore

/// CommonMark/GFM 语法树直接排进 TextKit；表格使用原生 NSTextTable。
/// 不执行 HTML，不自动请求远程图片。
enum MarkdownText {
    static let taskLineKey = NSAttributedString.Key("TimelineMarkdownTaskLine")
    /// 可折叠标题所在的整段：值是标题的折叠键（`h2:标题#0`，同名标题按出现次序编号，和工作板一致）。
    static let headingFoldKey = NSAttributedString.Key("TimelineMarkdownHeadingFold")
    /// 可折叠标题现在是否收起（右侧按钮画成朝右还是朝下）。
    static let headingFoldedKey = NSAttributedString.Key("TimelineMarkdownHeadingFolded")
    /// 标题右侧收起 / 展开按钮的边长；标题文字在右边给它让出位置。
    static func foldButtonSide(fontSize: CGFloat) -> CGFloat { (fontSize * 1.7).rounded() }

    /// 工作板正文的一段（笔记里的看板内容）怎么折叠：由整块工作板算好（标题的折叠范围可能跨过代码块、延伸到下一段），
    /// 这里只管画。行号是这一段里的行号，从 1 开始。
    struct BoardFoldMarks: Equatable {
        struct Mark: Equatable {
            let key: String
            let folded: Bool
        }
        /// 可以折叠的标题所在的行。
        var headings: [Int: Mark] = [:]
        /// 收起后藏起来的行。
        var hidden: [ClosedRange<Int>] = []
    }

    /// `folds` 不为 nil 时顶层标题可以折叠：里面是收起的标题键，收起的标题下面到下一个同级或更高级标题为止都不显示。
    /// `boardFolds` 不为 nil 时按工作板的折叠画（见 `BoardFoldMarks`）。
    static func render(_ source: String, color: NSColor, fontSize: CGFloat, monospaced: Bool = false, lineSpacing: CGFloat = UIScale.lineSpacing, scale: CGFloat = UIScale.factor, document: Document? = nil, interactiveTasks: Bool = false, folds: Set<String>? = nil, boardFolds: BoardFoldMarks? = nil) -> NSAttributedString {
        let math = MarkdownMath.extract(source)
        let renderer = Renderer(color: color, size: fontSize * scale, monospaced: monospaced, lineSpacing: lineSpacing, interactiveTasks: interactiveTasks)
        renderer.folds = folds
        renderer.boardFolds = boardFolds
        renderer.formulas = math.formulas
        renderer.sourceLines = math.source.components(separatedBy: "\n")
        renderer.blocks(document ?? Document(parsing: math.source))
        return renderer.output
    }

    /// 解析正文：公式先换成占位符（见 `MarkdownMath`），交给 `render(document:)` 时必须用这个解析。
    static func parse(_ source: String) -> Document {
        Document(parsing: MarkdownMath.extract(source).source)
    }

    private final class Renderer {
        private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let output = NSMutableAttributedString()
        let color: NSColor
        let size: CGFloat
        let font: NSFont
        let lineSpacing: CGFloat
        let interactiveTasks: Bool
        var sourceLines: [String] = []
        var folds: Set<String>?
        var boardFolds: BoardFoldMarks?
        var formulas: [MarkdownMath.Formula] = []
        init(color: NSColor, size: CGFloat, monospaced: Bool, lineSpacing: CGFloat, interactiveTasks: Bool) {
            self.color = color
            self.size = size
            self.lineSpacing = lineSpacing
            self.interactiveTasks = interactiveTasks
            font = monospaced ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
        }

        func style(indent: CGFloat = 0) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            style.paragraphSpacing = max(2, lineSpacing * 2)
            style.headIndent = indent
            style.firstLineHeadIndent = indent
            return style
        }

        func text(_ value: String, font: NSFont? = nil) -> NSMutableAttributedString {
            NSMutableAttributedString(string: value, attributes: [.font: font ?? self.font, .foregroundColor: color])
        }

        func inline(_ node: Markup, font: NSFont? = nil) -> NSMutableAttributedString {
            let font = font ?? self.font
            if let node = node as? Markdown.Text {
                guard !formulas.isEmpty || node.string.contains(MarkdownMath.continuation) else { return text(node.string, font: font) }
                let result = text("", font: font)
                for piece in MarkdownMath.pieces(node.string, formulas: formulas) {
                    switch piece {
                    case .text(let value): result.append(text(value, font: font))
                    case .formula(let formula): result.append(math(formula, font: font))
                    }
                }
                return result
            }
            if node is SoftBreak || node is LineBreak { return text("\n", font: font) }
            if let node = node as? InlineCode {
                let result = text(node.code, font: .monospacedSystemFont(ofSize: font.pointSize, weight: .regular))
                result.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.08), range: result.fullRange)
                return result
            }
            if let node = node as? InlineHTML { return text(node.rawHTML, font: font) }
            var childFont = font
            if node is Strong { childFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if node is Emphasis { childFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            let result = text("")
            let children = Array(node.children)
            for (index, child) in children.enumerated() {
                // 跨行公式后面几行只剩续行字符：它前面的换行也不要。
                if child is SoftBreak || child is LineBreak, index + 1 < children.count,
                   (children[index + 1] as? Markdown.Text)?.string.first == MarkdownMath.continuation { continue }
                result.append(inline(child, font: childFont))
            }
            if node is Strikethrough { result.addAttribute(.strikethroughStyle, value: 1, range: result.fullRange) }
            let destination = (node as? Link)?.destination ?? (node as? Markdown.Image)?.source
            if let destination, let url = TaskText.linkURL(destination) {
                if result.length == 0 { result.append(text(destination, font: font)) }
                result.addAttributes([.link: url, .foregroundColor: NativePalette.accent, .underlineStyle: 1, .cursor: NSCursor.pointingHand], range: result.fullRange)
            }
            return result
        }

        /// 公式附件；排不出来时显示原文（等宽、淡底色，和行内代码一样）。
        func math(_ formula: MarkdownMath.Formula, font: NSFont) -> NSMutableAttributedString {
            if let attachment = MathAttachment.string(formula, fontSize: font.pointSize, color: color, font: font) { return attachment }
            let result = text(formula.source, font: .monospacedSystemFont(ofSize: font.pointSize, weight: .regular))
            result.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.08), range: result.fullRange)
            return result
        }

        func paragraph(_ content: NSMutableAttributedString, style: NSMutableParagraphStyle) {
            if let detector = Self.linkDetector {
                for match in detector.matches(in: content.string, range: content.fullRange) {
                    guard let url = match.url.flatMap({ TaskText.linkURL($0.absoluteString) }),
                          content.attribute(.link, at: match.range.location, effectiveRange: nil) == nil,
                          content.attribute(.backgroundColor, at: match.range.location, effectiveRange: nil) == nil else { continue }
                    content.addAttributes([.link: url, .foregroundColor: NativePalette.accent, .underlineStyle: 1], range: match.range)
                }
            }
            content.append(text("\n"))
            content.addAttribute(.paragraphStyle, value: style, range: content.fullRange)
            centerDisplayMath(content, style: style)
            output.append(content)
        }

        /// 独占一行的独立公式居中，上下多留一点空。
        func centerDisplayMath(_ content: NSMutableAttributedString, style: NSParagraphStyle) {
            guard !formulas.isEmpty else { return }
            let string = content.string as NSString
            content.enumerateAttribute(MathAttachment.displayKey, in: content.fullRange) { value, range, _ in
                guard value != nil else { return }
                let line = string.paragraphRange(for: range)
                let rest = string.substring(with: line).replacingOccurrences(of: "\u{FFFC}", with: "")
                guard rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let centered = style.mutableCopy() as? NSMutableParagraphStyle else { return }
                centered.alignment = .center
                centered.firstLineHeadIndent = style.headIndent
                centered.paragraphSpacingBefore = max(style.paragraphSpacingBefore, 4)
                centered.paragraphSpacing = max(style.paragraphSpacing, 6)
                content.addAttribute(.paragraphStyle, value: centered, range: line)
            }
        }

        func blocks(_ node: Markup, indent: CGFloat = 0) {
            let children = Array(node.children)
            let foldable = folds != nil && node is Document
            let marks = node is Document ? boardFolds : nil
            var previousEnd: Int?
            var seen: [String: Int] = [:]
            var index = 0
            while index < children.count {
                let child = children[index]
                if let marks, let start = child.range?.lowerBound.line, marks.hidden.contains(where: { $0.contains(start) }) {
                    previousEnd = child.range?.upperBound.line
                    index += 1
                    continue
                }
                if let end = previousEnd, let start = child.range?.lowerBound.line, start > end + 1 {
                    let blankCount = sourceLines.dropFirst(end).prefix(start - end - 1)
                        .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
                    for _ in 0..<blankCount { paragraph(text(""), style: style(indent: indent)) }
                }
                previousEnd = child.range?.upperBound.line
                index += 1
                if let marks, let heading = child as? Heading, let line = heading.range?.lowerBound.line, let mark = marks.headings[line] {
                    renderHeading(heading, indent: indent, fold: (mark.key, mark.folded))
                    continue
                }
                guard foldable, let heading = child as? Heading else { block(child, indent: indent); continue }
                let name = "h\(heading.level):\(MarkdownMath.restore(heading.plainText, formulas: formulas).trimmingCharacters(in: .whitespaces))"
                let occurrence = seen[name, default: 0]
                seen[name] = occurrence + 1
                let key = "\(name)#\(occurrence)"
                var sectionEnd = index
                while sectionEnd < children.count, ((children[sectionEnd] as? Heading)?.level ?? 7) > heading.level { sectionEnd += 1 }
                let hasBody = sectionEnd > index
                let folded = hasBody && folds?.contains(key) == true
                renderHeading(heading, indent: indent, fold: hasBody ? (key, folded) : nil)
                if folded {
                    previousEnd = children[sectionEnd - 1].range?.upperBound.line
                    index = sectionEnd
                }
            }
        }

        func renderHeading(_ heading: Heading, indent: CGFloat, fold: (key: String, folded: Bool)? = nil) {
            let headingFont = NSFont.systemFont(ofSize: size + CGFloat(max(1, 7 - heading.level)) * 1.5, weight: .bold)
            let paragraphStyle = style(indent: indent)
            paragraphStyle.paragraphSpacingBefore = 5
            let content = inline(heading, font: headingFont)
            content.addAttribute(.foregroundColor, value: MarkdownText.headingColor(heading.level), range: content.fullRange)
            if let fold {
                // 收起 / 展开按钮画在标题行的最右边（`InteractiveTaskText` 负责画和点），标题文字在右边给它让出位置。
                paragraphStyle.tailIndent = -(MarkdownText.foldButtonSide(fontSize: size) + 6)
                content.addAttribute(MarkdownText.headingFoldKey, value: fold.key, range: content.fullRange)
                content.addAttribute(MarkdownText.headingFoldedKey, value: fold.folded, range: content.fullRange)
            }
            paragraph(content, style: paragraphStyle)
        }

        func block(_ node: Markup, indent: CGFloat) {
            switch node {
            case let heading as Heading:
                renderHeading(heading, indent: indent)
            case let node as Paragraph:
                paragraph(inline(node), style: style(indent: indent))
            case let code as CodeBlock:
                let content = text(code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code,
                                   font: .monospacedSystemFont(ofSize: size, weight: .regular))
                content.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.08), range: content.fullRange)
                paragraph(content, style: style(indent: indent + 8))
            case let table as Markdown.Table:
                renderTable(table, indent: indent)
            case let list as OrderedList:
                renderList(list, start: Int(list.startIndex), indent: indent)
            case let list as UnorderedList:
                renderList(list, start: nil, indent: indent)
            case let quote as BlockQuote:
                // 灰底引用框（像论坛里的引用）：左边一道竖线。连着的 > 行是一块，隔着空行就是两块。
                let frame = quoteBlock(indent: indent)
                let start = output.length
                blocks(quote, indent: 0)
                let range = NSRange(location: start, length: output.length - start)
                output.addAttribute(.foregroundColor, value: color.withAlphaComponent(0.85), range: range)
                output.enumerateAttribute(.paragraphStyle, in: range) { value, part, _ in
                    guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                    style.textBlocks.insert(frame, at: 0)
                    output.addAttribute(.paragraphStyle, value: style, range: part)
                }
            case is ThematicBreak:
                paragraph(text("────────────────"), style: style(indent: indent))
            case let html as HTMLBlock:
                paragraph(text(html.rawHTML), style: style(indent: indent))
            default:
                blocks(node, indent: indent)
            }
        }

        func quoteBlock(indent: CGFloat) -> NSTextBlock {
            let block = NSTextBlock()
            // 不给宽度时内容宽度是 0（字一列一个）：占满整行。
            block.setContentWidth(100, type: .percentageValueType)
            block.backgroundColor = color.withAlphaComponent(0.07)
            block.setWidth(4, type: .absoluteValueType, for: .border, edge: .minX)
            block.setBorderColor(color.withAlphaComponent(0.28), for: .minX)
            block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
            block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(4, type: .absoluteValueType, for: .padding, edge: .maxY)
            block.setWidth(indent, type: .absoluteValueType, for: .margin, edge: .minX)
            block.setWidth(3, type: .absoluteValueType, for: .margin, edge: .minY)
            block.setWidth(3, type: .absoluteValueType, for: .margin, edge: .maxY)
            return block
        }

        func renderList(_ list: Markup, start: Int?, indent: CGFloat) {
            for (index, child) in list.children.enumerated() {
                guard let item = child as? ListItem else { continue }
                let marker: String
                if let checkbox = item.checkbox { marker = checkbox == .checked ? "☑" : "☐" }
                else { marker = start.map { "\($0 + index)." } ?? "•" }
                for (blockIndex, child) in item.children.enumerated() {
                    if blockIndex == 0, child is Paragraph {
                        let content: NSMutableAttributedString
                        if interactiveTasks, let checkbox = item.checkbox, let line = item.range?.lowerBound.line {
                            content = taskCircle(checked: checkbox == .checked, line: line)
                            content.append(text("\t"))
                        } else {
                            content = text(marker + "\t")
                        }
                        let body = inline(child)
                        if item.checkbox == .checked {
                            body.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                                .foregroundColor: NSColor(Palette.muted)], range: body.fullRange)
                        }
                        content.append(body)
                        let paragraphStyle = style(indent: indent + 22)
                        paragraphStyle.firstLineHeadIndent = indent
                        paragraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: indent + 22)]
                        paragraphStyle.paragraphSpacing = 3
                        paragraph(content, style: paragraphStyle)
                    } else { block(child, indent: indent + 22) }
                }
            }
        }

        func taskCircle(checked: Bool, line: Int) -> NSMutableAttributedString {
            let side = size + 2
            let attachment = NSTextAttachment()
            let foreground = color
            attachment.bounds = NSRect(x: 0, y: font.descender, width: side, height: side)
            attachment.image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
                circle.lineWidth = 1.3
                if checked {
                    NSColor(Palette.success).setFill()
                    circle.fill()
                    NSColor.white.setStroke()
                    let check = NSBezierPath()
                    check.lineWidth = 1.5
                    check.lineCapStyle = .round
                    check.move(to: NSPoint(x: side * 0.27, y: side * 0.5))
                    check.line(to: NSPoint(x: side * 0.43, y: side * 0.34))
                    check.line(to: NSPoint(x: side * 0.73, y: side * 0.67))
                    check.stroke()
                } else {
                    foreground.withAlphaComponent(0.65).setStroke()
                    circle.stroke()
                }
                return true
            }
            let result = NSMutableAttributedString(attachment: attachment)
            result.addAttribute(MarkdownText.taskLineKey, value: line, range: result.fullRange)
            return result
        }

        func renderTable(_ node: Markdown.Table, indent: CGFloat) {
            let columns = node.maxColumnCount
            guard columns > 0 else { return }
            let table = NSTextTable()
            table.numberOfColumns = columns
            table.layoutAlgorithm = .fixedLayoutAlgorithm
            table.collapsesBorders = true
            table.setValue(100, type: .percentageValueType, for: .width)
            let rows: [Markup] = [node.head] + Array(node.body.children)
            for (rowIndex, row) in rows.enumerated() {
                for (column, cell) in row.children.enumerated() {
                    let cellBlock = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                    cellBlock.setValue(100 / CGFloat(columns), type: .percentageValueType, for: .width)
                    cellBlock.setWidth(6, type: .absoluteValueType, for: .padding)
                    cellBlock.setWidth(0.5, type: .absoluteValueType, for: .border)
                    cellBlock.setBorderColor(color.withAlphaComponent(0.25))
                    cellBlock.verticalAlignment = .topAlignment
                    if rowIndex == 0 { cellBlock.backgroundColor = color.withAlphaComponent(0.08) }
                    let paragraphStyle = style(indent: indent)
                    paragraphStyle.paragraphSpacing = 0
                    paragraphStyle.textBlocks = [cellBlock]
                    switch node.columnAlignments[column] {
                    case .center: paragraphStyle.alignment = .center
                    case .right: paragraphStyle.alignment = .right
                    default: paragraphStyle.alignment = .left
                    }
                    paragraph(inline(cell, font: rowIndex == 0 ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font), style: paragraphStyle)
                }
            }
            paragraph(text(""), style: style(indent: indent))
        }
    }

    /// 折叠箭头：固定大小的画布，展开 / 收起两种箭头宽度不同也不会让标题文字左右跳。
    static func chevron(folded: Bool, side: CGFloat, color: NSColor) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.62, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let symbol = NSImage(systemSymbolName: folded ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let symbol else { return true }
            let size = symbol.size
            symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            return true
        }
    }

    static func headingColor(_ level: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let colors: [UInt32] = dark ? [0xdd9179, 0xd4ae62, 0x79b898, 0x73afcf, 0xa596d1, 0xc68fae]
                : [0xa84d33, 0x846000, 0x327455, 0x296d91, 0x7658a4, 0x984d77]
            let value = colors[max(0, min(level - 1, colors.count - 1))]
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
}

private extension NSAttributedString {
    var fullRange: NSRange { NSRange(location: 0, length: length) }
}
