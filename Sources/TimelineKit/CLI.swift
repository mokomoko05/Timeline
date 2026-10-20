import Foundation
import TimelineCore

/// 命令行运行时的环境。全部可注入，所以命令的输出和行为可以直接在测试里验证。
public struct CLIEnvironment {
    public var arguments: [String]
    public var env: [String: String]
    public var stdoutIsTTY: Bool
    public var stdinIsTTY: Bool
    public var columns: Int?
    public var now: Date
    public var currentDirectory: String
    public var out: (String) -> Void
    public var err: (String) -> Void
    public var readStdin: () -> String
    /// 应用没在运行时怎么启动它；nil 表示不启动。
    public var launchApp: (() -> Void)?
    /// 交互式选择器；测试里替换。
    public var runPicker: @MainActor (PickerState, RenderContext, JournalStore) -> InteractivePicker.Outcome

    public init(arguments: [String], env: [String: String] = ProcessInfo.processInfo.environment,
                stdoutIsTTY: Bool = false, stdinIsTTY: Bool = false, columns: Int? = nil, now: Date = Date(),
                currentDirectory: String = FileManager.default.currentDirectoryPath,
                out: @escaping (String) -> Void = { print($0, terminator: "") }, err: @escaping (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) },
                readStdin: @escaping () -> String = { String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) },
                launchApp: (() -> Void)? = TimelineClient.openApp,
                runPicker: @escaping @MainActor (PickerState, RenderContext, JournalStore) -> InteractivePicker.Outcome = { state, ctx, store in
                    InteractivePicker.run(state: state, ctx: ctx, store: store) }) {
        self.arguments = arguments
        self.env = env
        self.stdoutIsTTY = stdoutIsTTY
        self.stdinIsTTY = stdinIsTTY
        self.columns = columns
        self.now = now
        self.currentDirectory = currentDirectory
        self.out = out
        self.err = err
        self.readStdin = readStdin
        self.launchApp = launchApp
        self.runPicker = runPicker
    }
}

/// 简单的参数解析：`--name value`、`--name=value`、`-t 3`、布尔开关、`--` 之后全是位置参数。
struct Arguments {
    var positional: [String] = []
    var values: [String: [String]] = [:]
    var flags: Set<String> = []
    var errors: [String] = []

    static let aliases: [String: String] = [
        "t": "task", "d": "date", "k": "kind", "g": "grep", "n": "last", "f": "format", "i": "image",
        "a": "all", "r": "reverse", "h": "help", "p": "print",
    ]
    static let valueOptions: Set<String> = ["task", "date", "since", "until", "kind", "grep", "last", "format", "dir", "socket", "color", "image", "tag", "priority"]

    init(_ arguments: [String]) {
        var index = 0
        var onlyPositional = false
        while index < arguments.count {
            let item = arguments[index]
            index += 1
            if onlyPositional || item == "-" || !item.hasPrefix("-") || Int(item) != nil { positional.append(item); continue }
            if item == "--" { onlyPositional = true; continue }
            var name = item.hasPrefix("--") ? String(item.dropFirst(2)) : String(item.dropFirst())
            var inline: String?
            if let equals = name.firstIndex(of: "=") { inline = String(name[name.index(after: equals)...]); name = String(name[..<equals]) }
            if !item.hasPrefix("--") { name = Self.aliases[name] ?? name }
            if Self.valueOptions.contains(name) {
                if let inline { values[name, default: []].append(inline) }
                else if index < arguments.count { values[name, default: []].append(arguments[index]); index += 1 }
                else { errors.append("选项 \(item) 需要一个值") }
            } else {
                flags.insert(name)
            }
        }
    }

    func value(_ name: String) -> String? { values[name]?.last }
    func has(_ name: String) -> Bool { flags.contains(name) }
}

public enum CLI {
    public static let version = "0.0.1"

    @MainActor
    public static func main() -> Int32 {
        let env = CLIEnvironment(arguments: Array(CommandLine.arguments.dropFirst()),
                                 stdoutIsTTY: isatty(STDOUT_FILENO) != 0, stdinIsTTY: isatty(STDIN_FILENO) != 0,
                                 columns: isatty(STDOUT_FILENO) != 0 ? RawTerminal.size().columns : nil)
        return run(env)
    }

    static let usage = """
    timeline — Timeline 的命令行：在终端里查看笔记、日志，并通过运行中的应用写入。

    查看（直接读数据文件，应用不需要在运行）
      timeline logs [筛选]          日志列表，按日期分组
      timeline show <id>            一条日志的完整内容，含图片（id 来自 logs，可只写唯一前缀）
      timeline notes <任务编号|标签> 某个任务或某个标签名下的全部笔记（--md 输出 Markdown）；标签直接写名字，或加引号 '#标签'
      timeline tasks [--all] [--tag 标签]   任务列表（编号、截止、笔记数、专注时长、标签）
      timeline tags                 所有标签：待办数、笔记数
      timeline pick [筛选]          交互式选择：↑↓ 移动，/ 搜索，回车查看，q 退出
      timeline status               数据概况，以及应用是否在运行

    写入（经运行中的应用；应用没开会自动启动，--no-launch 关闭）
      timeline log [-t N] [-i 图片]... <正文>   记一条日志；正文可以 /done /block /plan 开头，也可以以 #3 开头关联任务；- 表示读标准输入
      timeline todo <内容>          添加待办，支持「明天 15:00 开会 #标签」（#标签 要加引号，bash 里 # 会被当成注释）
      timeline done <N>             完成任务 #N
      timeline undone <N>           取消完成任务 #N（放弃的也用它恢复）
      timeline drop <N>             放弃任务 #N（不用做了，留着记录；再来一次恢复）
      timeline priority <N> <urgent|high|normal|lower|low>  设置任务优先级；todo 可加 --priority high

    筛选（logs / pick / notes 通用）
      -t, --task N[,N]           只看这些任务的日志        -d, --date D       只看某一天
      --tag 标签                 只看带这个标签（含子标签）的待办名下的日志
      --since D  --until D       日期范围                  -k, --kind K       note|done|block|plan
      -g, --grep 文字            搜索正文、任务标题和截图里识别出的文字
      --with-images              只看带图片的              --focus            包含专注计时记录
      -n, --last N               只看最近 N 条（无筛选时默认 30）    -a, --all  不限条数      -r, --reverse  倒序
      日期写法：2026-10-07、10-07、today、yesterday、7d（7 天前）

    输出
      --md / --json / --porcelain    Markdown / JSON / 制表符分隔（给 fzf、awk；列：id 日期 时间 类型 #任务 正文）
      --images                   logs 里直接显示图片（show 总是显示）
      --color always|never|auto  --no-color

    其他
      --dir 目录       数据目录（默认 ~/Library/Application Support/Timeline，或环境变量 TIMELINE_DATA_DIR）
      --socket 路径    通信 socket（默认在数据目录里）
      --no-launch      写入时不自动启动应用
      timeline --version | --help

    配合 fzf：  timeline logs --porcelain -a | fzf --delimiter '\\t' --with-nth 2.. --preview 'timeline show {1}'
    """

    @MainActor
    public static func run(_ environment: CLIEnvironment) -> Int32 {
        var context = Context(environment)
        return context.run()
    }

    // MARK: - 内部上下文

    struct Context {
        let env: CLIEnvironment
        let args: Arguments
        var directory: URL

        init(_ environment: CLIEnvironment) {
            env = environment
            args = Arguments(environment.arguments)
            let base = args.value("dir").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? JournalStore.defaultDirectory(environment: environment.env)
            directory = base
        }

        func say(_ text: String = "") { env.out(text + "\n") }
        func fail(_ text: String, code: Int32 = 1) -> Int32 { env.err("timeline: \(text)\n"); return code }

        var width: Int { max(40, env.columns ?? Int(env.env["COLUMNS"] ?? "") ?? 80) }

        var style: Style {
            switch args.value("color") {
            case "always": return Style(enabled: true)
            case "never": return .plain
            default: break
            }
            if args.has("no-color") || env.env["NO_COLOR"] != nil || env.env["TERM"] == "dumb" { return .plain }
            return Style(enabled: env.stdoutIsTTY)
        }

        func renderContext(forImages: Bool) -> RenderContext {
            let protocolKind: ImageProtocol = (env.stdoutIsTTY && forImages) ? ImageProtocol.detect(env.env) : .none
            return RenderContext(width: width, style: style, imageProtocol: protocolKind, imagesDirectory: directory.appendingPathComponent("Images", isDirectory: true))
        }

        var socketPath: String { args.value("socket") ?? TimelineWire.socketPath(directory: directory) }

        @MainActor
        func openStore() -> JournalStore? {
            let store = JournalStore(directory: directory, readOnlySnapshot: true)
            if let message = store.errorMessage { env.err("timeline: \(message)\n"); return nil }
            return store
        }

        // MARK: 分发

        @MainActor
        mutating func run() -> Int32 {
            if let problem = args.errors.first { return fail(problem, code: 2) }
            if args.has("version") { say("timeline \(CLI.version)"); return 0 }
            guard let command = args.positional.first else {
                env.out(CLI.usage + "\n")
                return args.has("help") ? 0 : 2
            }
            if args.has("help") || command == "help" { env.out(CLI.usage + "\n"); return 0 }
            let rest = Array(args.positional.dropFirst())
            switch command {
            case "logs", "log-list", "ls": return logs()
            case "show": return show(rest)
            case "notes": return notes(rest)
            case "tasks": return tasks()
            case "tags": return tags()
            case "pick": return pick()
            case "status": return status()
            case "log": return write(.log, rest)
            case "todo": return write(.todo, rest)
            case "done": return write(.done, rest)
            case "undone": return write(.undone, rest)
            case "drop": return write(.drop, rest)
            case "priority": return write(.priority, rest)
            default: return fail("不认识的命令「\(command)」。运行 timeline help 查看用法。", code: 2)
            }
        }

        // MARK: 筛选

        func filter(forTask forced: Int? = nil) -> (LogFilter, String?) {
            var filter = LogFilter()
            func list(_ name: String) -> [String] { (args.values[name] ?? []).flatMap { $0.split(whereSeparator: { $0 == "," || $0 == "，" }).map(String.init) } }
            for token in list("task") {
                guard let number = LogCommand.taskNumber(token) else { return (filter, "任务编号「\(token)」不对，应该是 3 或 #3") }
                filter.tasks.insert(number)
            }
            if let forced { filter.tasks = [forced] }
            for token in list("kind") {
                guard let kind = DailyLogKind(rawValue: token.lowercased()) else { return (filter, "类型「\(token)」不对，可选 note、done、block、plan") }
                filter.kinds.insert(kind)
            }
            if let text = args.value("tag") {
                guard let tag = TagText.normalize(text) else { return (filter, "标签「\(text)」不对：不能含空格，也不能是纯数字") }
                filter.tag = tag
            }
            if let text = args.value("date") {
                guard let day = DateArgument.parse(text, now: env.now) else { return (filter, "日期「\(text)」看不懂，可以写 2026-10-07、10-07、today、yesterday、7d") }
                filter.since = day
                filter.until = day
            }
            if let text = args.value("since") {
                guard let day = DateArgument.parse(text, now: env.now) else { return (filter, "日期「\(text)」看不懂") }
                filter.since = day
            }
            if let text = args.value("until") {
                guard let day = DateArgument.parse(text, now: env.now) else { return (filter, "日期「\(text)」看不懂") }
                filter.until = day
            }
            filter.grep = args.value("grep")
            filter.includeFocus = args.has("focus")
            filter.onlyWithImages = args.has("with-images")
            filter.reverse = args.has("reverse")
            if let text = args.value("last") {
                guard let n = Int(text), n >= 0 else { return (filter, "-n 需要一个非负整数") }
                filter.last = n
            } else if filter.isEmpty, !args.has("all") {
                filter.last = 30
            }
            return (filter, nil)
        }

        func format() -> String {
            if args.has("md") { return "md" }
            if args.has("json") { return "json" }
            if args.has("porcelain") { return "porcelain" }
            return args.value("format") ?? "text"
        }

        func emit(rows: [LogRow], title: String, images: Bool) -> Int32 {
            switch format() {
            case "json": say(LogRenderer.json(rows))
            case "porcelain": LogRenderer.porcelain(rows).forEach { say($0) }
            case "md", "markdown": say(LogRenderer.markdown(title: title, rows: rows))
            case "text":
                if rows.isEmpty { env.err("没有符合条件的日志。\n"); return 0 }
                LogRenderer.list(rows, ctx: renderContext(forImages: images), showImages: images).forEach { say($0) }
            default: return fail("不认识的输出格式「\(format())」，可选 text、md、json、porcelain", code: 2)
            }
            return 0
        }

        // MARK: 读命令

        @MainActor
        func logs() -> Int32 {
            let (filter, problem) = filter()
            if let problem { return fail(problem, code: 2) }
            guard let store = openStore() else { return 1 }
            let rows = LogQuery.rows(in: store, filter: filter)
            return emit(rows: rows, title: "日志", images: args.has("images"))
        }

        @MainActor
        func show(_ rest: [String]) -> Int32 {
            guard let reference = rest.first else { return fail("用法：timeline show <id>（id 见 timeline logs --porcelain 的第一列）", code: 2) }
            guard let store = openStore() else { return 1 }
            switch LogQuery.lookup(reference, in: store) {
            case .notFound: return fail("找不到日志「\(reference)」。id 至少写 3 位，来自 timeline logs。")
            case .ambiguous(let ids): return fail("「\(reference)」匹配了多条日志：\(ids.joined(separator: " "))，请多写几位。")
            case .found(let id):
                var filter = LogFilter()
                filter.includeFocus = true
                guard let row = LogQuery.rows(in: store, filter: filter).first(where: { $0.id == id }) else { return fail("找不到日志「\(reference)」。") }
                switch format() {
                case "json": say(LogRenderer.json([row]))
                case "porcelain": LogRenderer.porcelain([row]).forEach { say($0) }
                case "md", "markdown": say(LogRenderer.markdown(title: "日志 \(row.shortID)", rows: [row]))
                default: LogRenderer.detail(row, ctx: renderContext(forImages: true)).forEach { say($0) }
                }
                return 0
            }
        }

        @MainActor
        func notes(_ rest: [String]) -> Int32 {
            let usage = "用法：timeline notes <任务编号|标签>，例如 timeline notes 3 或 timeline notes 论文"
            guard let token = rest.first else { return fail(usage, code: 2) }
            if LogCommand.taskNumber(token) == nil {
                guard let tag = TagText.normalize(token) else { return fail(usage, code: 2) }
                return tagNotes(tag)
            }
            guard let number = LogCommand.taskNumber(token) else { return fail(usage, code: 2) }
            guard let store = openStore() else { return 1 }
            let (filter, problem) = filter(forTask: number)
            if let problem { return fail(problem, code: 2) }
            var effective = filter
            effective.notebookOnly = true
            if args.value("last") == nil { effective.last = nil }   // 笔记默认看全部
            let rows = LogQuery.rows(in: store, filter: effective)
            let located = store.locate(number: number)
            let title = "#\(number) " + (located.map { String(TaskText.rendered($0.task.title).characters) } ?? rows.last?.taskTitle ?? "（任务已删除）")
            if format() == "text" {
                let ctx = renderContext(forImages: args.has("images"))
                say(ctx.style.bold(TerminalText.truncate(title, to: width)))
                var meta: [String] = ["\(rows.count) 条笔记"]
                if let located {
                    if located.task.isDropped { meta.append("已放弃") } else if located.task.completed { meta.append("已完成") }
                    if let due = located.task.dueDate { meta.append("截止 \(LogRenderer.relativeDay(due, now: env.now))") }
                    if located.task.focusSeconds >= 1 { meta.append("已专注 \(LogRenderer.brief(located.task.focusSeconds))") }
                    if !located.task.tags.isEmpty { meta.append(located.task.tags.map { "#" + $0 }.joined(separator: " ")) }
                }
                say(ctx.style.dim(meta.joined(separator: " · ")))
                say()
                if rows.isEmpty { env.err("这个任务名下还没有笔记。\n"); return 0 }
                LogRenderer.list(rows, ctx: ctx, showImages: args.has("images")).forEach { say($0) }
                return 0
            }
            return emit(rows: rows, title: title, images: args.has("images"))
        }

        /// 某个标签（含子标签）名下所有待办的笔记。
        @MainActor
        func tagNotes(_ tag: String) -> Int32 {
            guard let store = openStore() else { return 1 }
            var (effective, problem) = filter()
            if let problem { return fail(problem, code: 2) }
            effective.tag = tag
            effective.notebookOnly = true
            if args.value("last") == nil { effective.last = nil }
            let rows = LogQuery.rows(in: store, filter: effective)
            let tasks = store.tasks(taggedWith: tag)
            if tasks.isEmpty, rows.isEmpty, !store.allTags().contains(where: { $0.id == TagText.key(tag) }) { return fail("没有标签「\(tag)」。运行 timeline tags 查看所有标签；任务编号请直接写数字，例如 timeline notes 3。", code: 1) }
            let title = "#" + tag
            if format() == "text" {
                let ctx = renderContext(forImages: args.has("images"))
                say(ctx.style.bold(TerminalText.truncate(title, to: width)))
                say(ctx.style.dim("\(tasks.count) 个待办（\(tasks.filter { !$0.task.completed }.count) 个未完成） · \(rows.count) 条笔记"))
                for item in tasks {
                    let box = item.task.isDropped ? ctx.style.gray("✗") : (item.task.completed ? ctx.style.green("✓") : ctx.style.gray("○"))
                    let name = (item.task.number.map { "#\($0) " } ?? "") + String(TaskText.rendered(item.task.title).characters)
                    say("  \(box) " + TerminalText.truncate(name, to: max(10, width - 4)))
                }
                say()
                if rows.isEmpty { env.err("这个标签名下还没有笔记。\n"); return 0 }
                LogRenderer.list(rows, ctx: ctx, showImages: args.has("images")).forEach { say($0) }
                return 0
            }
            return emit(rows: rows, title: title, images: args.has("images"))
        }

        @MainActor
        func tags() -> Int32 {
            guard let store = openStore() else { return 1 }
            let all = store.allTags()
            if format() == "json" {
                let items: [[String: Any]] = all.map { ["tag": $0.name, "tasks": $0.taskCount, "open_tasks": $0.openCount, "notes": $0.noteCount] }
                let data = (try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("[]".utf8)
                say(String(decoding: data, as: UTF8.self))
                return 0
            }
            if all.isEmpty { env.err("还没有标签。添加待办时写 #标签，或在界面里点待办上的标签按钮。\n"); return 0 }
            let ctx = renderContext(forImages: false)
            let nameWidth = min(24, all.map { TerminalText.width("#" + $0.name) }.max() ?? 0)
            for tag in all {
                let name = TerminalText.truncate("#" + tag.name, to: nameWidth)
                let pad = String(repeating: " ", count: max(0, nameWidth - TerminalText.width(name)))
                let meta = "\(tag.taskCount) 个待办 · \(tag.noteCount) 条笔记"
                say(ctx.style.cyan(name) + pad + "  " + ctx.style.dim(meta))
            }
            return 0
        }

        @MainActor
        func tasks() -> Int32 {
            guard let store = openStore() else { return 1 }
            var rows = LogRenderer.taskRows(in: store, includeCompleted: args.has("all"))
            if let text = args.value("tag") {
                guard let tag = TagText.normalize(text) else { return fail("标签「\(text)」不对：不能含空格，也不能是纯数字", code: 2) }
                let numbers = Set(store.tasks(taggedWith: tag).compactMap(\.task.number))
                rows = rows.filter { numbers.contains($0.number) }
            }
            if format() == "json" {
                let items: [[String: Any]] = rows.map { row in
                    var item: [String: Any] = ["number": row.number, "title": row.title, "completed": row.completed, "dropped": row.dropped, "notes": row.noteCount, "focus_seconds": Int(row.focusSeconds), "tags": row.tags]
                    if let due = row.due { item["due"] = ISO8601DateFormatter().string(from: due) }
                    item["priority"] = row.priority.rawValue
                    item["due_has_time"] = row.dueHasTime
                    return item
                }
                let data = (try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("[]".utf8)
                say(String(decoding: data, as: UTF8.self))
                return 0
            }
            if rows.isEmpty { env.err("没有任务。\n"); return 0 }
            LogRenderer.tasks(rows, ctx: renderContext(forImages: false), now: env.now).forEach { say($0) }
            return 0
        }

        @MainActor
        func pick() -> Int32 {
            guard env.stdoutIsTTY, env.stdinIsTTY else {
                return fail("pick 需要交互式终端。脚本里请用 timeline logs --porcelain 配合 fzf。", code: 2)
            }
            var (filter, problem) = self.filter()
            if let problem { return fail(problem, code: 2) }
            if args.value("last") == nil { filter.last = nil }
            guard let store = openStore() else { return 1 }
            let rows = LogQuery.rows(in: store, filter: filter)
            if rows.isEmpty { env.err("没有符合条件的日志。\n"); return 0 }
            let state = PickerState(rows: rows, title: "日志", selectOnEnter: args.has("print"))
            let outcome = env.runPicker(state, renderContext(forImages: true), store)
            if let row = outcome.selected { say(row.shortID) }
            return 0
        }

        @MainActor
        func status() -> Int32 {
            let store = JournalStore(directory: directory, readOnlySnapshot: true)
            say("数据目录  \(directory.path)")
            if let message = store.errorMessage { say(style.red("数据读取失败：\(message)")); return 1 }
            let all = store.sortedTasks()
            let open = all.filter { !$0.task.completed }.count
            say("任务      \(open) 个未完成 / 共 \(all.count) 个")
            say("日志      \(store.allLogs(includeFocus: false).count) 条")
            var request = WireRequest(op: .status)
            request.version = TimelineWire.version
            let client = TimelineClient(socketPath: socketPath)
            switch client.send(request) {
            case .success(let response) where response.ok:
                say("应用      " + style.green("运行中") + (response.info?["version"].map { "（\($0)）" } ?? ""))
                if let focus = response.info?["focus"], !focus.isEmpty { say("专注中    #\(focus)") }
                return 0
            case .success(let response):
                say("应用      返回错误：\(response.error ?? "未知")")
                return 1
            case .failure(let error):
                say("应用      " + style.yellow("没有运行") + "（读取命令仍可用；写入命令会自动启动它）")
                _ = error
                return 0
            }
        }

        // MARK: 写命令

        @MainActor
        func write(_ op: WireRequest.Op, _ rest: [String]) -> Int32 {
            var request = WireRequest(op: op)
            switch op {
            case .log:
                var text = rest.joined(separator: " ")
                if text == "-" || (rest.isEmpty && !env.stdinIsTTY && (args.values["image"] ?? []).isEmpty) {
                    text = env.readStdin().trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let images = (args.values["image"] ?? []).map { path -> String in
                    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: env.currentDirectory, isDirectory: true))
                    return url.standardizedFileURL.path
                }
                if text.isEmpty, images.isEmpty { return fail("没有内容可记。用法：timeline log [-t N] [-i 图片] <正文>", code: 2) }
                request.text = text
                request.images = images.isEmpty ? nil : images
                if let token = args.value("task") {
                    guard let number = LogCommand.taskNumber(token) else { return fail("任务编号「\(token)」不对，应该是 3 或 #3", code: 2) }
                    request.task = number
                }
            case .todo:
                let text = rest.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return fail("用法：timeline todo <内容>，例如 timeline todo 明天 15:00 开会", code: 2) }
                request.text = text
                if let value = args.value("priority") {
                    guard let priority = TaskPriority(rawValue: value) else { return fail("优先级应为 urgent、high、normal、lower 或 low", code: 2) }
                    request.priority = priority
                }
            case .priority:
                guard rest.count == 2, let number = LogCommand.taskNumber(rest[0]),
                      let priority = TaskPriority(rawValue: rest[1]) else {
                    return fail("用法：timeline priority <N> <urgent|high|normal|lower|low>", code: 2)
                }
                request.task = number
                request.priority = priority
            case .done, .undone, .drop:
                guard let token = rest.first, let number = LogCommand.taskNumber(token) else { return fail("用法：timeline \(op.rawValue) <任务编号>", code: 2) }
                request.task = number
            default: return fail("内部错误", code: 2)
            }
            let client = TimelineClient(socketPath: socketPath, launch: args.has("no-launch") ? nil : env.launchApp)
            switch client.send(request) {
            case .failure(let error): return fail(error.localizedDescription)
            case .success(let response):
                guard response.ok else { return fail(response.error ?? "操作失败") }
                say(style.green("✓ ") + (response.message ?? "完成") + (response.logID.map { style.dim("  id " + $0) } ?? ""))
                return 0
            }
        }
    }
}
