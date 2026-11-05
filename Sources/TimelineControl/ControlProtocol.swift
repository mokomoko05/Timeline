import Foundation

/// 命令行 `tl` 和 Timeline 之间的终端控制协议：每个连接发一行 JSON 请求，收一行 JSON 应答，然后断开。
public enum ControlProtocol {
    public static let version = 1
    /// 每个窗格的 shell 里都有这两个变量：`tl` 不带 `-t` 时默认操作自己所在的窗格。
    public static let socketEnvironmentKey = "TIMELINE_SOCKET"
    public static let paneEnvironmentKey = "TIMELINE_PANE_ID"
    public static let bundleIdentifier = "local.timeline.app"
    /// 单条消息上限（send 的文本、read 的回滚内容都在这里面）。
    public static let maxMessageBytes = 16 << 20

    /// 默认 socket 放在数据目录里（与 Journal 相同：`TIMELINE_DATA_DIR` 可以覆盖）。
    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let directory: URL
        if let override = environment["TIMELINE_DATA_DIR"], !override.isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Timeline", isDirectory: true)
        }
        return directory.appendingPathComponent("control.sock").path
    }

    /// 命令行实际连接的地址：shell 里注入的 `TIMELINE_SOCKET` 优先。
    public static func clientSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let path = environment[socketEnvironmentKey], !path.isEmpty { return path }
        return socketPath(environment: environment)
    }
}

public struct ControlRequest: Codable, Equatable, Sendable {
    public var command: String
    /// 目标窗格；为空时由 Timeline 取当前窗格。
    public var pane: String?
    public var text: String?
    /// send：是否在文本后按回车（默认是）。
    public var enter: Bool?
    /// split：right / down。
    public var direction: String?
    /// new：tab / window。
    public var kind: String?
    public var cwd: String?
    /// new / split：新窗格启动后要执行的命令。
    public var run: String?
    /// read：只取最后几行（可以跨进回滚区）。
    public var lines: Int?
    /// read：包含全部回滚内容。
    public var scrollback: Bool?
    /// close：前台有程序在运行也关闭。
    public var force: Bool?

    public init(command: String, pane: String? = nil, text: String? = nil, enter: Bool? = nil, direction: String? = nil,
                kind: String? = nil, cwd: String? = nil, run: String? = nil, lines: Int? = nil, scrollback: Bool? = nil, force: Bool? = nil) {
        self.command = command
        self.pane = pane
        self.text = text
        self.enter = enter
        self.direction = direction
        self.kind = kind
        self.cwd = cwd
        self.run = run
        self.lines = lines
        self.scrollback = scrollback
        self.force = force
    }
}

public struct PaneInfo: Codable, Equatable, Sendable {
    public var id: String
    public var pid: Int32
    public var cwd: String?
    /// 前台有程序在运行（不是停在 shell 提示符）。
    public var busy: Bool
    /// 所在窗口里当前选中的窗格。
    public var focused: Bool
    public var cols: Int
    public var rows: Int

    public init(id: String, pid: Int32, cwd: String?, busy: Bool, focused: Bool, cols: Int, rows: Int) {
        self.id = id
        self.pid = pid
        self.cwd = cwd
        self.busy = busy
        self.focused = focused
        self.cols = cols
        self.rows = rows
    }
}

public struct WindowInfo: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var visible: Bool
    /// 嵌在 Timeline 主窗口里的终端页。
    public var workspace: Bool
    /// 同一组原生标签页共用的编号（组里第一个窗口的 id）；不在标签组里为空。
    public var tabGroup: String?
    public var panes: [PaneInfo]

    public init(id: String, title: String, visible: Bool, workspace: Bool, tabGroup: String?, panes: [PaneInfo]) {
        self.id = id
        self.title = title
        self.visible = visible
        self.workspace = workspace
        self.tabGroup = tabGroup
        self.panes = panes
    }
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    /// 机器可读的错误类别：usage / not_found / busy / failed / disabled。
    public var code: String?
    public var windows: [WindowInfo]?
    /// new / split 新建的窗格。
    public var panes: [String]?
    public var text: String?

    public init(ok: Bool = true, error: String? = nil, code: String? = nil, windows: [WindowInfo]? = nil, panes: [String]? = nil, text: String? = nil) {
        self.ok = ok
        self.error = error
        self.code = code
        self.windows = windows
        self.panes = panes
        self.text = text
    }

    public static func failure(_ message: String, code: String) -> ControlResponse {
        ControlResponse(ok: false, error: message, code: code)
    }
}
