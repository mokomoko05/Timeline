import Foundation

/// 终端文字：显示宽度（汉字、全角、emoji 占两格）、截断、换行，以及 ANSI 颜色和 OSC 8 超链接。
public enum TerminalText {
    // MARK: - 宽度

    /// 单个 Unicode 标量在终端里占几格。
    public static func width(of scalar: Unicode.Scalar) -> Int {
        let v = scalar.value
        if v == 0 { return 0 }
        if v < 0x20 || (0x7F..<0xA0).contains(v) { return 0 }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return 0
        default: break
        }
        if (0xFE00...0xFE0F).contains(v) || (0xE0100...0xE01EF).contains(v) { return 0 }
        if scalar.properties.isEmojiPresentation { return 2 }
        let wide: [ClosedRange<UInt32>] = [
            0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
            0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60,
            0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD,
        ]
        return wide.contains { $0.contains(v) } ? 2 : 1
    }

    /// 一个字素簇的宽度：基字符决定，后面的组合符号、变体选择符不占格。
    public static func width(of character: Character) -> Int {
        var total = 0
        for scalar in character.unicodeScalars { total = max(total, width(of: scalar)) }
        if character.unicodeScalars.contains(where: { $0.value == 0xFE0F }) { return 2 }
        return total
    }

    // MARK: - 转义序列

    /// 把字符串切成「原子」：转义序列（CSI、OSC）整体不可拆、不占宽度；其余按字素簇。
    public static func atoms(_ text: String) -> [(text: String, width: Int, isEscape: Bool)] {
        var result: [(String, Int, Bool)] = []
        let scalars = Array(text.unicodeScalars)
        var index = 0
        var pending = String.UnicodeScalarView()
        func flush() {
            guard !pending.isEmpty else { return }
            for ch in String(pending) { result.append((String(ch), width(of: ch), false)) }
            pending = String.UnicodeScalarView()
        }
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar.value == 0x1B, index + 1 < scalars.count else { pending.append(scalar); index += 1; continue }
            flush()
            var end = index + 2
            switch scalars[index + 1] {
            case "[":   // CSI：到 0x40...0x7E 的终止字节
                while end < scalars.count, !(0x40...0x7E).contains(scalars[end].value) { end += 1 }
                end = min(end + 1, scalars.count)
            case "]", "_", "P":   // OSC / APC / DCS：到 BEL 或 ESC \
                while end < scalars.count {
                    if scalars[end].value == 0x07 { end += 1; break }
                    if scalars[end].value == 0x1B, end + 1 < scalars.count, scalars[end + 1] == "\\" { end += 2; break }
                    end += 1
                }
            default: break
            }
            var sequence = String.UnicodeScalarView()
            sequence.append(contentsOf: scalars[index..<min(end, scalars.count)])
            result.append((String(sequence), 0, true))
            index = max(end, index + 1)
        }
        flush()
        return result
    }

    public static func width(_ text: String) -> Int { atoms(text).reduce(0) { $0 + $1.width } }

    public static func stripEscapes(_ text: String) -> String { atoms(text).filter { !$0.isEscape }.map(\.text).joined() }

    // MARK: - 截断、补齐、换行

    /// 截到不超过 `limit` 格；被截断时末尾加省略号。转义序列原样保留（颜色不会丢），超出后补一个重置。
    public static func truncate(_ text: String, to limit: Int, ellipsis: String = "…") -> String {
        guard limit > 0 else { return "" }
        if width(text) <= limit { return text }
        let room = max(0, limit - width(ellipsis))
        var used = 0
        var out = ""
        var sawEscape = false
        for atom in atoms(text) {
            if atom.isEscape { out += atom.text; sawEscape = true; continue }
            if used + atom.width > room { break }
            out += atom.text
            used += atom.width
        }
        return out + ellipsis + (sawEscape ? "\u{1B}[0m\u{1B}]8;;\u{07}" : "")
    }

    public static func pad(_ text: String, to limit: Int) -> String {
        let w = width(text)
        return w >= limit ? text : text + String(repeating: " ", count: limit - w)
    }

    /// 按显示宽度换行：保留原有换行，尽量在空格处断开，实在没有空格就在宽度处硬断（汉字之间可随时断）。
    public static func wrap(_ text: String, width limit: Int) -> [String] {
        guard limit > 0 else { return [text] }
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var line: [(text: String, width: Int, isEscape: Bool)] = []
            var used = 0
            func emit() { lines.append(line.map(\.text).joined()); line = []; used = 0 }
            for atom in atoms(paragraph) {
                if atom.isEscape { line.append(atom); continue }
                if used + atom.width > limit {
                    // 往回找最近的空格作为断点。
                    if let space = line.lastIndex(where: { !$0.isEscape && $0.text == " " }), space > line.count / 3 {
                        let rest = Array(line[(space + 1)...])
                        line = Array(line[..<space])
                        emit()
                        line = rest
                        used = rest.reduce(0) { $0 + $1.width }
                    } else {
                        emit()
                    }
                }
                if used == 0, atom.text == " ", !lines.isEmpty { continue }   // 折行后不以空格开头
                line.append(atom)
                used += atom.width
            }
            emit()
        }
        return lines
    }
}

/// ANSI 样式。`enabled` 为 false（管道输出、NO_COLOR）时所有方法原样返回文字。
public struct Style {
    public let enabled: Bool
    public let hyperlinks: Bool
    public init(enabled: Bool, hyperlinks: Bool? = nil) {
        self.enabled = enabled
        self.hyperlinks = hyperlinks ?? enabled
    }

    public static let plain = Style(enabled: false)

    private func wrap(_ text: String, _ codes: String) -> String { enabled ? "\u{1B}[\(codes)m\(text)\u{1B}[0m" : text }
    public func bold(_ t: String) -> String { wrap(t, "1") }
    public func dim(_ t: String) -> String { wrap(t, "2") }
    public func reverse(_ t: String) -> String { wrap(t, "7") }
    public func red(_ t: String) -> String { wrap(t, "31") }
    public func green(_ t: String) -> String { wrap(t, "32") }
    public func yellow(_ t: String) -> String { wrap(t, "33") }
    public func blue(_ t: String) -> String { wrap(t, "34") }
    public func magenta(_ t: String) -> String { wrap(t, "35") }
    public func cyan(_ t: String) -> String { wrap(t, "36") }
    public func gray(_ t: String) -> String { wrap(t, "90") }

    /// OSC 8 超链接：终端里可以点击（⌘ 点击），不支持的终端只显示文字。
    public func link(_ text: String, url: String) -> String {
        hyperlinks ? "\u{1B}]8;;\(url)\u{07}\(text)\u{1B}]8;;\u{07}" : text
    }
}
