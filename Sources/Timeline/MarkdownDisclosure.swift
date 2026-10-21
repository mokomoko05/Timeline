import Foundation
import Combine

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

indirect enum MarkdownDisclosureNode: Identifiable {
    case markdown(MarkdownFragment)
    case disclosure(MarkdownDisclosure)

    var id: Int {
        switch self {
        case .markdown(let fragment): return fragment.id
        case .disclosure(let disclosure): return disclosure.id
        }
    }
}

final class MarkdownDisclosureCache: ObservableObject {
    @Published private(set) var expanded: [Int: Bool] = [:]
    private var source: String?
    private var nodes: [MarkdownDisclosureNode] = []
    private var rendered: Set<Int> = []

    func parse(_ source: String) -> [MarkdownDisclosureNode] {
        if self.source != source {
            self.source = source
            nodes = MarkdownDisclosures.parse(source)
        }
        return nodes
    }

    func isExpanded(_ disclosure: MarkdownDisclosure) -> Bool {
        expanded[disclosure.id] ?? disclosure.initiallyOpen
    }

    func toggle(_ disclosure: MarkdownDisclosure) {
        rendered.insert(disclosure.id)
        expanded[disclosure.id] = !isExpanded(disclosure)
    }

    func hasRendered(_ disclosure: MarkdownDisclosure) -> Bool { isExpanded(disclosure) || rendered.contains(disclosure.id) }
}

enum MarkdownDisclosures {
    private struct Opening {
        let title: String
        let initiallyOpen: Bool
        let bodyStart: Int
    }

    private static let opening = try! NSRegularExpression(pattern: #"^<details(?:\s+(open)(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?)?\s*>\s*(?:<summary\s*>(.*?)</summary\s*>)?\s*$"#, options: [.caseInsensitive])
    private static let summary = try! NSRegularExpression(pattern: #"^<summary\s*>(.*?)</summary\s*>\s*$"#, options: [.caseInsensitive])

    static func parse(_ source: String) -> [MarkdownDisclosureNode] {
        let lines = source.components(separatedBy: "\n")
        var openings: [Int: Opening] = [:]
        var closingLines: [Int: Int] = [:]
        var stack: [Int] = []
        var fence: (marker: Character, length: Int)?
        for index in lines.indices {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let indentation = raw.prefix { $0 == " " || $0 == "\t" }
            let indented = indentation.contains("\t") || indentation.count > 3
            if let active = fence {
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
                                          initiallyOpen: match.range(at: 1).location != NSNotFound,
                                          bodyStart: bodyStart)
                stack.append(index)
            } else if line.lowercased() == "</details>", let start = stack.popLast() {
                closingLines[start] = index
            }
        }

        func nodes(in range: Range<Int>) -> [MarkdownDisclosureNode] {
            var result: [MarkdownDisclosureNode] = []
            var plainStart = range.lowerBound
            var index = range.lowerBound
            func appendPlain(until end: Int) {
                guard plainStart < end else { return }
                let text = lines[plainStart..<end].joined(separator: "\n")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(.markdown(MarkdownFragment(source: text, lineOffset: plainStart)))
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

    private static func decodeTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
