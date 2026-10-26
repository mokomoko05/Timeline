import Foundation

/// 一次编辑：把 `range` 换成 `replacement`，之后选中 `selection`。范围都按 UTF-16 计（和 UITextView / NSTextView 一致）。
public struct MarkdownEdit: Equatable {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    /// 应用到一段文字上（测试和不经过文本框的地方用）。
    public func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}

/// 写 Markdown 源码时的格式操作：工具栏上的加粗、列表、标题……，以及回车时自动续上列表。
/// 都是纯文字变换，返回一次替换，交给文本框执行（这样系统的撤销照常可用）。
public enum MarkdownEditing {
    public enum LineStyle: CaseIterable {
        case bullet, task, numbered, quote

        func marker(index: Int) -> String {
            switch self {
            case .bullet: return "- "
            case .task: return "- [ ] "
            case .numbered: return "\(index + 1). "
            case .quote: return "> "
            }
        }
    }

    /// 行首的缩进和已有的列表 / 引用记号。
    private static let prefix = try! NSRegularExpression(pattern: #"^([ \t]*)([-+*] \[[ xX]\] |[-+*] |\d+[.)] |> ?)?"#)
    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6}) "#)

    /// 选中范围覆盖的整行（不含最后的换行）和每一行。
    private static func lines(in text: NSString, selection: NSRange) -> (range: NSRange, lines: [String]) {
        var range = text.lineRange(for: NSRange(location: selection.location, length: selection.length))
        // 选区正好停在下一行行首时，不算那一行。
        if selection.length > 0, selection.location + selection.length == range.location + range.length, range.length > 0 {
            let last = text.lineRange(for: NSRange(location: max(selection.location, selection.location + selection.length - 1), length: 0))
            range = NSRange(location: range.location, length: last.location + last.length - range.location)
        }
        let body = text.substring(with: range)
        let trimmed = body.hasSuffix("\n") ? String(body.dropLast()) : body
        return (NSRange(location: range.location, length: (trimmed as NSString).length), trimmed.components(separatedBy: "\n"))
    }

    private static func style(of marker: String) -> LineStyle? {
        if marker.hasPrefix(">") { return .quote }
        if marker.contains("[") { return .task }
        if marker.first?.isNumber == true { return .numbered }
        return marker.isEmpty ? nil : .bullet
    }

    private static func split(_ line: String) -> (indent: String, marker: String, rest: String) {
        let ns = line as NSString
        guard let match = prefix.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return ("", "", line) }
        let indent = ns.substring(with: match.range(at: 1))
        let marker = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
        return (indent, marker, ns.substring(from: match.range.length))
    }

    /// 把选中的各行设成 / 取消某种列表（所有非空行都已经是这种时取消）。
    public static func toggle(_ style: LineStyle, in text: String, selection: NSRange) -> MarkdownEdit {
        let ns = text as NSString
        let (range, lines) = lines(in: ns, selection: selection)
        let parts = lines.map(split)
        let content = parts.enumerated().filter { !$0.element.rest.isEmpty || !$0.element.marker.isEmpty || lines.count == 1 }
        let removing = !content.isEmpty && content.allSatisfy { Self.style(of: $0.element.marker) == style }
        var index = 0
        let updated = parts.enumerated().map { offset, part -> String in
            guard lines.count == 1 || !part.rest.isEmpty || !part.marker.isEmpty else { return lines[offset] }
            if removing { return part.indent + part.rest }
            defer { index += 1 }
            return part.indent + style.marker(index: index) + part.rest
        }
        return replacing(range, of: ns, with: updated, selection: selection)
    }

    /// 标题一级一级加：正文 → # → ## → ### → 正文。只看选区的第一行。
    public static func cycleHeading(in text: String, selection: NSRange) -> MarkdownEdit {
        let ns = text as NSString
        let line = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        var content = ns.substring(with: line)
        if content.hasSuffix("\n") { content.removeLast() }
        let contentNS = content as NSString
        var level = 0
        var body = content
        if let match = heading.firstMatch(in: content, range: NSRange(location: 0, length: contentNS.length)) {
            level = match.range(at: 1).length
            body = contentNS.substring(from: match.range.length)
        }
        let next = level >= 3 ? 0 : level + 1
        let updated = (next == 0 ? "" : String(repeating: "#", count: next) + " ") + body
        let range = NSRange(location: line.location, length: contentNS.length)
        return replacing(range, of: ns, with: [updated], selection: selection)
    }

    /// 加粗、斜体、行内代码：选中的文字两边加上 / 去掉记号；没选文字就放一对记号，光标停在中间。
    public static func wrap(_ marker: String, in text: String, selection: NSRange) -> MarkdownEdit {
        let ns = text as NSString
        let length = (marker as NSString).length
        let selected = ns.substring(with: selection)
        // 选中的文字自己带着记号：去掉。
        if selected.count >= 2 * marker.count, selected.hasPrefix(marker), selected.hasSuffix(marker),
           !(marker == "*" && selected.hasPrefix("**") && !selected.hasPrefix("***")) {
            let inner = (selected as NSString).substring(with: NSRange(location: length, length: (selected as NSString).length - 2 * length))
            return MarkdownEdit(range: selection, replacement: inner, selection: NSRange(location: selection.location, length: (inner as NSString).length))
        }
        // 记号在选区外面：去掉。
        if selection.location >= length, selection.location + selection.length + length <= ns.length,
           ns.substring(with: NSRange(location: selection.location - length, length: length)) == marker,
           ns.substring(with: NSRange(location: selection.location + selection.length, length: length)) == marker,
           !(marker == "*" && isBoldBoundary(ns, before: selection.location - length, after: selection.location + selection.length + length)) {
            let outer = NSRange(location: selection.location - length, length: selection.length + 2 * length)
            return MarkdownEdit(range: outer, replacement: selected, selection: NSRange(location: outer.location, length: selection.length))
        }
        return MarkdownEdit(range: selection, replacement: marker + selected + marker,
                            selection: NSRange(location: selection.location + length, length: selection.length))
    }

    /// `*` 两边又各挨着一个 `*`：那是加粗的记号，斜体不去动它。
    private static func isBoldBoundary(_ text: NSString, before: Int, after: Int) -> Bool {
        (before > 0 && text.character(at: before - 1) == 42) || (after < text.length && text.character(at: after) == 42)
    }

    /// 链接：选中的是网址就放进括号、光标停在方括号里写名字；否则选中的当名字，光标停在括号里填网址。
    public static func link(in text: String, selection: NSRange) -> MarkdownEdit {
        let selected = (text as NSString).substring(with: selection)
        let trimmed = selected.trimmingCharacters(in: .whitespaces)
        if trimmed.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://\S+$"#, options: .regularExpression) != nil {
            return MarkdownEdit(range: selection, replacement: "[](\(trimmed))", selection: NSRange(location: selection.location + 1, length: 0))
        }
        let replacement = "[\(selected)]()"
        let caret = selection.location + (replacement as NSString).length - 1
        return MarkdownEdit(range: selection, replacement: replacement,
                            selection: NSRange(location: selected.isEmpty ? selection.location + 1 : caret, length: 0))
    }

    /// 缩进 / 取消缩进：选中的各行行首加两个空格，或去掉最多两个空格（或一个制表符）。
    public static func indent(in text: String, selection: NSRange, outdent: Bool = false) -> MarkdownEdit {
        let ns = text as NSString
        let (range, lines) = lines(in: ns, selection: selection)
        let updated = lines.map { line -> String in
            guard outdent else { return "  " + line }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            return String(line.dropFirst(line.prefix(2).prefix { $0 == " " }.count))
        }
        return replacing(range, of: ns, with: updated, selection: selection)
    }

    /// 在列表项里按回车：下一行续上同样的记号（编号加一，勾选框是空的）；空的列表项按回车就结束列表。
    /// 不在列表里返回 nil，照常换行。
    public static func newline(in text: String, at location: Int) -> MarkdownEdit? {
        let ns = text as NSString
        let line = ns.lineRange(for: NSRange(location: location, length: 0))
        let before = ns.substring(with: NSRange(location: line.location, length: location - line.location))
        let part = split(before)
        guard let style = style(of: part.marker) else { return nil }
        let after = ns.substring(with: NSRange(location: location, length: line.location + line.length - location))
            .trimmingCharacters(in: .newlines)
        if part.rest.trimmingCharacters(in: .whitespaces).isEmpty && after.trimmingCharacters(in: .whitespaces).isEmpty {
            // 空的列表项：去掉记号，留下一个空行。
            let range = NSRange(location: line.location, length: location - line.location)
            return MarkdownEdit(range: range, replacement: part.indent, selection: NSRange(location: line.location + (part.indent as NSString).length, length: 0))
        }
        var marker: String
        switch style {
        case .numbered:
            let digits = part.marker.prefix { $0.isNumber }
            let number = (Int(digits) ?? 0) + 1
            marker = "\(number)" + String(part.marker.dropFirst(digits.count))
        case .task: marker = String(part.marker.prefix(2)) + "[ ] "
        default: marker = part.marker
        }
        if style == .quote, !marker.hasSuffix(" ") { marker += " " }
        let insertion = "\n" + part.indent + marker
        return MarkdownEdit(range: NSRange(location: location, length: 0), replacement: insertion,
                            selection: NSRange(location: location + (insertion as NSString).length, length: 0))
    }

    /// 换掉 `range` 里的几行；单个光标跟着所在那一行移动，否则选中改过的整段。
    private static func replacing(_ range: NSRange, of text: NSString, with lines: [String], selection: NSRange) -> MarkdownEdit {
        let replacement = lines.joined(separator: "\n")
        let newLength = (replacement as NSString).length
        if selection.length == 0, lines.count == 1 {
            let oldLine = text.substring(with: range)
            let delta = newLength - (oldLine as NSString).length
            // 光标在行首记号里时放到记号后面，否则跟着文字走。
            let offset = selection.location - range.location
            let newOffset = max(0, min(newLength, offset + delta))
            return MarkdownEdit(range: range, replacement: replacement, selection: NSRange(location: range.location + newOffset, length: 0))
        }
        return MarkdownEdit(range: range, replacement: replacement, selection: NSRange(location: range.location, length: newLength))
    }
}
