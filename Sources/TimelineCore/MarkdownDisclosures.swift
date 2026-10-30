import Foundation

/// 正文里的 `<details>` 折叠块：怎么认、折叠记忆的键是什么。Mac、iOS 和编辑器（Editor/src/editor.js 的 parseDetails）算法一致。
public enum MarkdownDisclosures {
    public struct Opening {
        public let title: String
        /// 折叠记忆里用的名字：和编辑器一致，不随界面语言变。
        public let foldName: String
        public let initiallyOpen: Bool
        public let bodyStart: Int
    }

    private static let opening = try! NSRegularExpression(pattern: #"^<details(?:\s+(open)(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?)?\s*>\s*(?:<summary\s*>(.*?)</summary\s*>)?\s*$"#, options: [.caseInsensitive])
    private static let summary = try! NSRegularExpression(pattern: #"^<summary\s*>(.*?)</summary\s*>\s*$"#, options: [.caseInsensitive])

    /// 逐行找出折叠块的开头、结尾（代码块里的不算），和代码块占的行。
    public static func scan(_ lines: [String], untitled: String = "折叠内容") -> (openings: [Int: Opening], closingLines: [Int: Int], codeLines: Set<Int>) {
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
                openings[index] = Opening(title: decoded.isEmpty ? untitled : decoded,
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

    /// 正文里配好对的折叠块（行号从 1 开始，和解析结果的行号一致；键和工作板、编辑器的折叠记忆一样）。
    public struct Span {
        public let line: Int
        public let bodyStart: Int
        public let closing: Int
        public let key: String
        public let title: String
        public let initiallyOpen: Bool
    }

    /// `untitled` 是没写标题时显示的文字（键里仍用不随语言变的名字）。
    public static func spans(_ lines: [String], untitled: String = "折叠内容") -> [Span] {
        let (openings, closingLines, _) = scan(lines, untitled: untitled)
        var seen: [String: Int] = [:]
        return openings.keys.sorted().compactMap { start in
            guard let opening = openings[start] else { return nil }
            let occurrence = seen[opening.foldName, default: 0]
            seen[opening.foldName] = occurrence + 1
            guard let closing = closingLines[start] else { return nil }
            return Span(line: start + 1, bodyStart: opening.bodyStart + 1, closing: closing + 1, key: "d:\(opening.foldName)#\(occurrence)",
                        title: opening.title, initiallyOpen: opening.initiallyOpen)
        }
    }

    private static func decodeTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 正文的折叠记忆（一组字符串）：标题的记录就是键，有它表示收起；
/// 折叠块的记录是 "d:名字#序号=open"（或 "=closed"），编辑器旧版存的没有后缀，表示展开。
public enum FoldRecords {
    private static func disclosureState(_ item: String) -> (name: String, open: Bool)? {
        guard item.hasPrefix("d:") else { return nil }
        if item.hasSuffix("=open") { return (String(item.dropLast(5)), true) }
        if item.hasSuffix("=closed") { return (String(item.dropLast(7)), false) }
        return (item, true)
    }

    /// 给编辑器的折叠记忆：标题和展开的折叠块是 true，明确收起的折叠块是 false（`<details open>` 收起后要记得住）。
    public static func editorFolds(_ records: some Sequence<String>) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for item in records {
            if let state = disclosureState(item) { result[state.name] = state.open } else { result[item] = true }
        }
        return result
    }

    /// 折叠块现在是否展开：没有记录时看它自己的 `open` 属性。
    public static func isOpen(_ key: String, initially: Bool, in records: Set<String>) -> Bool {
        if records.contains(key + "=closed") { return false }
        return records.contains(key + "=open") || records.contains(key) || initially
    }

    /// 编辑器发来的折叠变化：折叠块的 `value` 是展开，标题的 `value` 是收起。
    public static func set(_ key: String, value: Bool, in records: inout Set<String>) {
        if key.hasPrefix("d:") {
            records.subtract([key, key + "=open", key + "=closed"])
            records.insert(key + (value ? "=open" : "=closed"))
        } else if value {
            records.insert(key)
        } else {
            records.remove(key)
        }
    }

    /// 带着目标状态的折叠块记录（"…=open" / "…=closed"）：拆成键和展开与否；其他记录返回 nil。
    public static func disclosureTarget(_ item: String) -> (name: String, open: Bool)? { disclosureState(item) }
}
