import Foundation

public struct ControlUsageError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum ControlInvocation: Equatable {
    /// nil 是总览；否则是某个命令的说明。
    case help(String?)
    case run(ControlRequest, json: Bool)
}

/// `tl` 的参数解析和输出格式。放在共享模块里，单元测试可以直接测。
public enum ControlCommandLine {
    private static let commands: Set<String> = ["ls", "new", "split", "focus", "close", "send", "read", "attach", "show", "hide", "ping"]
    /// 这些命令作用在某个窗格上：没写 -t 时用自己所在的窗格。
    private static let paneCommands: Set<String> = ["new", "split", "focus", "close", "send", "read"]
    /// 允许直接写窗格编号作为位置参数的命令。
    private static let positionalPane: Set<String> = ["focus", "close", "read", "attach"]

    public static func parse(_ arguments: [String], environment: [String: String], currentDirectory: String,
                             readStandardInput: () -> String? = { nil }) throws -> ControlInvocation {
        guard let command = arguments.first else { return .help(nil) }
        if ["help", "-h", "--help"].contains(command) {
            guard let topic = arguments.dropFirst().first else { return .help(nil) }
            guard ControlHelp.command(named: topic) != nil else { throw ControlUsageError("没有这个命令：\(topic)  Unknown command: \(topic)") }
            return .help(topic)
        }
        guard commands.contains(command) else { throw ControlUsageError("未知命令：\(command)  Unknown command: \(command)") }
        // tl <命令> --help：在解析其余参数之前处理（send 会把未知的 - 开头参数当作文字）。
        if arguments.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" }), !arguments.contains("--"), ControlHelp.command(named: command) != nil {
            return .help(command)
        }
        var request = ControlRequest(command: command)
        var json = false
        var positionals: [String] = []
        var trailing: [String]?
        var index = 1
        func value(_ option: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw ControlUsageError("\(option) 需要一个值  \(option) needs a value") }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--": trailing = Array(arguments[(index + 1)...]); index = arguments.count; continue
            case "--json": json = true
            case "-t", "--pane", "--target": request.pane = try value(argument)
            case "--tab": request.kind = "tab"
            case "--window": request.kind = "window"
            case "-r" where command == "attach", "--read-only": request.readOnly = true
            case "-r", "--right": request.direction = "right"
            case "-d", "--down": request.direction = "down"
            case "--cwd": request.cwd = resolve(try value(argument), currentDirectory: currentDirectory, environment: environment)
            case "-f", "--force": request.force = true
            case "-n", "--no-enter": request.enter = false
            case "-s", "--scrollback": request.scrollback = true
            case "--history":
                let raw = try value(argument)
                guard let lines = Int(raw), lines >= 0 else { throw ControlUsageError("--history 需要非负整数：\(raw)  --history needs a non-negative integer: \(raw)") }
                request.history = lines
            case "-l", "--lines":
                let raw = try value(argument)
                guard let lines = Int(raw), lines > 0 else { throw ControlUsageError("--lines 需要正整数：\(raw)  --lines needs a positive integer: \(raw)") }
                request.lines = lines
            default:
                if argument.hasPrefix("-"), argument.count > 1, command != "send" { throw ControlUsageError("未知选项：\(argument)  Unknown option: \(argument)") }
                positionals.append(argument)
            }
            index += 1
        }
        switch command {
        case "send":
            let text = positionals.isEmpty && trailing == nil ? readStandardInput() : (positionals + (trailing ?? [])).joined(separator: " ")
            guard let text, !text.isEmpty else { throw ControlUsageError("send 需要文本（参数或标准输入）  send needs text (arguments or standard input)") }
            request.text = text
        case "new", "split":
            guard positionals.isEmpty else { throw ControlUsageError("多余的参数：\(positionals.joined(separator: " "))；要执行的命令请写在 -- 之后  Unexpected arguments; put the command after --") }
            if let trailing, !trailing.isEmpty { request.run = trailing.joined(separator: " ") }
        default:
            if positionalPane.contains(command), positionals.count == 1, request.pane == nil {
                request.pane = positionals[0]
            } else if !positionals.isEmpty || trailing != nil {
                throw ControlUsageError("多余的参数：\((positionals + (trailing ?? [])).joined(separator: " "))  Unexpected arguments")
            }
        }
        let ownPane = environment[ControlProtocol.paneEnvironmentKey].flatMap { $0.isEmpty ? nil : $0 }
        if paneCommands.contains(command), request.pane == nil { request.pane = ownPane }
        if command == "attach", let ownPane {
            // 在 Timeline 的终端里 attach 自己所在的窗格，输出会无限回环。
            guard let target = request.pane else {
                throw ControlUsageError("在 Timeline 终端里请用 -t 指定要 attach 的窗格  Inside a Timeline terminal, choose a pane with -t")
            }
            if target == ownPane { throw ControlUsageError("不能 attach 到 tl 自己所在的窗格 \(ownPane)  Cannot attach to the pane tl runs in (\(ownPane))") }
        }
        // 关闭自己所在的窗格：前台程序就是 tl 自己，不算「有程序在运行」。
        if command == "close", let ownPane, request.pane == ownPane { request.force = true }
        return .run(request, json: json)
    }

    static func resolve(_ path: String, currentDirectory: String, environment: [String: String]) -> String {
        var expanded = path
        if expanded == "~" || expanded.hasPrefix("~/") {
            let home = environment["HOME"] ?? NSHomeDirectory()
            expanded = home + expanded.dropFirst()
        }
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: currentDirectory, isDirectory: true)).standardizedFileURL.path
    }

    /// 人看的输出；`--json` 时直接输出应答，不走这里。
    public static func format(_ response: ControlResponse, for request: ControlRequest, home: String = NSHomeDirectory()) -> String {
        switch request.command {
        case "ls":
            let windows = response.windows ?? []
            if windows.isEmpty { return "（没有终端窗口）\n" }
            var output = ""
            for window in windows {
                var flags = [window.visible ? "显示中" : "已收起"]
                if window.workspace { flags.append("主窗口") }
                if let group = window.tabGroup { flags.append("标签组 \(group)") }
                output += "\(window.id)  \(window.title)  (\(flags.joined(separator: ", ")))\n"
                for pane in window.panes {
                    let cwd = pane.cwd.map { $0 == home ? "~" : ($0.hasPrefix(home + "/") ? "~" + $0.dropFirst(home.count) : $0) } ?? "?"
                    let marker = pane.focused ? "*" : " "
                    let state = pane.busy ? "运行中" : "空闲"
                    let attached = (pane.attached ?? 0) > 0 ? "  attach ×\(pane.attached ?? 0)" : ""
                    output += "  \(marker) \(pane.id.padding(toLength: 4, withPad: " ", startingAt: 0))  \(state)  \(pane.cols)x\(pane.rows)  pid \(pane.pid)  \(cwd)\(attached)\n"
                }
            }
            return output
        case "new", "split":
            return (response.panes ?? []).map { $0 + "\n" }.joined()
        case "read":
            guard let text = response.text, !text.isEmpty else { return "" }
            return text.hasSuffix("\n") ? text : text + "\n"
        default:
            return ""
        }
    }
}
