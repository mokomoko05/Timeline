import Foundation

public enum Key: Equatable {
    case up, down, left, right, pageUp, pageDown, home, end
    case enter, escape, backspace, tab
    case ctrl(Character)
    case char(Character)
}

/// 把终端读到的原始字节解码成按键。不完整的转义序列留在 `rest` 里等下一批字节。
public enum KeyDecoder {
    public static func decode(_ bytes: [UInt8]) -> (keys: [Key], rest: [UInt8]) {
        var keys: [Key] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x1B {
                guard index + 1 < bytes.count else {
                    // 单独一个 ESC：当作 Esc 键（调用方在读超时后才会把它交过来）。
                    keys.append(.escape); index += 1; continue
                }
                let next = bytes[index + 1]
                if next == UInt8(ascii: "[") || next == UInt8(ascii: "O") {
                    var end = index + 2
                    while end < bytes.count, !(0x40...0x7E).contains(bytes[end]) { end += 1 }
                    guard end < bytes.count else { return (keys, Array(bytes[index...])) }
                    let params = String(decoding: bytes[(index + 2)..<end], as: UTF8.self)
                    switch (bytes[end], params) {
                    case (UInt8(ascii: "A"), _): keys.append(.up)
                    case (UInt8(ascii: "B"), _): keys.append(.down)
                    case (UInt8(ascii: "C"), _): keys.append(.right)
                    case (UInt8(ascii: "D"), _): keys.append(.left)
                    case (UInt8(ascii: "H"), _): keys.append(.home)
                    case (UInt8(ascii: "F"), _): keys.append(.end)
                    case (UInt8(ascii: "~"), "5"): keys.append(.pageUp)
                    case (UInt8(ascii: "~"), "6"): keys.append(.pageDown)
                    case (UInt8(ascii: "~"), "1"), (UInt8(ascii: "~"), "7"): keys.append(.home)
                    case (UInt8(ascii: "~"), "4"), (UInt8(ascii: "~"), "8"): keys.append(.end)
                    default: break
                    }
                    index = end + 1
                    continue
                }
                keys.append(.escape)
                index += 1
                continue
            }
            switch byte {
            case 0x0D, 0x0A: keys.append(.enter); index += 1
            case 0x7F, 0x08: keys.append(.backspace); index += 1
            case 0x09: keys.append(.tab); index += 1
            case 0x01...0x1A:
                keys.append(.ctrl(Character(UnicodeScalar(byte + 0x60)))); index += 1
            default:
                // UTF-8 多字节字符。
                let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                guard index + length <= bytes.count else { return (keys, Array(bytes[index...])) }
                if let text = String(bytes: bytes[index..<(index + length)], encoding: .utf8), let ch = text.first { keys.append(.char(ch)) }
                index += length
            }
        }
        return (keys, [])
    }
}

public enum PickerAction: Equatable {
    case none
    case quit
    /// 选中一条（`--print` 模式下回车，或按 p）。
    case select(LogRow)
    case copy(String)
    case showImages(LogRow)
}

/// 交互式日志选择器的状态机：不碰终端，输入按键、输出要画的行，所以可以直接测试。
public struct PickerState {
    public enum Mode: Equatable { case list, search, detail }

    public private(set) var all: [LogRow]
    public private(set) var query = ""
    public private(set) var mode = Mode.list
    public private(set) var cursor = 0
    public private(set) var top = 0
    public private(set) var detailScroll = 0
    public private(set) var notice: String?
    /// true：回车直接选中并退出（用于 `--print`）；false：回车进入详情。
    public var selectOnEnter: Bool
    public var title: String
    private var detailLines: [String] = []

    public init(rows: [LogRow], title: String = "日志", selectOnEnter: Bool = false) {
        all = rows
        self.title = title
        self.selectOnEnter = selectOnEnter
        cursor = max(0, rows.count - 1)   // 日志按时间升序，默认停在最新一条
    }

    public var visible: [LogRow] {
        guard !query.isEmpty else { return all }
        return all.filter { $0.searchable.localizedCaseInsensitiveContains(query) || "#\($0.taskNumber ?? -1)" == query || $0.shortID.hasPrefix(query.lowercased()) }
    }

    public var current: LogRow? {
        let rows = visible
        return rows.indices.contains(cursor) ? rows[cursor] : nil
    }

    // MARK: - 输入

    /// `height` 是终端总行数（用来决定翻页步长和滚动）。
    public mutating func handle(_ key: Key, height: Int, detailProvider: (LogRow) -> [String] = { _ in [] }) -> PickerAction {
        notice = nil
        if key == .ctrl("c") { return .quit }
        switch mode {
        case .list: return handleList(key, height: height, detailProvider: detailProvider)
        case .search: return handleSearch(key, height: height)
        case .detail: return handleDetail(key, height: height, detailProvider: detailProvider)
        }
    }

    private var page: (Int) -> Int { { max(1, $0 - 4) } }

    private mutating func move(_ delta: Int, height: Int) {
        let count = visible.count
        guard count > 0 else { return }
        cursor = min(max(cursor + delta, 0), count - 1)
        keepCursorVisible(height: height)
    }

    private mutating func keepCursorVisible(height: Int) {
        let rows = max(1, height - 3)
        if cursor < top { top = cursor }
        if cursor >= top + rows { top = cursor - rows + 1 }
        top = max(0, min(top, max(0, visible.count - rows)))
    }

    private mutating func handleList(_ key: Key, height: Int, detailProvider: (LogRow) -> [String]) -> PickerAction {
        switch key {
        case .up, .char("k"): move(-1, height: height)
        case .down, .char("j"): move(1, height: height)
        case .pageUp, .ctrl("b"): move(-page(height), height: height)
        case .pageDown, .ctrl("f"), .ctrl("d"): move(page(height), height: height)
        case .home, .char("g"): move(-visible.count, height: height)
        case .end, .char("G"): move(visible.count, height: height)
        case .char("/"): mode = .search
        case .enter, .right, .char("l"):
            guard let row = current else { return .none }
            if selectOnEnter { return .select(row) }
            openDetail(row, detailProvider: detailProvider)
        case .char("p"): if let row = current { return .select(row) }
        case .char("y"):
            if let row = current { notice = "已复制"; return .copy(row.text) }
        case .char("q"), .escape:
            if !query.isEmpty { query = ""; cursor = max(0, visible.count - 1); keepCursorVisible(height: height) } else { return .quit }
        default: break
        }
        return .none
    }

    private mutating func handleSearch(_ key: Key, height: Int) -> PickerAction {
        switch key {
        case .enter: mode = .list
        case .escape: query = ""; mode = .list; cursor = max(0, visible.count - 1)
        case .backspace: if !query.isEmpty { query.removeLast() }
        case .ctrl("u"): query = ""
        case .up: move(-1, height: height); return .none
        case .down: move(1, height: height); return .none
        case .char(let ch): query.append(ch)
        default: return .none
        }
        cursor = max(0, visible.count - 1)
        keepCursorVisible(height: height)
        return .none
    }

    private mutating func openDetail(_ row: LogRow, detailProvider: (LogRow) -> [String]) {
        mode = .detail
        detailScroll = 0
        detailLines = detailProvider(row)
    }

    private mutating func handleDetail(_ key: Key, height: Int, detailProvider: (LogRow) -> [String]) -> PickerAction {
        let rows = max(1, height - 2)
        let maxScroll = max(0, detailLines.count - rows)
        switch key {
        case .up, .char("k"): detailScroll = max(0, detailScroll - 1)
        case .down, .char("j"): detailScroll = min(maxScroll, detailScroll + 1)
        case .pageUp: detailScroll = max(0, detailScroll - page(height))
        case .pageDown, .char(" "): detailScroll = min(maxScroll, detailScroll + page(height))
        case .home, .char("g"): detailScroll = 0
        case .end, .char("G"): detailScroll = maxScroll
        case .left, .char("h"), .escape, .backspace, .char("q"): mode = .list
        case .char("n"), .char("]"):
            if cursor + 1 < visible.count { cursor += 1; keepCursorVisible(height: height); if let row = current { openDetail(row, detailProvider: detailProvider) } }
        case .char("N"), .char("["):
            if cursor > 0 { cursor -= 1; keepCursorVisible(height: height); if let row = current { openDetail(row, detailProvider: detailProvider) } }
        case .char("y"): if let row = current { notice = "已复制"; return .copy(row.text) }
        case .char("i"): if let row = current { return row.images.isEmpty ? { notice = "这条日志没有图片"; return .none }() : .showImages(row) }
        case .char("p"): if let row = current { return .select(row) }
        default: break
        }
        return .none
    }

    // MARK: - 输出

    /// 画满 `height` 行，每行显示宽度不超过 `width`。
    public func render(width: Int, height: Int, style: Style, detailLines provided: [String]? = nil) -> [String] {
        let width = max(20, width)
        let height = max(5, height)
        var lines: [String]
        switch mode {
        case .detail:
            lines = renderDetail(width: width, height: height, style: style, provided: provided)
        default:
            lines = renderList(width: width, height: height, style: style)
        }
        while lines.count < height { lines.append("") }
        return Array(lines.prefix(height))
    }

    private func renderList(width: Int, height: Int, style: Style) -> [String] {
        let rows = visible
        var header = style.bold("\(title)  ") + style.gray("\(rows.isEmpty ? 0 : cursor + 1)/\(rows.count)")
        if mode == .search { header += "  " + style.yellow("搜索: ") + query + style.reverse(" ") }
        else if !query.isEmpty { header += "  " + style.yellow("筛选: ") + query }
        var lines = [TerminalText.truncate(header, to: width), style.gray(String(repeating: "─", count: width))]
        let capacity = height - 3
        if rows.isEmpty {
            lines.append(style.dim(query.isEmpty ? "没有日志" : "没有匹配「\(query)」的日志"))
        } else {
            let end = min(rows.count, top + capacity)
            for index in top..<end {
                let row = rows[index]
                let task = row.taskNumber.map { "#\($0)" } ?? ""
                let marker = row.images.isEmpty ? "" : " 🖼"
                let prefix = "\(String(row.dateKey.dropFirst(5))) \(row.timeLabel) \(row.kind.label.padding(toLength: 5, withPad: " ", startingAt: 0)) \(task.padding(toLength: 4, withPad: " ", startingAt: 0)) "
                let text = TerminalText.truncate(row.singleLine + marker, to: max(5, width - TerminalText.width(prefix) - 1))
                let line = " " + prefix + text
                lines.append(index == cursor ? style.reverse(TerminalText.pad(line, to: width)) : style.gray(String(prefix.isEmpty ? "" : " " + prefix)) + text)
            }
        }
        while lines.count < height - 1 { lines.append("") }
        let help = mode == .search ? "输入筛选 · ⏎ 确认 · Esc 取消 · ↑↓ 移动" : "↑↓/jk 移动 · ⏎ 查看 · / 搜索 · y 复制 · p 输出编号 · q 退出"
        lines.append(style.dim(TerminalText.truncate(notice.map { "\($0) · " + help } ?? help, to: width)))
        return lines
    }

    private func renderDetail(width: Int, height: Int, style: Style, provided: [String]?) -> [String] {
        let content = provided ?? detailLines
        let rows = max(1, height - 2)
        let start = min(detailScroll, max(0, content.count - rows))
        var lines = Array(content.dropFirst(start).prefix(rows)).map { TerminalText.truncate($0, to: width) }
        while lines.count < height - 1 { lines.append("") }
        let position = content.count > rows ? " (\(min(content.count, start + rows))/\(content.count))" : ""
        let help = "↑↓ 滚动 · ←/Esc 返回 · n/N 下/上一条 · y 复制 · i 查看图片 · p 输出编号" + position
        lines.append(style.dim(TerminalText.truncate(notice.map { "\($0) · " + help } ?? help, to: width)))
        return lines
    }
}
