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

    public static func rendered(_ source: String, alias: String? = nil) -> AttributedString {
        var result = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        let links = result.runs.compactMap { run in run.link.map { (run.range, $0) } }
        for (range, url) in links {
            result[range].link = linkURL(url.absoluteString)
        }
        let text = String(result.characters)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
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
