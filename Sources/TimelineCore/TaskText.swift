import Foundation

public enum TaskText {
    public static func linkURL(_ input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("/") || value.hasPrefix("~/") {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        if let url = URL(string: value), url.isFileURL {
            guard url.host == nil || url.host == "" || url.host == "localhost", !url.path.isEmpty else { return nil }
            return url
        }
        return webURL(value)
    }

    public static func webURL(_ input: String) -> URL? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains(":") {
            guard value.contains("."), !value.hasPrefix("/"), !value.contains(where: \.isWhitespace) else { return nil }
            value = "https://" + value
        }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    public static func markdownLink(label: String, url: URL) -> String {
        let title = label.isEmpty ? (url.isFileURL ? url.lastPathComponent : (url.host ?? url.absoluteString)) : label
        let escaped = title.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(escaped)](<\(url.absoluteString)>)"
    }

    private static let cacheLock = NSLock()
    private static var renderCache: [String: AttributedString] = [:]
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    /// Markdown 行内语法和网址都离不开这些字符；一个都没有时原文就是结果。
    private static let syntaxCharacters = Set("[]<>*_`\\&~!:.@/")

    /// 标题和日志会在列表、提醒、搜索里反复渲染；结果只取决于原文和别名，所以缓存。
    public static func rendered(_ source: String, alias: String? = nil) -> AttributedString {
        let trimmedAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedAlias.isEmpty, !source.contains(where: syntaxCharacters.contains) { return AttributedString(source) }
        let key = trimmedAlias.isEmpty ? source : source + "\u{0}" + (alias ?? "")
        cacheLock.lock()
        if let cached = renderCache[key] { cacheLock.unlock(); return cached }
        cacheLock.unlock()
        let result = render(source, alias: alias)
        cacheLock.lock()
        if renderCache.count >= 2048 { renderCache.removeAll(keepingCapacity: true) }
        renderCache[key] = result
        cacheLock.unlock()
        return result
    }

    private static func render(_ source: String, alias: String?) -> AttributedString {
        var result = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        let links = result.runs.compactMap { run in run.link.map { (run.range, $0) } }
        for (range, url) in links {
            result[range].link = linkURL(url.absoluteString)
        }
        let text = String(result.characters)
        if let detector = linkDetector {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let detectedURL = match.url, let url = linkURL(detectedURL.absoluteString),
                      let textRange = Range(match.range, in: text) else { continue }
                let start = result.characters.index(result.startIndex, offsetBy: text.distance(from: text.startIndex, to: textRange.lowerBound))
                let end = result.characters.index(start, offsetBy: text.distance(from: textRange.lowerBound, to: textRange.upperBound))
                let range = start..<end
                if result[range].runs.allSatisfy({ $0.link == nil }) {
                    result[range].link = url
                }
            }
        }
        if let alias, !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var abbreviated = AttributedString(alias)
            let destinations = Set(result.runs.compactMap(\.link))
            if destinations.count == 1 { abbreviated.link = destinations.first }
            return abbreviated
        }
        return result
    }
}
