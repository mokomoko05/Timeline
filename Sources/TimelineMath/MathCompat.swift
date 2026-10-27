import Foundation

/// AI 回答、网页里常见的 LaTeX（KaTeX / MathJax 能排的写法）有不少 SwiftMath 不认识，一个不认识的命令就让整个公式排不出来。
/// 排版前先换成 SwiftMath 认识的等价写法；实在没有对应的（大小号括号、编号、框）就去掉修饰，只留内容。
public enum MathCompat {
    public static func normalize(_ latex: String) -> String {
        var text = latex
        // 编号、标签：行内显示用不上。
        for name in ["tag*", "tag", "label", "eqref", "ref"] { text = replaceCommand(text, name, arguments: 1) { _ in "" } }
        for name in ["nonumber", "notag"] { text = replaceWord(text, name, with: "") }
        // 环境：编号的公式环境去掉编号；align 换成 aligned；array 换成 matrix（列格式丢掉）。
        text = text.replacingOccurrences(of: #"\\begin\{(equation|displaymath|math)\*?\}"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\\end\{(equation|displaymath|math)\*?\}"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\\(begin|end)\{(align|alignat|flalign|eqnarray|split)\*?\}(\{\d+\})?"#, with: "\\\\$1{aligned}", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\\(begin|end)\{(gather|gathered|multline)\*?\}"#, with: "\\\\$1{matrix}", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\\begin\{array\}\{[^}]*\}"#, with: "\\\\begin{matrix}", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\\end\{array\}"#, with: "\\\\end{matrix}", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\\(begin|end)\{(smallmatrix|matrix\*)\}"#, with: "\\\\$1{matrix}", options: .regularExpression)
        // 大小号括号（\big( \Bigl[ …）：去掉大小，只留括号。
        text = text.replacingOccurrences(of: #"\\(big|Big|bigg|Bigg)[lrm]?(?![a-zA-Z])\s*"#, with: "", options: .regularExpression)
        // 字体与运算符名。
        text = replaceCommand(text, "operatorname*", arguments: 1) { "\\mathrm{\($0[0])}" }
        text = replaceCommand(text, "operatorname", arguments: 1) { "\\mathrm{\($0[0])}" }
        for (from, to) in [("boldsymbol", "mathbf"), ("bm", "mathbf"), ("pmb", "mathbf"), ("mathbfit", "mathbf"),
                           ("textbf", "mathbf"), ("textit", "mathit"), ("textrm", "mathrm"), ("textsf", "mathsf"),
                           ("texttt", "mathtt"), ("textnormal", "mathrm"), ("mathscr", "mathcal"), ("mbox", "text")] {
            text = replaceWord(text, from, with: "\\" + to)
        }
        // 分数、上下标装饰。
        for name in ["dfrac", "tfrac", "cfrac"] { text = replaceWord(text, name, with: "\\frac") }
        // 没有 \stackrel / \overset：上面的东西放成上标、下面的放成下标，意思不丢。
        text = replaceCommand(text, "overset", arguments: 2) { "{\($0[1])}^{\($0[0])}" }
        text = replaceCommand(text, "stackrel", arguments: 2) { "{\($0[1])}^{\($0[0])}" }
        text = replaceCommand(text, "underset", arguments: 2) { "{\($0[1])}_{\($0[0])}" }
        text = replaceCommand(text, "underbrace", arguments: 1) { "\\underline{\($0[0])}" }
        text = replaceCommand(text, "overbrace", arguments: 1) { "\\overline{\($0[0])}" }
        text = replaceCommand(text, "xrightarrow", arguments: 1) { "{\\longrightarrow}^{\($0[0])}" }
        text = replaceCommand(text, "xleftarrow", arguments: 1) { "{\\longleftarrow}^{\($0[0])}" }
        text = replaceCommand(text, "boxed", arguments: 1) { "{\($0[0])}" }
        text = replaceCommand(text, "fbox", arguments: 1) { "{\($0[0])}" }
        text = replaceCommand(text, "hspace*", arguments: 1) { _ in "\\quad" }
        text = replaceCommand(text, "hspace", arguments: 1) { _ in "\\quad" }
        text = replaceCommand(text, "phantom", arguments: 1) { _ in "" }
        // 符号的别名。
        for (from, to) in [("lVert", "\\|"), ("rVert", "\\|"), ("lvert", "|"), ("rvert", "|"), ("Vert", "\\|"), ("vert", "|"),
                           ("dots", "\\ldots"), ("dotsc", "\\ldots"), ("dotsb", "\\cdots"), ("dotsm", "\\cdots"), ("dotso", "\\ldots"),
                           ("implies", "\\Longrightarrow"), ("impliedby", "\\Longleftarrow"), ("varnothing", "\\emptyset"),
                           ("enspace", "\\;"), ("thinspace", "\\,"), ("medspace", "\\;"), ("thickspace", "\\;"), ("negthinspace", "\\!"),
                           ("nmid", "∤"), ("colon", ":"), ("land", "\\wedge"), ("lor", "\\vee"), ("lnot", "\\neg"), ("gets", "\\leftarrow"),
                           ("coloneqq", ":="), ("eqqcolon", "=:"), ("triangleq", "≜"), ("iint", "\\int\\int"),
                           ("iiint", "\\int\\int\\int"), ("intercal", "\\top"), ("lbrace", "\\{"), ("rbrace", "\\}"),
                           ("lbrack", "["), ("rbrack", "]"), ("And", "\\&"), ("argmax", "\\mathrm{arg\\,max}"), ("argmin", "\\mathrm{arg\\,min}")] {
            text = replaceWord(text, from, with: to)
        }
        // 反斜杠加空格是一个空格（`\\ ` 是换行，不算：前面还有一个反斜杠）。
        text = text.replacingOccurrences(of: #"(?<!\\)((?:\\\\)*)\\ "#, with: "$1\\\\;", options: .regularExpression)
        return text
    }

    /// 把 `\name` 换掉（后面不能紧跟字母，免得 `\dots` 误伤 `\dotsc`）。
    private static func replaceWord(_ text: String, _ name: String, with replacement: String) -> String {
        guard text.contains("\\" + name) else { return text }
        let pattern = "\\\\" + NSRegularExpression.escapedPattern(for: name) + "(?![a-zA-Z])"
        return text.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: replacement), options: .regularExpression)
    }

    /// 把带 `arguments` 个花括号参数的 `\name{…}{…}` 换掉；参数里可以嵌套花括号。
    private static func replaceCommand(_ text: String, _ name: String, arguments: Int, _ transform: ([String]) -> String) -> String {
        let command = "\\" + name
        guard text.contains(command) else { return text }
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: command) {
            let after = rest[range.upperBound...]
            // 后面紧跟字母说明是别的命令（\tag 和 \tagged）；`*` 的变体单独处理。
            if let next = after.first, next.isLetter || (next == "*" && !name.hasSuffix("*")) {
                result += rest[..<range.upperBound]
                rest = after
                continue
            }
            var cursor = after.startIndex
            var values: [String] = []
            while values.count < arguments {
                while cursor < after.endIndex, after[cursor] == " " { cursor = after.index(after: cursor) }
                guard cursor < after.endIndex, after[cursor] == "{", let close = matchingBrace(after, from: cursor) else { break }
                values.append(String(after[after.index(after: cursor)..<close]))
                cursor = after.index(after: close)
            }
            guard values.count == arguments else {
                result += rest[..<range.upperBound]
                rest = after
                continue
            }
            result += rest[..<range.lowerBound]
            result += transform(values)
            rest = after[cursor...]
        }
        return result + rest
    }

    private static func matchingBrace(_ text: Substring, from open: Substring.Index) -> Substring.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                index = text.index(after: index)
                if index < text.endIndex { index = text.index(after: index) }
                continue
            }
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
