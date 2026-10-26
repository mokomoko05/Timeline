import Markdown
import SwiftUI
import TimelineCore
import UIKit

/// Markdown 正文（CommonMark/GFM，和 Mac 用同一个解析器）。
/// 标题下面有内容时可以点标题收起，收起到下一个同级或更高级标题为止；`foldScope` 不为 nil 时记住收起状态。
/// `toggleTask` 不为 nil 时任务勾选可以点（参数是源码里的行号，从 1 开始）。
struct MarkdownView: View {
    let source: String
    var foldScope: String?
    var size: CGFloat = 16
    var toggleTask: ((Int) -> Void)?
    @State private var folded: Set<String> = []
    @State private var loaded = false

    var body: some View {
        let blocks = MarkdownBlock.parse(source)
        VStack(alignment: .leading, spacing: size * 0.55) {
            ForEach(Array(visible(blocks).enumerated()), id: \.offset) { _, item in
                if case .heading(let level, let text, let key, _) = item.block, item.foldable {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { toggleFold(key) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: size * 0.6, weight: .bold))
                                .foregroundStyle(Palette.muted)
                                .rotationEffect(.degrees(folded.contains(key) ? 0 : 90))
                                .frame(width: size * 0.7)
                            headingText(level, text)
                            if folded.contains(key) { Text("⋯").font(.system(size: size, weight: .bold)).foregroundStyle(Palette.muted) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    BlockView(block: item.block, size: size, toggleTask: toggleTask)
                }
            }
        }
        .onAppear(perform: loadFolds)
    }

    private func headingText(_ level: Int, _ text: AttributedString) -> some View {
        Text(text)
            .font(.system(size: size + CGFloat(max(1, 7 - level)) * 1.6, weight: .bold))
            .foregroundStyle(Palette.heading(level))
            .padding(.top, level <= 2 ? size * 0.3 : 0)
    }

    private struct Visible {
        let block: MarkdownBlock
        let foldable: Bool
    }

    /// 顶层块里去掉收起的标题下面的内容。
    private func visible(_ blocks: [MarkdownBlock]) -> [Visible] {
        var result: [Visible] = []
        var index = 0
        while index < blocks.count {
            let block = blocks[index]
            index += 1
            guard case .heading(let level, _, let key, _) = block else { result.append(Visible(block: block, foldable: false)); continue }
            var end = index
            while end < blocks.count, (blocks[end].headingLevel ?? 7) > level { end += 1 }
            result.append(Visible(block: block, foldable: end > index))
            if end > index, folded.contains(key) { index = end }
        }
        return result
    }

    private var defaultsKey: String? { foldScope.map { "markdownFolds." + $0 } }

    private func loadFolds() {
        guard !loaded else { return }
        loaded = true
        if let defaultsKey { folded = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []) }
    }

    private func toggleFold(_ key: String) {
        if folded.contains(key) { folded.remove(key) } else { folded.insert(key) }
        if let defaultsKey { UserDefaults.standard.set(Array(folded), forKey: defaultsKey) }
    }
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

    struct Item {
        let checkbox: Bool?
        let line: Int
        let blocks: [MarkdownBlock]
    }

    var headingLevel: Int? {
        if case .heading(let level, _, _, _) = self { return level }
        return nil
    }

    private static var cache: [String: [MarkdownBlock]] = [:]

    static func parse(_ source: String) -> [MarkdownBlock] {
        if let cached = cache[source] { return cached }
        var seen: [String: Int] = [:]
        let result = blocks(Document(parsing: source), seen: &seen)
        if cache.count > 400 { cache.removeAll() }
        cache[source] = result
        return result
    }

    private static func blocks(_ node: Markup, seen: inout [String: Int]) -> [MarkdownBlock] {
        node.children.compactMap { block($0, seen: &seen) }
    }

    private static func block(_ node: Markup, seen: inout [String: Int]) -> MarkdownBlock? {
        switch node {
        case let heading as Heading:
            // 折叠键和 Mac 一样：级别 + 标题文字 + 同名标题的出现次序。
            let name = "h\(heading.level):\(heading.plainText.trimmingCharacters(in: .whitespaces))"
            let occurrence = seen[name, default: 0]
            seen[name] = occurrence + 1
            return .heading(heading.level, inline(heading), key: "\(name)#\(occurrence)", line: heading.range?.lowerBound.line ?? 0)
        case let paragraph as Paragraph:
            return .paragraph(inline(paragraph))
        case let list as OrderedList:
            return .list(items(list, seen: &seen), start: Int(list.startIndex))
        case let list as UnorderedList:
            return .list(items(list, seen: &seen), start: nil)
        case let quote as BlockQuote:
            return .quote(blocks(quote, seen: &seen))
        case let code as CodeBlock:
            return .code(language: code.language?.nilIfEmpty, code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code)
        case let table as Markdown.Table:
            let header = table.head.children.map { inline($0) }
            let rows = table.body.children.map { row in row.children.map { inline($0) } }
            return .table(header: header, rows: rows)
        case is ThematicBreak:
            return .rule
        case let html as HTMLBlock:
            return .html(html.rawHTML)
        default:
            let nested = blocks(node, seen: &seen)
            return nested.isEmpty ? nil : .quote(nested)
        }
    }

    private static func items(_ list: Markup, seen: inout [String: Int]) -> [Item] {
        list.children.compactMap { child in
            guard let item = child as? ListItem else { return nil }
            return Item(checkbox: item.checkbox.map { $0 == .checked }, line: item.range?.lowerBound.line ?? 0, blocks: blocks(item, seen: &seen))
        }
    }

    // MARK: 行内

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func inline(_ node: Markup) -> AttributedString {
        var result = AttributedString()
        for child in node.children { result += span(child, intent: []) }
        return detectLinks(result)
    }

    private static func span(_ node: Markup, intent: InlinePresentationIntent) -> AttributedString {
        if let text = node as? Markdown.Text { return styled(text.string, intent) }
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
        var value = AttributedString()
        for child in node.children { value += span(child, intent: childIntent) }
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
                  result[lower..<upper].link == nil else { continue }
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

    var body: some View {
        switch block {
        case .heading(let level, let text, _, _):
            Text(text)
                .font(.system(size: size + CGFloat(max(1, 7 - level)) * 1.6, weight: .bold))
                .foregroundStyle(Palette.heading(level))
        case .paragraph(let text):
            Text(text).font(.system(size: size)).foregroundStyle(Palette.ink).lineSpacing(size * 0.25)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let items, let start):
            VStack(alignment: .leading, spacing: size * 0.35) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(item, index: index, start: start)
                        VStack(alignment: .leading, spacing: size * 0.35) {
                            ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, child in
                                if item.checkbox == true, case .paragraph(let text) = child {
                                    Text(text).font(.system(size: size)).strikethrough().foregroundStyle(Palette.muted)
                                } else {
                                    BlockView(block: child, size: size, toggleTask: toggleTask)
                                }
                            }
                        }
                    }
                }
            }
        case .quote(let blocks):
            VStack(alignment: .leading, spacing: size * 0.4) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, child in BlockView(block: child, size: size, toggleTask: toggleTask) }
            }
            .opacity(0.8)
            .padding(.leading, 12)
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(Palette.line).frame(width: 3) }
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
        case .html(let text):
            Text(text).font(.system(size: size * 0.9, design: .monospaced)).foregroundStyle(Palette.muted)
        }
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
        Text(text)
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
                Text(language ?? "代码").font(.caption2.weight(.semibold)).foregroundStyle(Palette.muted)
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
                Text(code).font(.system(size: size * 0.82, design: .monospaced)).foregroundStyle(Palette.ink)
                    .padding(10)
            }
        }
        .background(Palette.muted.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
