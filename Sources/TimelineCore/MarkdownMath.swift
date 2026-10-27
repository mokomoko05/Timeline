import Foundation

/// Markdown 里的公式：`$…$`、`\(…\)` 是行内公式，`$$…$$`、`\[…\]` 是独立公式。
///
/// CommonMark 不认识公式：`\\`、`\{` 会被当成转义吃掉，`*`、`_`、`|` 会被当成强调和表格。
/// 所以先把公式从原文里取出来，换成私用区字符组成的占位符再交给解析器，排版时再把占位符换回公式。
/// 占位符保留原文的行数（公式跨几行，占位符也占几行），任务勾选、标题折叠用的行号不变。
/// 代码块、行内代码里的 `$` 原样保留；`\$` 是普通的美元符号。
public enum MarkdownMath {
    public struct Formula: Hashable, Sendable {
        public let latex: String
        public let display: Bool

        public init(latex: String, display: Bool) {
            self.latex = latex
            self.display = display
        }

        /// 公式排不出来时显示的原文。
        public var source: String { display ? "$$\(latex)$$" : "$\(latex)$" }
    }

    public struct Extracted: Sendable {
        public let source: String
        public let formulas: [Formula]
    }

    /// 文本中的一段：普通文字或者一个公式。
    public enum Piece: Equatable, Sendable {
        case text(String)
        case formula(Formula)
    }

    static let inlineMark: Character = "\u{E000}"
    static let displayMark: Character = "\u{E001}"
    static let endMark: Character = "\u{E002}"
    /// 公式跨行时，第二行起每行只剩这个字符（保留行数）；排版时连同前面的换行一起去掉。
    public static let continuation: Character = "\u{E003}"

    /// 原文里可能有公式。没有 `$`、`\(`、`\[` 的正文直接跳过，不用逐字扫描。
    public static func mayContainMath(_ source: String) -> Bool {
        source.contains("$") || source.contains("\\(") || source.contains("\\[")
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Extracted] = [:]

    public static func extract(_ source: String) -> Extracted {
        guard mayContainMath(source) else { return Extracted(source: source, formulas: []) }
        cacheLock.lock()
        let cached = cache[source]
        cacheLock.unlock()
        if let cached { return cached }
        let result = scan(source)
        cacheLock.lock()
        if cache.count > 400 { cache.removeAll() }
        cache[source] = result
        cacheLock.unlock()
        return result
    }

    /// 把一段文字（解析器给出的文本节点）按占位符切开。跨行留下的续行字符直接去掉。
    public static func pieces(_ text: String, formulas: [Formula]) -> [Piece] {
        guard !formulas.isEmpty || text.contains(continuation),
              text.contains(where: { $0 == inlineMark || $0 == displayMark || $0 == continuation }) else { return [.text(text)] }
        var result: [Piece] = []
        var buffer = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == continuation { index = text.index(after: index); continue }
            if character == inlineMark || character == displayMark,
               let end = text[index...].firstIndex(of: endMark),
               let number = Int(text[text.index(after: index)..<end]), formulas.indices.contains(number) {
                if !buffer.isEmpty { result.append(.text(buffer)); buffer = "" }
                result.append(.formula(formulas[number]))
                index = text.index(after: end)
                continue
            }
            buffer.append(character)
            index = text.index(after: index)
        }
        if !buffer.isEmpty { result.append(.text(buffer)) }
        return result
    }

    /// 占位符里只有私用区字符和数字，换回原文：解析器不认识的地方（比如标题的折叠键）用得上。
    public static func restore(_ text: String, formulas: [Formula]) -> String {
        pieces(text, formulas: formulas).map {
            switch $0 {
            case .text(let value): value
            case .formula(let formula): formula.source
            }
        }.joined()
    }

    // MARK: 扫描

    private static func scan(_ source: String) -> Extracted {
        let lines = source.components(separatedBy: "\n")
        var formulas: [Formula] = []
        var output: [String] = []
        output.reserveCapacity(lines.count)
        var fence: (character: Character, count: Int)?
        var lineIndex = 0
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            if let open = fence {
                if closesFence(line, open) { fence = nil }
                output.append(line)
                lineIndex += 1
                continue
            }
            if let opening = opensFence(line) {
                fence = opening
                output.append(line)
                lineIndex += 1
                continue
            }
            let (text, consumed) = scanLine(lines, from: lineIndex, formulas: &formulas)
            output.append(contentsOf: text)
            lineIndex += consumed
        }
        return Extracted(source: output.joined(separator: "\n"), formulas: formulas)
    }

    private static func opensFence(_ line: String) -> (Character, Int)? {
        let trimmed = line.drop { $0 == " " || $0 == ">" }
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        if first == "`", trimmed.dropFirst(count).contains("`") { return nil }
        return (first, count)
    }

    private static func closesFence(_ line: String, _ fence: (character: Character, count: Int)) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == ">" }
        let count = trimmed.prefix { $0 == fence.character }.count
        return count >= fence.count && trimmed.dropFirst(count).allSatisfy(\.isWhitespace)
    }

    /// 行首的缩进和引用符号：公式跨行时，后面几行的这一段不算公式内容，原样留着（列表、引用里的公式）。
    private static func linePrefix(_ line: Substring) -> Substring {
        line.prefix { $0 == " " || $0 == "\t" || $0 == ">" }
    }

    /// 从第 `start` 行开始扫一行；遇到跨行的独立公式时连带吃掉后面几行。返回替换后的各行和吃掉的行数。
    private static func scanLine(_ lines: [String], from start: Int, formulas: inout [Formula]) -> ([String], Int) {
        let characters = Array(lines[start])
        guard characters.contains(where: { $0 == "$" || $0 == "\\" }) else { return ([lines[start]], 1) }
        var result: [String] = []
        var current = ""
        var index = 0
        var lineIndex = start
        var chars = characters

        func emit(_ formula: Formula, display: Bool) {
            current.append(display ? displayMark : inlineMark)
            current += String(formulas.count)
            current.append(endMark)
            formulas.append(formula)
        }

        while index < chars.count {
            let character = chars[index]
            // 行内代码：同样长度的反引号之间原样保留。
            if character == "`" {
                let run = chars[index...].prefix { $0 == "`" }.count
                if let close = findBackticks(chars, from: index + run, count: run) {
                    current += String(chars[index..<close + run])
                    index = close + run
                } else {
                    current += String(repeating: "`", count: run)
                    index += run
                }
                continue
            }
            if character == "\\", index + 1 < chars.count {
                let next = chars[index + 1]
                if next == "[" || next == "(" {
                    let closer: [Character] = next == "[" ? ["\\", "]"] : ["\\", ")"]
                    let display = next == "["
                    if let found = findCloser(lines, line: lineIndex, chars: chars, from: index + 2, closer: closer, multiline: display) {
                        emit(Formula(latex: found.latex.trimmingCharacters(in: .whitespacesAndNewlines), display: display), display: display)
                        appendContinuations(found, lines: lines, current: &current, result: &result, lineIndex: &lineIndex, chars: &chars, index: &index)
                        continue
                    }
                }
                current.append(character)
                current.append(next)
                index += 2
                continue
            }
            if character == "$" {
                if index + 1 < chars.count, chars[index + 1] == "$" {
                    if let found = findCloser(lines, line: lineIndex, chars: chars, from: index + 2, closer: ["$", "$"], multiline: true),
                       !found.latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        emit(Formula(latex: found.latex.trimmingCharacters(in: .whitespacesAndNewlines), display: true), display: true)
                        appendContinuations(found, lines: lines, current: &current, result: &result, lineIndex: &lineIndex, chars: &chars, index: &index)
                        continue
                    }
                    current += "$$"
                    index += 2
                    continue
                }
                // 行内公式：$ 后面紧跟非空白，结束的 $ 前面不是空白、后面不是数字（「$5 到 $10」不算公式）。
                if index + 1 < chars.count, !chars[index + 1].isWhitespace,
                   let close = findInlineDollar(chars, from: index + 1) {
                    emit(Formula(latex: String(chars[index + 1..<close]), display: false), display: false)
                    index = close + 1
                    continue
                }
            }
            current.append(character)
            index += 1
        }
        result.append(current)
        return (result, lineIndex - start + 1)
    }

    private struct Found {
        let latex: String
        /// 结束符所在的行（相对开始行）和结束符之后的位置。
        let lineOffset: Int
        let after: Int
        let endChars: [Character]
    }

    private static func findBackticks(_ chars: [Character], from start: Int, count: Int) -> Int? {
        var index = start
        while index < chars.count {
            if chars[index] == "`" {
                let run = chars[index...].prefix { $0 == "`" }.count
                if run == count { return index }
                index += run
            } else {
                index += 1
            }
        }
        return nil
    }

    private static func findInlineDollar(_ chars: [Character], from start: Int) -> Int? {
        var index = start
        while index < chars.count {
            let character = chars[index]
            if character == "\\" { index += 2; continue }
            if character == "$" {
                if index + 1 < chars.count, chars[index + 1] == "$" { return nil }
                guard !chars[index - 1].isWhitespace else { return nil }
                if index + 1 < chars.count, chars[index + 1].isNumber { return nil }
                return index > start ? index : nil
            }
            index += 1
        }
        return nil
    }

    /// 找结束符。独立公式可以跨行（最多 200 行），途中遇到代码围栏就放弃。
    private static func findCloser(_ lines: [String], line: Int, chars: [Character], from start: Int, closer: [Character], multiline: Bool) -> Found? {
        var latex = ""
        var current = chars
        var index = start
        var offset = 0
        while true {
            while index < current.count {
                if current[index] == "\\", index + 1 < current.count, closer[0] != "\\" || current[index + 1] != closer[1] {
                    latex.append(current[index])
                    latex.append(current[index + 1])
                    index += 2
                    continue
                }
                if index + closer.count <= current.count, Array(current[index..<index + closer.count]) == closer {
                    return Found(latex: latex, lineOffset: offset, after: index + closer.count, endChars: current)
                }
                latex.append(current[index])
                index += 1
            }
            offset += 1
            guard multiline, offset < 200, line + offset < lines.count else { return nil }
            let next = lines[line + offset]
            if opensFence(next) != nil { return nil }
            let prefix = linePrefix(next[...])
            latex.append("\n")
            current = Array(next)
            index = prefix.count
        }
    }

    /// 公式跨行时：后面每一行留下行首缩进 / 引用符号和一个续行字符，接着扫结束符后面的内容。
    private static func appendContinuations(_ found: Found, lines: [String], current: inout String, result: inout [String],
                                            lineIndex: inout Int, chars: inout [Character], index: inout Int) {
        guard found.lineOffset > 0 else {
            index = found.after
            return
        }
        for offset in 1...found.lineOffset {
            result.append(current)
            current = String(linePrefix(lines[lineIndex + offset][...]))
            current.append(continuation)
        }
        lineIndex += found.lineOffset
        chars = found.endChars
        index = found.after
    }
}
