import AppKit
import Markdown
import TimelineCore

/// CommonMark/GFM 语法树直接排进 TextKit；表格使用原生 NSTextTable。
/// 不执行 HTML，不自动请求远程图片。
enum MarkdownText {
    static let taskLineKey = NSAttributedString.Key("TimelineMarkdownTaskLine")

    static func render(_ source: String, color: NSColor, fontSize: CGFloat, monospaced: Bool = false, lineSpacing: CGFloat = UIScale.lineSpacing, scale: CGFloat = UIScale.factor, document: Document? = nil, interactiveTasks: Bool = false) -> NSAttributedString {
        let renderer = Renderer(color: color, size: fontSize * scale, monospaced: monospaced, lineSpacing: lineSpacing, interactiveTasks: interactiveTasks)
        renderer.sourceLines = source.components(separatedBy: "\n")
        renderer.blocks(document ?? Document(parsing: source))
        return renderer.output
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
            if let node = node as? Markdown.Text { return text(node.string, font: font) }
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
            for child in node.children { result.append(inline(child, font: childFont)) }
            if node is Strikethrough { result.addAttribute(.strikethroughStyle, value: 1, range: result.fullRange) }
            let destination = (node as? Link)?.destination ?? (node as? Markdown.Image)?.source
            if let destination, let url = TaskText.linkURL(destination) {
                if result.length == 0 { result.append(text(destination, font: font)) }
                result.addAttributes([.link: url, .foregroundColor: NSColor.linkColor, .underlineStyle: 1, .cursor: NSCursor.pointingHand], range: result.fullRange)
            }
            return result
        }

        func paragraph(_ content: NSMutableAttributedString, style: NSMutableParagraphStyle) {
            if let detector = Self.linkDetector {
                for match in detector.matches(in: content.string, range: content.fullRange) {
                    guard let url = match.url.flatMap({ TaskText.linkURL($0.absoluteString) }),
                          content.attribute(.link, at: match.range.location, effectiveRange: nil) == nil,
                          content.attribute(.backgroundColor, at: match.range.location, effectiveRange: nil) == nil else { continue }
                    content.addAttributes([.link: url, .foregroundColor: NSColor.linkColor, .underlineStyle: 1], range: match.range)
                }
            }
            content.append(text("\n"))
            content.addAttribute(.paragraphStyle, value: style, range: content.fullRange)
            output.append(content)
        }

        func blocks(_ node: Markup, indent: CGFloat = 0) {
            var previousEnd: Int?
            for child in node.children {
                if let end = previousEnd, let start = child.range?.lowerBound.line, start > end + 1 {
                    let blankCount = sourceLines.dropFirst(end).prefix(start - end - 1)
                        .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
                    for _ in 0..<blankCount { paragraph(text(""), style: style(indent: indent)) }
                }
                block(child, indent: indent)
                previousEnd = child.range?.upperBound.line
            }
        }

        func block(_ node: Markup, indent: CGFloat) {
            switch node {
            case let heading as Heading:
                let headingFont = NSFont.systemFont(ofSize: size + CGFloat(max(1, 7 - heading.level)) * 1.5, weight: .bold)
                let paragraphStyle = style(indent: indent)
                paragraphStyle.paragraphSpacingBefore = 5
                let content = inline(heading, font: headingFont)
                content.addAttribute(.foregroundColor, value: MarkdownText.headingColor(heading.level), range: content.fullRange)
                paragraph(content, style: paragraphStyle)
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
                let start = output.length
                blocks(quote, indent: indent + 16)
                output.addAttribute(.foregroundColor, value: color.withAlphaComponent(0.75), range: NSRange(location: start, length: output.length - start))
            case is ThematicBreak:
                paragraph(text("────────────────"), style: style(indent: indent))
            case let html as HTMLBlock:
                paragraph(text(html.rawHTML), style: style(indent: indent))
            default:
                blocks(node, indent: indent)
            }
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
