import AppKit
import Markdown
import DayleafCore

/// CommonMark/GFM 语法树直接排进 TextKit；表格使用原生 NSTextTable。
/// 不执行 HTML，不自动请求远程图片。
enum MarkdownText {
    static func render(_ source: String, color: NSColor, fontSize: CGFloat, monospaced: Bool = false, lineSpacing: CGFloat = UIScale.lineSpacing) -> NSAttributedString {
        let renderer = Renderer(color: color, size: UIScale.pt(fontSize), monospaced: monospaced, lineSpacing: lineSpacing)
        renderer.blocks(Document(parsing: source))
        return renderer.output
    }

    private final class Renderer {
        let output = NSMutableAttributedString()
        let color: NSColor
        let size: CGFloat
        let font: NSFont
        let lineSpacing: CGFloat
        init(color: NSColor, size: CGFloat, monospaced: Bool, lineSpacing: CGFloat) {
            self.color = color
            self.size = size
            self.lineSpacing = lineSpacing
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
            if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
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
            for child in node.children { block(child, indent: indent) }
        }

        func block(_ node: Markup, indent: CGFloat) {
            switch node {
            case let heading as Heading:
                let headingFont = NSFont.systemFont(ofSize: size + CGFloat(max(1, 7 - heading.level)) * 1.5, weight: .bold)
                let paragraphStyle = style(indent: indent)
                paragraphStyle.paragraphSpacingBefore = 5
                paragraph(inline(heading, font: headingFont), style: paragraphStyle)
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
                        let content = text(marker + "\t")
                        content.append(inline(child))
                        let paragraphStyle = style(indent: indent + 22)
                        paragraphStyle.firstLineHeadIndent = indent
                        paragraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: indent + 22)]
                        paragraphStyle.paragraphSpacing = 3
                        paragraph(content, style: paragraphStyle)
                    } else { block(child, indent: indent + 22) }
                }
            }
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
}

private extension NSAttributedString {
    var fullRange: NSRange { NSRange(location: 0, length: length) }
}
