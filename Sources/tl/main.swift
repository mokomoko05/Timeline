import AppKit
import Foundation
import TimelineControl

/// `tl`：通过 Timeline 的控制 socket 管理内置终端。退出码：0 成功，1 Timeline 报错，2 用法错误，3 连不上 Timeline。
func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data(("tl: " + message + "\n").utf8))
    exit(code)
}

let environment = ProcessInfo.processInfo.environment
let invocation: ControlInvocation
do {
    invocation = try ControlCommandLine.parse(
        Array(CommandLine.arguments.dropFirst()), environment: environment,
        currentDirectory: FileManager.default.currentDirectoryPath,
        readStandardInput: {
            guard isatty(STDIN_FILENO) == 0 else { return nil }
            return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        })
} catch {
    fail("\(error)\n" + ControlHelp.hint, code: 2)
}

if case .help(let topic) = invocation {
    print(topic.flatMap(ControlHelp.help(for:)) ?? ControlHelp.overview, terminator: "")
    exit(0)
}
guard case .run(var request, let json) = invocation else { exit(0) }

let path = ControlProtocol.clientSocketPath(environment: environment)

/// 连上 Timeline；Timeline 没开时在后台拉起来再等它开始监听。开着却连不上，说明在设置里关掉了命令行控制。
func connecting<T>(_ attempt: () throws -> T) -> T {
    do {
        return try attempt()
    } catch let error as ControlSocketError where error.isNotListening {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: ControlProtocol.bundleIdentifier).isEmpty else {
            fail("连不上 Timeline（\(path)）。请在 Timeline 设置里打开「允许命令行（tl）控制终端」。", code: 3)
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-b", ControlProtocol.bundleIdentifier]
        do { try open.run(); open.waitUntilExit() } catch { fail("无法启动 Timeline：\(error)", code: 3) }
        for _ in 0..<50 {
            usleep(200_000)
            if let value = try? attempt() { return value }
        }
        fail("已启动 Timeline，但没有等到控制服务（\(path)）。", code: 3)
    } catch {
        fail("与 Timeline 通信失败：\(error)", code: 3)
    }
}

// MARK: - attach

/// SIGWINCH / SIGTERM 等信号写进这个管道，收发循环借此醒来（信号处理函数里只能做这种事）。
nonisolated(unsafe) var wakeWriteFD: Int32 = -1

func runAttach() -> Never {
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1, let size = TerminalSize.of(STDOUT_FILENO) else {
        fail("attach 需要在交互式终端里运行  attach must run in an interactive terminal", code: 2)
    }
    request.cols = size.cols
    request.rows = size.rows
    let (socket, response, rest) = connecting { try ControlSocket.open(request, path: path) }
    guard response.ok else { fail(response.error ?? "未知错误", code: 1) }
    let pane = response.panes?.first ?? request.pane ?? "?"

    var pipeFDs: [Int32] = [0, 0]
    guard pipe(&pipeFDs) == 0 else { fail("无法创建管道", code: 3) }
    wakeWriteFD = pipeFDs[1]
    let onResize: @convention(c) (Int32) -> Void = { _ in var byte = AttachClient.wakeResize; _ = write(wakeWriteFD, &byte, 1) }
    let onTerminate: @convention(c) (Int32) -> Void = { _ in var byte = AttachClient.wakeTerminate; _ = write(wakeWriteFD, &byte, 1) }
    signal(SIGWINCH, onResize)
    for number in [SIGTERM, SIGHUP, SIGINT, SIGQUIT] { signal(number, onTerminate) }

    guard let raw = RawTerminalMode(fd: STDIN_FILENO) else { fail("无法把终端切到 raw 模式", code: 2) }
    let client = AttachClient(socket: socket, input: STDIN_FILENO, output: STDOUT_FILENO, wake: pipeFDs[0],
                              readOnly: request.readOnly == true, currentSize: { TerminalSize.of(STDOUT_FILENO) })
    let outcome = client.run(leftover: rest)
    // 先把外部终端的模式复位（离开备用屏幕、关掉鼠标上报等），再恢复行规程。
    TerminalModes.resetSequence.withUnsafeBytes { _ = write(STDOUT_FILENO, $0.baseAddress, $0.count) }
    raw.restore()
    close(socket)
    switch outcome {
    case .detached:
        print("\n[已断开 \(pane)  detached from \(pane)]")
        exit(0)
    case .exited(let code):
        print("\n[\(pane) 已结束  \(pane) exited\(code.map { ": \($0)" } ?? "")]")
        exit(0)
    case .disconnected:
        print("\n[与 Timeline 的连接已断开  connection to Timeline lost]")
        exit(3)
    }
}

if request.command == "attach" { runAttach() }

// MARK: - 其他命令

let response = connecting { try ControlSocket.send(request, path: path) }

if json {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(response) { print(String(decoding: data, as: UTF8.self)) }
    exit(response.ok ? 0 : 1)
}
guard response.ok else { fail(response.error ?? "未知错误", code: 1) }
FileHandle.standardOutput.write(Data(ControlCommandLine.format(response, for: request).utf8))
