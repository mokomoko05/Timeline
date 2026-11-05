import Foundation

/// `tl help` 的中英文说明。占位符用 ASCII（<pane>、<dir>…），中英混排时各列仍能对齐。
public enum ControlHelp {
    struct Option {
        let flags: String
        let zh: String
        let en: String
    }

    struct Command {
        let name: String
        let synopsis: String
        let zh: String
        let en: String
        /// 详细说明（tl help <命令>），一条一段。
        let details: [(zh: String, en: String)]
        let options: [Option]
        let examples: [String]
    }

    static let paneOption = Option(flags: "-t, --pane <pane>", zh: "目标窗格（如 p3）", en: "Target pane (e.g. p3)")
    static let cwdOption = Option(flags: "--cwd <dir>", zh: "起始目录（默认继承目标窗格的目录）", en: "Start directory (defaults to the target pane's)")

    static let commands: [Command] = [
        Command(name: "ls", synopsis: "tl ls [--json]",
                zh: "列出终端窗口和窗格", en: "List terminal windows and panes",
                details: [("每个窗格一行：编号、空闲 / 运行中、列x行、shell 的 pid、当前目录；* 是窗口里选中的窗格。",
                           "One line per pane: ID, idle / busy, cols x rows, shell pid, current directory; * marks the window's selected pane.")],
                options: [], examples: ["tl ls", "tl ls --json"]),
        Command(name: "new", synopsis: "tl new [--tab|--window] [-t <pane>] [--cwd <dir>] [-- <cmd>...]",
                zh: "新建终端窗口或标签页", en: "Open a new terminal window or tab",
                details: [("输出新窗格的编号，每行一个（三窗格布局会输出三个）。-- 之后的命令在第一个新窗格里执行。",
                           "Prints the new pane IDs, one per line (three for the three-pane layout). The command after -- runs in the first new pane.")],
                options: [Option(flags: "--window", zh: "新建独立窗口（默认）", en: "New standalone window (default)"),
                          Option(flags: "--tab", zh: "在目标窗格所在窗口里新开标签页", en: "New tab in the target pane's window"),
                          paneOption, cwdOption],
                examples: ["tl new", "tl new --tab --cwd ~/repo -- git status"]),
        Command(name: "split", synopsis: "tl split [--right|--down] [-t <pane>] [--cwd <dir>] [-- <cmd>...]",
                zh: "把窗格分成两个", en: "Split a pane in two",
                details: [("新窗格拿走目标窗格一半的空间并获得焦点，输出它的编号。窗格太小时拒绝分栏。",
                           "The new pane takes half of the target's space and gets focus; its ID is printed. Panes that are too small refuse to split.")],
                options: [Option(flags: "-r, --right", zh: "向右分栏（默认）", en: "Split to the right (default)"),
                          Option(flags: "-d, --down", zh: "向下分栏", en: "Split downward"),
                          paneOption, cwdOption],
                examples: ["tl split", "p=$(tl split --down -- npm test)"]),
        Command(name: "focus", synopsis: "tl focus [<pane>]",
                zh: "显示并选中窗格", en: "Show and select a pane",
                details: [("把窗格所在的窗口（标签页）带到前台，并把键盘焦点放到这个窗格。",
                           "Brings the pane's window (tab) to the front and gives the pane keyboard focus.")],
                options: [paneOption], examples: ["tl focus p3"]),
        Command(name: "close", synopsis: "tl close [<pane>] [--force]",
                zh: "关闭窗格", en: "Close a pane",
                details: [("结束窗格里的 shell，其余窗格补位；最后一个窗格关闭时整个窗口一起关。",
                           "Ends the pane's shell and lets the other panes fill in; closing the last pane closes the window."),
                          ("窗格里有程序在前台运行时会拒绝，需要加 --force。关闭 tl 自己所在的窗格不需要 --force。",
                           "Refuses while a program runs in the foreground unless --force is given. Closing the pane tl runs in needs no --force.")],
                options: [Option(flags: "-f, --force", zh: "有程序在运行也关闭", en: "Close even if a program is running"), paneOption],
                examples: ["tl close p3", "tl close p3 --force"]),
        Command(name: "send", synopsis: "tl send [-t <pane>] [--no-enter] [<text>...]",
                zh: "向窗格输入文字", en: "Type text into a pane",
                details: [("多个参数用空格连起来，末尾自动回车。没给文字时读标准输入。",
                           "Arguments are joined with spaces and Enter is pressed at the end. Reads standard input when no text is given.")],
                options: [Option(flags: "-n, --no-enter", zh: "只输入，不回车", en: "Type without pressing Enter"), paneOption],
                examples: ["tl send -t p3 git status", "echo 'make test' | tl send -t p3"]),
        Command(name: "read", synopsis: "tl read [<pane>] [--lines <N>] [--scrollback]",
                zh: "读取窗格里的文字", en: "Read text from a pane",
                details: [("默认输出窗格当前屏幕的内容，去掉末尾空行。",
                           "Prints what is currently on the pane's screen, without trailing blank lines.")],
                options: [Option(flags: "-l, --lines <N>", zh: "只要最后 N 行（可以跨进回滚区）", en: "Only the last N lines (may reach into scrollback)"),
                          Option(flags: "-s, --scrollback", zh: "包含全部回滚内容", en: "Include the whole scrollback"),
                          paneOption],
                examples: ["tl read p3", "tl read p3 --lines 50"]),
        Command(name: "show", synopsis: "tl show",
                zh: "显示全部终端", en: "Show all terminals",
                details: [("和终端全局快捷键的「显示」一样；没有终端时新开一个。",
                           "Same as showing them with the terminal hotkey; opens one if none exist.")],
                options: [], examples: ["tl show"]),
        Command(name: "hide", synopsis: "tl hide",
                zh: "收起全部终端", en: "Hide all terminals",
                details: [("只是收起，里面的程序继续运行。", "Only hides them; programs inside keep running.")],
                options: [], examples: ["tl hide"]),
        Command(name: "help", synopsis: "tl help [<command>]",
                zh: "显示这份说明", en: "Show this help",
                details: [("也可以写成 tl <命令> --help。", "Also available as tl <command> --help.")],
                options: [], examples: ["tl help split"]),
    ]

    static func command(named name: String) -> Command? { commands.first { $0.name == name } }

    private static func optionLines(_ options: [Option]) -> String {
        let width = (options.map(\.flags.count).max() ?? 0) + 3
        return options.map { option in
            let flags = "  " + option.flags.padding(toLength: width, withPad: " ", startingAt: 0)
            return flags + option.zh + "\n" + String(repeating: " ", count: flags.count) + option.en + "\n"
        }.joined()
    }

    /// 总览：tl help。
    public static var overview: String {
        let width = (commands.map(\.name.count).max() ?? 0) + 4
        var text = """
        tl — 管理 Timeline 内置终端 / Manage Timeline's built-in terminals

        用法 Usage:
          tl <command> [options]

        命令 Commands:

        """
        for command in commands {
            let name = "  " + command.name.padding(toLength: width, withPad: " ", startingAt: 0)
            text += name + command.zh + "\n" + String(repeating: " ", count: name.count) + command.en + "\n"
        }
        text += "\n通用选项 Global options:\n" + optionLines([
            Option(flags: "-t, --pane <pane>", zh: "目标窗格（如 p3）；默认是 tl 所在的窗格，在 Timeline 终端外是当前窗格",
                   en: "Target pane (e.g. p3); defaults to the pane tl runs in, or the current pane outside Timeline"),
            Option(flags: "--json", zh: "输出原始 JSON 应答", en: "Print the raw JSON response"),
            Option(flags: "-h, --help", zh: "显示说明", en: "Show help"),
        ])
        text += """

        环境变量 Environment:
          TIMELINE_PANE_ID   tl 所在窗格的编号（Timeline 为每个窗格设置）
                             ID of the pane tl runs in (set by Timeline for every pane)
          TIMELINE_SOCKET    控制 socket 路径（默认在 Timeline 数据目录里）
                             Control socket path (defaults to Timeline's data directory)

        退出码 Exit codes:
          0  成功 / Success
          1  Timeline 报错（如找不到窗格、窗格忙） / Timeline reported an error (unknown pane, busy pane…)
          2  用法错误 / Usage error
          3  连不上 Timeline / Cannot reach Timeline

        示例 Examples:
          tl ls
          p=$(tl split --down -- npm test)
          tl read -t "$p" --lines 20
          tl close "$p" --force

        Timeline 没在运行时，tl 会在后台启动它。可以在 Timeline 设置里关闭命令行控制。
        tl starts Timeline in the background if it is not running. Command-line control can be turned off in Timeline's settings.

        运行 tl help <command> 查看某个命令的详细说明。
        Run `tl help <command>` for details on a command.

        """
        return text
    }

    /// 单个命令：tl help <命令>。
    public static func help(for name: String) -> String? {
        guard let command = command(named: name) else { return nil }
        var text = "用法 Usage:\n  \(command.synopsis)\n\n\(command.zh)\n\(command.en)\n"
        for detail in command.details { text += "\n\(detail.zh)\n\(detail.en)\n" }
        if !command.options.isEmpty { text += "\n选项 Options:\n" + optionLines(command.options) }
        if !command.examples.isEmpty { text += "\n示例 Examples:\n" + command.examples.map { "  \($0)\n" }.joined() }
        return text
    }

    /// 用法错误时附在后面的一行提示。
    public static let hint = "运行 tl help 查看用法。 Run `tl help` for usage."
}
