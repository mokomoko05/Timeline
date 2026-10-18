import Foundation
import DayleafCore

/// 渲染时用到的环境：终端宽度、样式、图片协议、图片所在目录。
public struct RenderContext {
    public var width: Int
    public var style: Style
    public var imageProtocol: ImageProtocol
    public var imagesDirectory: URL
    public init(width: Int = 80, style: Style = .plain, imageProtocol: ImageProtocol = .none, imagesDirectory: URL) {
        self.width = max(20, width)
        self.style = style
        self.imageProtocol = imageProtocol
        self.imagesDirectory = imagesDirectory
    }
}

public enum LogRenderer {
    // MARK: - 文字

    /// 把正文里的 Markdown 链接和裸网址转成可点击的终端超链接。
    public static func richText(_ text: String, style: Style) -> String {
        let attributed = TaskText.rendered(text)
        var out = ""
        for run in attributed.runs {
            let piece = String(attributed[run.range].characters)
            if let url = run.link, style.hyperlinks {
                out += style.link(style.cyan(piece), url: url.absoluteString)
            } else {
                out += piece
            }
        }
        return out
    }

    private static func kindLabel(_ kind: DailyLogKind, style: Style) -> String {
        let label = kind.label.padding(toLength: 5, withPad: " ", startingAt: 0)
        switch kind {
        case .note: return style.gray(label)
        case .done: return style.green(label)
        case .block: return style.red(label)
        case .plan: return style.blue(label)
        }
    }

    private static let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    static func dayHeader(_ row: LogRow, ctx: RenderContext) -> String {
        let weekday = weekdays[JournalDates.calendar.component(.weekday, from: row.date) - 1]
        let title = "\(row.dateKey) \(weekday)"
        let rule = String(repeating: "─", count: max(2, ctx.width - TerminalText.width(title) - 4))
        return ctx.style.bold(ctx.style.blue("── \(title) ")) + ctx.style.gray(rule)
    }

    /// 日志列表：按日期分组，每条一行（正文过长自动换行，续行缩进对齐）。
    public static func list(_ rows: [LogRow], ctx: RenderContext, showImages: Bool = false) -> [String] {
        var lines: [String] = []
        var lastKey: String?
        for row in rows {
            if row.dateKey != lastKey {
                if lastKey != nil { lines.append("") }
                lines.append(dayHeader(row, ctx: ctx))
                lastKey = row.dateKey
            }
            lines += entry(row, ctx: ctx, showImages: showImages)
        }
        return lines
    }

    static func entry(_ row: LogRow, ctx: RenderContext, showImages: Bool) -> [String] {
        let task = row.taskNumber.map { "#\($0)" } ?? ""
        let prefix = "\(row.timeLabel)  \(kindLabelPlain(row.kind))  \(task.padding(toLength: 4, withPad: " ", startingAt: 0))"
        let indent = TerminalText.width(prefix) + 1
        let styledPrefix = ctx.style.gray(row.timeLabel) + "  " + kindLabel(row.kind, style: ctx.style) + "  " +
            ctx.style.yellow(task.padding(toLength: 4, withPad: " ", startingAt: 0)) + " "
        let body = richText(row.text.isEmpty ? (row.images.isEmpty ? "" : "（图片）") : row.text, style: ctx.style)
        let wrapped = TerminalText.wrap(body, width: max(10, ctx.width - indent))
        var lines: [String] = []
        for (index, piece) in wrapped.enumerated() {
            lines.append(index == 0 ? styledPrefix + piece : String(repeating: " ", count: indent) + piece)
        }
        if lines.isEmpty { lines.append(styledPrefix) }
        if row.focus { lines[0] += " " + ctx.style.dim("⏱") }
        if !row.images.isEmpty {
            let note = "🖼 \(row.images.count) 张图片" + (showImages ? "" : "（sched show \(row.shortID) 查看）")
            lines.append(String(repeating: " ", count: indent) + ctx.style.dim(TerminalText.truncate(note, to: max(10, ctx.width - indent))))
            if showImages { lines += imageLines(row, ctx: ctx, indent: indent) }
        }
        return lines
    }

    private static func kindLabelPlain(_ kind: DailyLogKind) -> String { kind.label.padding(toLength: 5, withPad: " ", startingAt: 0) }

    /// 图片：支持内联协议就直接画出来，否则打印文件路径（可点击）。
    static func imageLines(_ row: LogRow, ctx: RenderContext, indent: Int) -> [String] {
        var lines: [String] = []
        let columns = max(8, min(72, ctx.width - indent - 2))
        for name in row.images {
            let url = ctx.imagesDirectory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                lines.append(String(repeating: " ", count: indent) + ctx.style.red("（找不到图片文件 \(name)）"))
                continue
            }
            if ctx.imageProtocol != .none, let prepared = InlineImage.prepare(url),
               let sequence = InlineImage.sequence(prepared, name: name, columns: InlineImage.columns(pixelWidth: prepared.pixelWidth, maxColumns: columns), protocol: ctx.imageProtocol) {
                // 序列末尾自带换行，去掉，由调用方统一换行。
                lines.append(String(repeating: " ", count: indent) + String(sequence.dropLast()))
            } else {
                lines.append(String(repeating: " ", count: indent) + ctx.style.link(url.path, url: url.absoluteString))
            }
            if let text = row.imageText[name], !text.isEmpty {
                let snippet = text.replacingOccurrences(of: "\n", with: " ")
                lines.append(String(repeating: " ", count: indent) + ctx.style.dim("识别文字：" + TerminalText.truncate(snippet, to: max(10, ctx.width - indent - 10))))
            }
        }
        return lines
    }

    /// 单条日志的完整视图。
    public static func detail(_ row: LogRow, ctx: RenderContext) -> [String] {
        var lines: [String] = []
        lines.append(ctx.style.bold("\(row.dateKey) \(row.timeLabel)") + "  " + kindLabel(row.kind, style: ctx.style) +
                     (row.focus ? "  " + ctx.style.dim("专注记录") : "") + "  " + ctx.style.gray("id " + row.shortID))
        if let number = row.taskNumber {
            lines.append(ctx.style.yellow("#\(number)") + " " + ctx.style.bold(TerminalText.truncate(row.taskTitle ?? "", to: max(10, ctx.width - 8))))
        }
        lines.append("")
        lines += TerminalText.wrap(richText(row.text, style: ctx.style), width: ctx.width)
        if !row.images.isEmpty {
            lines.append("")
            lines += imageLines(row, ctx: ctx, indent: 0)
        }
        return lines
    }

    // MARK: - 机器可读

    /// 一行一条、制表符分隔：`短标识 日期 时间 类型 #任务 正文`。给 fzf、awk 用。
    public static func porcelain(_ rows: [LogRow]) -> [String] {
        rows.map { row in
            [row.shortID, row.dateKey, row.timeLabel, row.kind.rawValue, row.taskNumber.map { "#\($0)" } ?? "-", row.singleLine].joined(separator: "\t")
        }
    }

    public static func json(_ rows: [LogRow]) -> String {
        let items: [[String: Any]] = rows.map { row in
            var item: [String: Any] = [
                "id": row.id.uuidString, "short_id": row.shortID, "date": row.dateKey, "time": row.timeLabel,
                "created_at": ISO8601DateFormatter().string(from: row.createdAt), "kind": row.kind.rawValue, "text": row.text,
                "images": row.images, "focus": row.focus,
            ]
            if let number = row.taskNumber { item["task"] = number }
            if let title = row.taskTitle { item["task_title"] = title }
            if !row.imageText.isEmpty { item["image_text"] = row.imageText }
            return item
        }
        let data = (try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Markdown：和应用笔记视图的「复制为 Markdown」同样的结构，图片引用 Images 文件夹里的文件名。
    public static func markdown(title: String, rows: [LogRow]) -> String {
        var lines = ["# \(title)", ""]
        var lastKey: String?
        for row in rows {
            if row.dateKey != lastKey {
                if lastKey != nil { lines.append("") }
                lines.append("## \(row.dateKey)")
                lastKey = row.dateKey
            }
            var line = "- \(row.timeLabel) [\(row.kind.label)]"
            if row.taskNumber != nil, !title.hasPrefix("#") { line += " #\(row.taskNumber!)" }
            line += " " + String(TaskText.rendered(row.text).characters).replacingOccurrences(of: "\n", with: "\n  ")
            for name in row.images { line += "\n  ![](Images/\(name))" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 任务

    public struct TaskRow: Equatable {
        public let number: Int
        public let title: String
        public let completed: Bool
        /// 放弃的待办（也算 completed）。
        public var dropped = false
        public let due: Date?
        public let dueHasTime: Bool
        public let focusSeconds: TimeInterval
        public let noteCount: Int
        public let tags: [String]
        public var priority: TaskPriority = .normal
    }

    @MainActor
    public static func taskRows(in store: JournalStore, includeCompleted: Bool) -> [TaskRow] {
        let counts = Dictionary(grouping: store.allLogs(includeFocus: false).compactMap { $0.log.taskID }, by: { $0 }).mapValues(\.count)
        return store.sortedTasks().filter { includeCompleted || !$0.task.completed }.compactMap { item in
            guard let number = item.task.number else { return nil }
            return TaskRow(number: number, title: String(TaskText.rendered(item.task.title).characters), completed: item.task.completed, dropped: item.task.isDropped,
                           due: item.task.dueDate, dueHasTime: item.task.dueHasTime, focusSeconds: item.task.focusSeconds,
                           noteCount: counts[item.id] ?? 0, tags: item.task.tags, priority: item.task.priority)
        }
    }

    public static func tasks(_ rows: [TaskRow], ctx: RenderContext, now: Date = Date()) -> [String] {
        rows.map { row in
            let box = row.dropped ? ctx.style.gray("✗") : (row.completed ? ctx.style.green("✓") : ctx.style.gray("○"))
            let number = ctx.style.yellow(("#\(row.number)").padding(toLength: 5, withPad: " ", startingAt: 0))
            var meta: [String] = []
            if row.priority != .normal { meta.append(row.priority == .high ? "↑ 高优先级" : "↓ 低优先级") }
            if let due = row.due {
                var text = relativeDay(due, now: now)
                if row.dueHasTime {
                    let parts = JournalDates.calendar.dateComponents([.hour, .minute], from: due)
                    text += String(format: " %02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
                }
                // 全天事项当天不算逾期；带时间的事项过了点就算。
                let late = !row.completed && (row.dueHasTime ? due < now : due < JournalDates.calendar.startOfDay(for: now))
                meta.append(late ? ctx.style.red(text + " 已逾期") : ctx.style.dim(text))
            }
            if row.noteCount > 0 { meta.append(ctx.style.dim("\(row.noteCount) 条笔记")) }
            if row.focusSeconds >= 1 { meta.append(ctx.style.dim("专注 " + brief(row.focusSeconds))) }
            if !row.tags.isEmpty { meta.append(ctx.style.cyan(row.tags.map { "#" + $0 }.joined(separator: " "))) }
            let metaText = meta.joined(separator: ctx.style.dim(" · "))
            let room = max(10, ctx.width - 9 - (meta.isEmpty ? 0 : TerminalText.width(metaText) + 2))
            let title = TerminalText.truncate(row.title, to: room)
            return "\(box) \(number) \(row.completed ? ctx.style.dim(title) : title)" + (meta.isEmpty ? "" : "  " + metaText)
        }
    }

    static func relativeDay(_ date: Date, now: Date) -> String {
        let calendar = JournalDates.calendar
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "今天"
        case 1: return "明天"
        case -1: return "昨天"
        default:
            let c = calendar.dateComponents([.month, .day], from: date)
            return "\(c.month ?? 0)月\(c.day ?? 0)日"
        }
    }

    public static func brief(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (h, m) = (total / 3600, (total % 3600) / 60)
        if h > 0 { return m > 0 ? "\(h) 小时 \(m) 分" : "\(h) 小时" }
        if m > 0 { return "\(m) 分钟" }
        return "\(total) 秒"
    }
}
