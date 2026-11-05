import AppKit
import Darwin
import Foundation
import TimelineControl

enum ControlServerError: Error, Equatable {
    /// 另一个 Timeline 已经在这个路径上监听：不抢。
    case inUse
    case system(String, Int32)
}

/// 应用内的 Unix socket 服务：后台线程收发，每条请求切回主线程交给 handler。
/// 只接受同一用户的连接（socket 权限 0600，并用 getpeereid 核对）。
final class ControlServer: @unchecked Sendable {
    let path: String
    private let handler: @MainActor (ControlRequest) -> ControlResponse
    private let acceptQueue = DispatchQueue(label: "Timeline.ControlServer")
    private let connectionQueue = DispatchQueue(label: "Timeline.ControlServer.connection", qos: .userInitiated, attributes: .concurrent)
    private var source: DispatchSourceRead?

    init(path: String, handler: @escaping @MainActor (ControlRequest) -> ControlResponse) {
        self.path = path
        self.handler = handler
    }

    var isRunning: Bool { source != nil }

    func start() throws {
        guard source == nil else { return }
        if let fd = try? ControlSocket.connect(path: path, timeout: 1) {
            close(fd)
            throw ControlServerError.inUse
        }
        var address = try ControlSocket.address(path)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        let fd = try ControlSocket.makeSocket()
        func fail(_ call: String) -> ControlServerError {
            let code = errno
            close(fd)
            return .system(call, code)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw fail("bind") }
        guard chmod(path, 0o600) == 0 else { unlink(path); throw fail("chmod") }
        guard listen(fd, 16) == 0 else { unlink(path); throw fail("listen") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(fd) }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    func stop() {
        guard let source else { return }
        source.cancel()
        self.source = nil
        unlink(path)
    }

    deinit { stop() }

    private func acceptPending(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            ControlSocket.setTimeout(client, seconds: 10)
            connectionQueue.async { [weak self] in
                guard let self else { close(client); return }
                serve(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
        let response: ControlResponse
        do {
            let line = try ControlSocket.readLine(client)
            if let request = try? JSONDecoder().decode(ControlRequest.self, from: line) {
                let handler = handler
                response = DispatchQueue.main.sync { MainActor.assumeIsolated { handler(request) } }
            } else {
                response = .failure("无法解析的请求", code: "usage")
            }
        } catch {
            return
        }
        try? ControlSocket.writeAll(client, (try? ControlSocket.encodeLine(response)) ?? Data())
    }
}

// MARK: - 命令

extension ShellWindowController {
    func pane(withID id: String) -> PaneTerminalView? {
        for window in windows {
            if let pane = window.panes.first(where: { $0.paneID == id }) { return pane }
        }
        return nil
    }

    /// 处理一条来自 `tl` 的请求。没有指定窗格时用当前（最近使用的）终端窗口里选中的窗格。
    func handleControl(_ request: ControlRequest) -> ControlResponse {
        do { return try perform(request) } catch let failure as ControlFailure { return failure.response } catch {
            return .failure("\(error)", code: "failed")
        }
    }

    private struct ControlFailure: Error {
        let response: ControlResponse
        init(_ message: String, code: String) { response = .failure(message, code: code) }
    }

    private func perform(_ request: ControlRequest) throws -> ControlResponse {
        func target() throws -> PaneTerminalView {
            if let id = request.pane {
                guard let pane = pane(withID: id) else { throw ControlFailure("找不到窗格 \(id)", code: "not_found") }
                return pane
            }
            guard let pane = keyTerminal?.terminal as? PaneTerminalView else { throw ControlFailure("没有终端窗格", code: "not_found") }
            return pane
        }
        func directory() throws -> String? {
            guard let cwd = request.cwd else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ControlFailure("目录不存在：\(cwd)", code: "usage")
            }
            return cwd
        }
        func run(_ command: String?, in pane: PaneTerminalView) {
            if let command, !command.isEmpty { pane.send(txt: command + "\r") }
        }

        switch request.command {
        case "ping":
            return ControlResponse(text: "\(ControlProtocol.version)")
        case "ls":
            return ControlResponse(windows: windows.map(info(for:)))
        case "show":
            show()
            return ControlResponse()
        case "hide":
            hide()
            return ControlResponse()
        case "new":
            let cwd = try directory()
            let window: TerminalWindow
            switch request.kind ?? "window" {
            case "window": window = newWindow(directory: cwd)
            case "tab":
                let anchor = try request.pane.map { _ in try target() }.flatMap { self.window(for: $0) }
                window = newTab(beside: anchor, directory: cwd)
            default: throw ControlFailure("未知类型：\(request.kind ?? "")（tab / window）", code: "usage")
            }
            if let first = window.panes.first { run(request.run, in: first) }
            return ControlResponse(panes: window.panes.map(\.paneID))
        case "split":
            let source = try target()
            let cwd = try directory()
            let sideBySide: Bool
            switch request.direction ?? "right" {
            case "right": sideBySide = true
            case "down": sideBySide = false
            default: throw ControlFailure("未知方向：\(request.direction ?? "")（right / down）", code: "usage")
            }
            guard let pane = splitPane(sideBySide: sideBySide, from: source, directory: cwd) else {
                throw ControlFailure("窗格 \(source.paneID) 太小，不能再分", code: "failed")
            }
            run(request.run, in: pane)
            return ControlResponse(panes: [pane.paneID])
        case "focus":
            focus(try target())
            return ControlResponse()
        case "close":
            let pane = try target()
            guard let window = window(for: pane) else { throw ControlFailure("找不到窗格 \(pane.paneID)", code: "not_found") }
            if request.force != true, let process = pane.process,
               ShellProcessInfo.hasForegroundProgram(fd: process.childfd, shellPid: process.shellPid) {
                throw ControlFailure("窗格 \(pane.paneID) 里有程序在运行；确认要结束它请加 --force", code: "busy")
            }
            pane.end()
            finish(pane, in: window)
            return ControlResponse()
        case "send":
            guard let text = request.text, !text.isEmpty else { throw ControlFailure("send 需要文本", code: "usage") }
            try target().send(txt: request.enter == false ? text : text + "\r")
            return ControlResponse()
        case "read":
            return ControlResponse(text: try target().transcript(lines: request.lines, scrollback: request.scrollback == true))
        default:
            throw ControlFailure("未知命令：\(request.command)", code: "usage")
        }
    }

    private func info(for window: TerminalWindow) -> WindowInfo {
        let group = window.tabbedWindows.flatMap { $0.count > 1 ? ($0.first as? TerminalWindow)?.windowID : nil }
        let panes = window.panes.map { pane -> PaneInfo in
            let terminal = pane.getTerminal()
            let process = pane.process
            let pid = process?.shellPid ?? 0
            return PaneInfo(id: pane.paneID, pid: pid, cwd: ShellProcessInfo.currentDirectory(of: pid),
                            busy: process.map { ShellProcessInfo.hasForegroundProgram(fd: $0.childfd, shellPid: pid) } ?? false,
                            focused: pane === window.terminal, cols: terminal.cols, rows: terminal.rows)
        }
        return WindowInfo(id: window.windowID, title: window.title, visible: window.isVisible && window.terminalIsPresented,
                          workspace: window === workspaceWindow, tabGroup: group, panes: panes)
    }
}

// MARK: - 开关

/// 按设置启动 / 停止命令行控制服务，并把 socket 路径告诉终端（注入到之后新开的窗格里）。
@MainActor
final class TerminalControlService {
    private let shell: ShellWindowController
    private let defaults: UserDefaults
    private let path: String
    private var server: ControlServer?
    private var observer: NSObjectProtocol?

    init(shell: ShellWindowController, defaults: UserDefaults = .standard, path: String = ControlProtocol.socketPath()) {
        self.shell = shell
        self.defaults = defaults
        self.path = path
        defaults.register(defaults: [Prefs.terminalControl: true])
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    var isRunning: Bool { server?.isRunning == true }

    func update() {
        let enabled = defaults.bool(forKey: Prefs.terminalControl)
        if enabled, server == nil {
            let server = ControlServer(path: path) { [weak shell] request in
                shell?.handleControl(request) ?? .failure("终端不可用", code: "failed")
            }
            do {
                try server.start()
                self.server = server
                shell.controlSocketPath = path
            } catch {
                NSLog("Timeline: 命令行控制服务未启动（\(path)）：\(error)")
            }
        } else if !enabled, let server {
            server.stop()
            self.server = nil
            shell.controlSocketPath = nil
        }
    }

    func stop() {
        server?.stop()
        server = nil
        shell.controlSocketPath = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
