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
guard case .run(let request, let json) = invocation else { exit(0) }

let path = ControlProtocol.clientSocketPath(environment: environment)

func send() throws -> ControlResponse { try ControlSocket.send(request, path: path) }

var response: ControlResponse
do {
    response = try send()
} catch let error as ControlSocketError where error.isNotListening {
    // Timeline 没开：在后台拉起来再等它开始监听。开着却连不上，说明在设置里关掉了命令行控制。
    guard NSRunningApplication.runningApplications(withBundleIdentifier: ControlProtocol.bundleIdentifier).isEmpty else {
        fail("连不上 Timeline（\(path)）。请在 Timeline 设置里打开「允许命令行（tl）控制终端」。", code: 3)
    }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", "-b", ControlProtocol.bundleIdentifier]
    do { try open.run(); open.waitUntilExit() } catch { fail("无法启动 Timeline：\(error)", code: 3) }
    var started: ControlResponse?
    for _ in 0..<50 {
        usleep(200_000)
        if let value = try? send() { started = value; break }
    }
    guard let started else { fail("已启动 Timeline，但没有等到控制服务（\(path)）。", code: 3) }
    response = started
} catch {
    fail("与 Timeline 通信失败：\(error)", code: 3)
}

if json {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(response) { print(String(decoding: data, as: UTF8.self)) }
    exit(response.ok ? 0 : 1)
}
guard response.ok else { fail(response.error ?? "未知错误", code: 1) }
FileHandle.standardOutput.write(Data(ControlCommandLine.format(response, for: request).utf8))
