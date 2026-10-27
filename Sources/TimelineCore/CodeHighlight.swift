import Foundation

/// 笔记里代码块的语法高亮：按语言认出注释、字符串、数字、关键字、类型和函数名，返回它们在代码里的位置（UTF-16）。
///
/// 不追求和编辑器一样精确，只是常见语言（AI 回答里最常见的那些）看起来像样；认不出语言时按类 C 的规则猜。
/// 结果按代码和语言缓存：滚动时重画不用再扫一遍。
public enum CodeHighlight {
    public enum Kind: Sendable { case comment, string, number, keyword, type, function, attribute }

    public struct Token: Equatable, Sendable {
        public let range: NSRange
        public let kind: Kind
    }

    private enum Family { case cLike, python, shell, ruby, sql, json, yaml, html, css, plain }

    private struct Rules {
        let comment: String?
        let keywords: Set<String>
        let caseInsensitive: Bool
    }

    public static func tokens(_ code: String, language: String?) -> [Token] {
        let key = (language ?? "") + "\u{0}" + code
        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()
        let result = scan(code, family: family(language))
        lock.lock()
        if cache.count > 300 { cache.removeAll() }
        cache[key] = result
        lock.unlock()
        return result
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [Token]] = [:]

    private static func family(_ language: String?) -> Family {
        switch language?.lowercased().trimmingCharacters(in: .whitespaces) ?? "" {
        case "python", "py", "python3": return .python
        case "sh", "bash", "zsh", "shell", "console", "fish", "powershell", "ps1": return .shell
        case "ruby", "rb": return .ruby
        case "sql", "mysql", "postgresql", "sqlite": return .sql
        case "json", "jsonc", "json5": return .json
        case "yaml", "yml", "toml", "ini": return .yaml
        case "html", "xml", "svg", "vue": return .html
        case "css", "scss", "less": return .css
        case "text", "txt", "plain", "plaintext", "markdown", "md": return .plain
        default: return .cLike
        }
    }

    private static let cKeywords: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "function", "func", "fn",
        "var", "let", "const", "class", "struct", "enum", "interface", "protocol", "extension", "impl", "trait", "type", "typealias",
        "import", "export", "from", "package", "using", "namespace", "public", "private", "protected", "internal", "fileprivate",
        "static", "final", "override", "virtual", "abstract", "async", "await", "try", "catch", "throw", "throws", "finally",
        "new", "delete", "this", "self", "super", "true", "false", "null", "nil", "undefined", "void", "in", "of", "is", "as",
        "guard", "defer", "where", "mut", "pub", "mod", "use", "match", "loop", "go", "chan", "select", "yield", "lambda",
        "int", "float", "double", "char", "bool", "boolean", "string", "long", "short", "unsigned", "signed", "auto", "inline",
        "template", "typename", "constexpr", "extern", "sizeof", "goto", "volatile", "val", "object", "when", "init", "deinit",
        "some", "any", "inout", "operator", "instanceof", "typeof", "readonly", "declare", "module", "require", "debugger"]
    private static let pythonKeywords: Set<String> = [
        "def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as", "with", "try", "except",
        "finally", "raise", "pass", "break", "continue", "lambda", "yield", "in", "is", "not", "and", "or", "None", "True",
        "False", "global", "nonlocal", "assert", "del", "async", "await", "self", "match", "case", "print"]
    private static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "in", "function", "return", "export",
        "local", "echo", "cd", "sudo", "exit", "source", "alias", "set", "unset", "readonly", "until", "select", "time"]
    private static let rubyKeywords: Set<String> = [
        "def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until", "for", "do", "return", "yield",
        "begin", "rescue", "ensure", "raise", "require", "include", "attr_accessor", "self", "nil", "true", "false", "and",
        "or", "not", "then", "case", "when", "puts", "lambda", "proc"]
    private static let sqlKeywords: Set<String> = [
        "select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create", "table",
        "drop", "alter", "add", "index", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having",
        "limit", "offset", "as", "distinct", "union", "all", "null", "is", "in", "like", "between", "case", "when", "then",
        "else", "end", "primary", "key", "foreign", "references", "default", "asc", "desc", "count", "sum", "avg", "max", "min", "with"]
    private static let jsonKeywords: Set<String> = ["true", "false", "null"]

    private static func rules(_ family: Family) -> Rules {
        switch family {
        case .cLike: return Rules(comment: #"//[^\n]*|/\*[\s\S]*?\*/"#, keywords: cKeywords, caseInsensitive: false)
        case .python: return Rules(comment: #"#[^\n]*"#, keywords: pythonKeywords, caseInsensitive: false)
        case .shell: return Rules(comment: #"(?<![\w$])#[^\n]*"#, keywords: shellKeywords, caseInsensitive: false)
        case .ruby: return Rules(comment: #"#[^\n]*"#, keywords: rubyKeywords, caseInsensitive: false)
        case .sql: return Rules(comment: #"--[^\n]*|/\*[\s\S]*?\*/"#, keywords: sqlKeywords, caseInsensitive: true)
        case .json: return Rules(comment: nil, keywords: jsonKeywords, caseInsensitive: false)
        case .yaml: return Rules(comment: #"#[^\n]*"#, keywords: jsonKeywords.union(["yes", "no", "on", "off"]), caseInsensitive: false)
        case .html: return Rules(comment: #"<!--[\s\S]*?-->"#, keywords: [], caseInsensitive: false)
        case .css: return Rules(comment: #"/\*[\s\S]*?\*/"#, keywords: [], caseInsensitive: false)
        case .plain: return Rules(comment: nil, keywords: [], caseInsensitive: false)
        }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? { try? NSRegularExpression(pattern: pattern) }
    private static let stringSource = #""""[\s\S]*?"""|'''[\s\S]*?'''|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`"#
    private static let numberPattern = regex(#"\b(?:0x[0-9a-fA-F_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#)
    private static let wordPattern = regex(#"[A-Za-z_$][\w$]*"#)
    private static let attributePattern = regex(#"@[A-Za-z_]\w*"#)
    private static let htmlTagPattern = regex(#"</?[A-Za-z][\w:-]*|/?>"#)
    private static let htmlAttributePattern = regex(#"\s([A-Za-z_:][\w:.-]*)(?==)"#)
    private static let cssPropertyPattern = regex(#"([A-Za-z-]+)\s*:"#)
    private static let yamlKeyPattern = regex(#"(?m)^\s*-?\s*([\w.-]+)\s*[:=]"#)
    private static let shellVariablePattern = regex(#"\$\{?[A-Za-z_][\w]*\}?|(?<=\s)--?[A-Za-z][\w-]*"#)

    private static func scan(_ code: String, family: Family) -> [Token] {
        guard family != .plain, !code.isEmpty else { return [] }
        let text = code as NSString
        let full = NSRange(location: 0, length: text.length)
        let rules = rules(family)
        var tokens: [Token] = []
        // 已经认出来的地方（注释、字符串里）不再认别的。
        var taken = IndexSet()
        func claim(_ range: NSRange, _ kind: Kind) {
            guard range.length > 0, !taken.intersects(integersIn: range.location..<(range.location + range.length)) else { return }
            taken.insert(integersIn: range.location..<(range.location + range.length))
            tokens.append(Token(range: range, kind: kind))
        }
        // 注释和字符串合成一个表达式从左往右扫：先出现的算数（字符串里的 // 不是注释，注释里的引号不是字符串）。
        let strings = family == .html ? #""[^"]*"|'[^']*'"# : stringSource
        let combined = (rules.comment.map { "(" + $0 + ")|" } ?? "()(?!)|") + "(" + strings + ")"
        for match in regex(combined)?.matches(in: code, range: full) ?? [] {
            claim(match.range, match.range(at: 1).location != NSNotFound ? .comment : .string)
        }
        switch family {
        case .html:
            for match in htmlTagPattern?.matches(in: code, range: full) ?? [] { claim(match.range, .keyword) }
            for match in htmlAttributePattern?.matches(in: code, range: full) ?? [] { claim(match.range(at: 1), .attribute) }
        case .css:
            for match in cssPropertyPattern?.matches(in: code, range: full) ?? [] { claim(match.range(at: 1), .attribute) }
        case .yaml, .json:
            for match in yamlKeyPattern?.matches(in: code, range: full) ?? [] { claim(match.range(at: 1), .attribute) }
        case .shell:
            for match in shellVariablePattern?.matches(in: code, range: full) ?? [] { claim(match.range, .attribute) }
        default:
            for match in attributePattern?.matches(in: code, range: full) ?? [] { claim(match.range, .attribute) }
        }
        for match in numberPattern?.matches(in: code, range: full) ?? [] { claim(match.range, .number) }
        for match in wordPattern?.matches(in: code, range: full) ?? [] {
            let word = text.substring(with: match.range)
            if rules.keywords.contains(rules.caseInsensitive ? word.lowercased() : word) {
                claim(match.range, .keyword)
                continue
            }
            let after = match.range.location + match.range.length
            if after < text.length, text.character(at: after) == 40 /* ( */, family != .sql, family != .json, family != .yaml {
                claim(match.range, .function)
            } else if let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first), word.count > 1,
                      family == .cLike || family == .python || family == .ruby {
                claim(match.range, .type)
            }
        }
        return tokens.sorted { $0.range.location < $1.range.location }
    }
}
