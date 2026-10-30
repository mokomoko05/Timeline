import Foundation
import Combine
import Markdown

struct MarkdownFragment: Identifiable {
    let source: String
    let lineOffset: Int
    var id: Int { lineOffset }
}

struct MarkdownDisclosure: Identifiable {
    let id: Int
    let title: String
    let initiallyOpen: Bool
    let children: [MarkdownDisclosureNode]
}

struct MarkdownCodeFragment: Identifiable {
    let id: Int
    let language: String
    let content: String
}

indirect enum MarkdownDisclosureNode: Identifiable {
    case markdown(MarkdownFragment)
    case disclosure(MarkdownDisclosure)
    case code(MarkdownCodeFragment)

    var id: Int {
        switch self {
        case .markdown(let fragment): return fragment.id
        case .disclosure(let disclosure): return disclosure.id
        case .code(let code): return code.id
        }
    }
}

@MainActor
final class MarkdownDisclosureCache: ObservableObject {
    @Published private(set) var expanded: [Int: Bool] = [:]
    /// 绑定了工作板时，标题收起、折叠块展开都用工作板的折叠记忆（和工作板编辑器共用）。
    @Published private var foldRevision = 0
    private(set) var folds: [String: Bool] = [:]
    private(set) var layout = BoardFoldLayout("")
    private var boardID: UUID?
    private var observer: NSObjectProtocol?
    private var source: String?
    private var nodes: [MarkdownDisclosureNode] = []
    private var rendered: Set<Int> = []

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func parse(_ source: String) -> [MarkdownDisclosureNode] {
        if self.source != source {
            self.source = source
            nodes = MarkdownDisclosures.parse(source)
            layout = BoardFoldLayout(source)
        }
        return nodes
    }

    /// 跟随这块工作板的折叠记忆（在显示时调用；只读不发布变化，之后的变化由通知带来）。
    func bind(_ id: UUID) {
        guard boardID != id else { return }
        boardID = id
        folds = BoardFolds.load(id)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: .boardFoldsChanged, object: nil, queue: nil) { [weak self] note in
            guard note.userInfo?["board"] as? UUID == id else { return }
            MainActor.assumeIsolated {
                guard let self, self.boardID == id else { return }
                let folds = BoardFolds.load(id)
                guard folds != self.folds else { return }
                self.folds = folds
                self.foldRevision += 1
            }
        }
    }

    func isExpanded(_ disclosure: MarkdownDisclosure) -> Bool {
        if boardID != nil, let key = layout.disclosureKeys[disclosure.id] { return folds[key] ?? disclosure.initiallyOpen }
        return expanded[disclosure.id] ?? disclosure.initiallyOpen
    }

    func toggle(_ disclosure: MarkdownDisclosure) {
        rendered.insert(disclosure.id)
        let open = !isExpanded(disclosure)
        if let boardID, let key = layout.disclosureKeys[disclosure.id] {
            folds[key] = open
            foldRevision += 1
            BoardFolds.set(key, open, board: boardID)
        } else {
            expanded[disclosure.id] = open
        }
    }

    /// 收起 / 展开标题（只在绑定了工作板时有用）。
    func toggleHeading(_ key: String) {
        guard let boardID else { return }
        let folded = folds[key] != true
        if folded { folds[key] = true } else { folds.removeValue(forKey: key) }
        foldRevision += 1
        BoardFolds.set(key, folded, board: boardID)
    }

    func hasRendered(_ disclosure: MarkdownDisclosure) -> Bool { isExpanded(disclosure) || rendered.contains(disclosure.id) }
}

extension Notification.Name {
    /// 某块工作板的折叠记忆变了（userInfo["board"] 是工作板的 UUID）。
    static let boardFoldsChanged = Notification.Name("TimelineBoardFoldsChanged")
}

/// 工作板的折叠记忆：标题收起（"h…" → true）、折叠块展开 / 收起（"d…" → true / false），按工作板存进偏好。
/// 工作板编辑器和笔记里的看板内容共用这一份，一边改了另一边跟着变。
@MainActor
enum BoardFolds {
    static var defaults: UserDefaults = .standard

    static func key(_ id: UUID) -> String { "board.folds.\(id.uuidString)" }

    static func load(_ id: UUID, defaults: UserDefaults? = nil) -> [String: Bool] {
        (defaults ?? Self.defaults).dictionary(forKey: key(id)) as? [String: Bool] ?? [:]
    }

    static func set(_ fold: String, _ value: Bool, board id: UUID, defaults: UserDefaults? = nil) {
        let defaults = defaults ?? Self.defaults
        var folds = load(id, defaults: defaults)
        folds[fold] = value
        // 只记和默认不同的：标题默认展开；折叠块的默认由 open 属性决定，两种都存下来以免默认值变化。
        if fold.hasPrefix("h"), !value { folds.removeValue(forKey: fold) }
        defaults.set(folds, forKey: key(id))
        NotificationCenter.default.post(name: .boardFoldsChanged, object: nil, userInfo: ["board": id])
    }
}

enum MarkdownDisclosures {
    fileprivate struct Opening {
        let title: String
        /// 折叠记忆里用的名字：和编辑器一致，不随界面语言变。
        let foldName: String
        let initiallyOpen: Bool
        let bodyStart: Int
    }

    private static let opening = try! NSRegularExpression(pattern: #"^<details(?:\s+(open)(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?)?\s*>\s*(?:<summary\s*>(.*?)</summary\s*>)?\s*$"#, options: [.caseInsensitive])
    private static let summary = try! NSRegularExpression(pattern: #"^<summary\s*>(.*?)</summary\s*>\s*$"#, options: [.caseInsensitive])

    /// 逐行找出折叠块的开头、结尾（代码块里的不算），和代码块占的行。
    fileprivate static func scan(_ lines: [String]) -> (openings: [Int: Opening], closingLines: [Int: Int], codeLines: Set<Int>) {
        var openings: [Int: Opening] = [:]
        var closingLines: [Int: Int] = [:]
        var codeLines: Set<Int> = []
        var stack: [Int] = []
        var fence: (marker: Character, length: Int)?
        for index in lines.indices {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let indentation = raw.prefix { $0 == " " || $0 == "\t" }
            let indented = indentation.contains("\t") || indentation.count > 3
            if let active = fence {
                codeLines.insert(index)
                let run = line.prefix { $0 == active.marker }
                if run.count >= active.length && line.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                }
                continue
            }
            if !indented, let marker = line.first, marker == "\u{60}" || marker == "~" {
                let run = line.prefix { $0 == marker }
                if run.count >= 3 {
                    fence = (marker, run.count)
                    codeLines.insert(index)
                    continue
                }
            }
            guard !indented else { continue }
            let text = line as NSString
            if let match = opening.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) {
                var title: String?
                var bodyStart = index + 1
                if match.range(at: 2).location != NSNotFound {
                    title = text.substring(with: match.range(at: 2))
                } else {
                    var next = index + 1
                    while next < lines.count && lines[next].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { next += 1 }
                    if next < lines.count {
                        let candidate = lines[next].trimmingCharacters(in: .whitespacesAndNewlines) as NSString
                        if let match = summary.firstMatch(in: candidate as String, range: NSRange(location: 0, length: candidate.length)) {
                            title = candidate.substring(with: match.range(at: 1))
                            bodyStart = next + 1
                        }
                    }
                }
                let decoded = decodeTitle(title ?? "")
                openings[index] = Opening(title: decoded.isEmpty ? AppLocalized("折叠内容") : decoded,
                                          foldName: decoded.isEmpty ? "折叠内容" : decoded,
                                          initiallyOpen: match.range(at: 1).location != NSNotFound,
                                          bodyStart: bodyStart)
                stack.append(index)
            } else if line.lowercased() == "</details>", let start = stack.popLast() {
                closingLines[start] = index
            }
        }
        return (openings, closingLines, codeLines)
    }

    static func parse(_ source: String) -> [MarkdownDisclosureNode] {
        let lines = source.components(separatedBy: "\n")
        let (openings, closingLines, _) = scan(lines)

        func nodes(in range: Range<Int>) -> [MarkdownDisclosureNode] {
            var result: [MarkdownDisclosureNode] = []
            var plainStart = range.lowerBound
            var index = range.lowerBound
            func appendPlain(until end: Int) {
                guard plainStart < end else { return }
                let text = lines[plainStart..<end].joined(separator: "\n")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Use CommonMark ranges so fenced / indented code remains literal, including
                    // HTML examples. Preserve absolute line offsets for tasks after each code block.
                    let document = Document(parsing: text)
                    var cursor = plainStart
                    for child in document.children {
                        guard let code = child as? CodeBlock, let range = code.range else { continue }
                        let start = plainStart + range.lowerBound.line - 1
                        let after = min(end, plainStart + range.upperBound.line)
                        if cursor < start {
                            let before = lines[cursor..<start].joined(separator: "\n")
                            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                result.append(.markdown(MarkdownFragment(source: before, lineOffset: cursor)))
                            }
                        }
                        result.append(.code(MarkdownCodeFragment(id: start, language: code.language ?? "", content: code.code)))
                        cursor = after
                    }
                    if cursor < end {
                        let remaining = lines[cursor..<end].joined(separator: "\n")
                        if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            result.append(.markdown(MarkdownFragment(source: remaining, lineOffset: cursor)))
                        }
                    }
                }
            }
            while index < range.upperBound {
                if let opening = openings[index], let end = closingLines[index], end < range.upperBound {
                    appendPlain(until: index)
                    result.append(.disclosure(MarkdownDisclosure(id: index, title: opening.title,
                                                                initiallyOpen: opening.initiallyOpen,
                                                                children: nodes(in: opening.bodyStart..<end))))
                    index = end + 1
                    plainStart = index
                } else {
                    index += 1
                }
            }
            appendPlain(until: range.upperBound)
            return result
        }
        return nodes(in: lines.indices)
    }

    fileprivate static func decodeTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 工作板正文里可以折叠的标题和折叠块，算法和编辑器（Editor/src/editor.js 的 parseHeadings / parseDetails）一致，
/// 折叠记忆的键也一样，所以笔记里的看板内容和工作板显示同样的收起 / 展开。行号从 0 开始。
struct BoardFoldLayout: Equatable {
    struct Heading: Equatable {
        let line: Int
        let level: Int
        let key: String
        /// 收起时藏到哪一行（含）；末尾的空行不藏，和下一个标题之间仍有间隔。
        let lastLine: Int
    }

    /// 有内容可收起的标题。
    let headings: [Heading]
    /// 折叠块开头那一行 → 折叠记忆的键。
    let disclosureKeys: [Int: String]

    private static let atxHeading = try! NSRegularExpression(pattern: #"^[ \t]{0,3}(#{1,6})(?:[ \t]|$)"#)
    private static let headingMarks = try! NSRegularExpression(pattern: #"^\s{0,3}#{1,6}\s*"#)
    private static let closingMarks = try! NSRegularExpression(pattern: #"\s+#+\s*$"#)
    private static let htmlBlock = try! NSRegularExpression(pattern: #"^[ ]{0,3}</?[A-Za-z]"#)
    private static let quoteMarks = try! NSRegularExpression(pattern: #"^(?:[ ]{0,3}>[ ]?)+"#)
    private static let fence = try! NSRegularExpression(pattern: #"^[ ]{0,3}(?:`{3,}|~{3,})"#)

    /// 引用的层数和去掉 `>` 之后的文字（行内 lazy continuation 属于上一段，收起时跟着那一段走，这里不用算）。
    private static func unquote(_ raw: String) -> (depth: Int, text: String) {
        let range = NSRange(location: 0, length: (raw as NSString).length)
        guard let match = quoteMarks.firstMatch(in: raw, range: range) else { return (0, raw) }
        let marks = (raw as NSString).substring(with: match.range)
        return (marks.filter { $0 == ">" }.count, (raw as NSString).substring(from: match.range.length))
    }

    init(_ source: String) {
        let lines = source.components(separatedBy: "\n")
        let (openings, closingLines, codeLines) = MarkdownDisclosures.scan(lines)
        var keys: [Int: String] = [:]
        var seenDisclosures: [String: Int] = [:]
        for start in openings.keys.sorted() {
            guard let opening = openings[start] else { continue }
            let occurrence = seenDisclosures[opening.foldName, default: 0]
            seenDisclosures[opening.foldName] = occurrence + 1
            keys[start] = "d:\(opening.foldName)#\(occurrence)"
        }
        disclosureKeys = keys
        let containers = closingLines.map { (open: $0.key, close: $0.value) }

        struct Found { let line: Int; let level: Int; let key: String; let container: Int?; let quote: ClosedRange<Int>? }
        var found: [Found] = []
        var seen: [String: Int] = [:]
        var inHTML = false
        var quotedFence = false
        let depths = lines.map { Self.unquote($0).depth }
        for (index, raw) in lines.enumerated() where !codeLines.contains(index) {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { inHTML = false; continue }
            let range = NSRange(location: 0, length: (raw as NSString).length)
            // 和 Markdown 解析一致：HTML 块（比如 <details> 开头的几行）一直到空行为止，里面的 # 不是标题。
            if inHTML { continue }
            if Self.htmlBlock.firstMatch(in: raw, range: range) != nil { inHTML = true; continue }
            let (depth, body) = Self.unquote(raw)
            let bodyRange = NSRange(location: 0, length: (body as NSString).length)
            // 引用里的代码块（`MarkdownDisclosures.scan` 只认顶层的围栏）：里面的 # 不是标题。
            if depth == 0 { quotedFence = false }
            else if Self.fence.firstMatch(in: body, range: bodyRange) != nil { quotedFence.toggle(); continue }
            if quotedFence { continue }
            guard let match = Self.atxHeading.firstMatch(in: body, range: bodyRange) else { continue }
            var text = Self.headingMarks.stringByReplacingMatches(in: body, range: bodyRange, withTemplate: "")
            text = Self.closingMarks.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
            let level = match.range(at: 1).length
            let name = "h\(level):\(text.trimmingCharacters(in: .whitespacesAndNewlines))"
            let occurrence = seen[name, default: 0]
            seen[name] = occurrence + 1
            let container = containers.filter { $0.open < index && index < $0.close }.max { $0.open < $1.open }?.open
            var quote: ClosedRange<Int>?
            if depth > 0 {
                var start = index, end = index
                while start > 0, depths[start - 1] >= depth { start -= 1 }
                while end + 1 < lines.count, depths[end + 1] >= depth { end += 1 }
                quote = start...end
            }
            found.append(Found(line: index, level: level, key: "\(name)#\(occurrence)", container: container, quote: quote))
        }
        var result: [Heading] = []
        for (position, heading) in found.enumerated() {
            var boundary = heading.quote.map { $0.upperBound + 1 } ?? heading.container.flatMap { closingLines[$0] } ?? lines.count
            if let next = found[(position + 1)...].first(where: { $0.container == heading.container && $0.quote == heading.quote && $0.level <= heading.level }),
               next.line < boundary { boundary = next.line }
            var last = boundary - 1
            let blank = heading.quote == nil ? CharacterSet.whitespaces : CharacterSet.whitespaces.union(CharacterSet(charactersIn: ">"))
            while last > heading.line && lines[last].trimmingCharacters(in: blank).isEmpty { last -= 1 }
            if last > heading.line { result.append(Heading(line: heading.line, level: heading.level, key: heading.key, lastLine: last)) }
        }
        headings = result
    }

    /// 按折叠记忆收起后藏起来的行（含两端）。
    func hiddenRanges(_ folds: [String: Bool]) -> [ClosedRange<Int>] {
        headings.filter { folds[$0.key] == true }.map { ($0.line + 1)...$0.lastLine }
    }
}
