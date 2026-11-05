import AppKit
import XCTest
import TimelineControl
@testable import Timeline

/// 命令行 tl 的参数解析与输出（纯逻辑，不开窗口）。
final class TerminalControlCommandLineTests: XCTestCase {
    private func parse(_ arguments: [String], environment: [String: String] = [:], stdin: String? = nil) throws -> ControlRequest {
        guard case .run(let request, _) = try ControlCommandLine.parse(arguments, environment: environment, currentDirectory: "/work",
                                                                        readStandardInput: { stdin }) else {
            XCTFail("应当是要执行的命令")
            return ControlRequest(command: "")
        }
        return request
    }

    func testPaneDefaultsToTheShellItRunsIn() throws {
        let environment = [ControlProtocol.paneEnvironmentKey: "p4"]
        XCTAssertEqual(try parse(["split", "--down"], environment: environment), ControlRequest(command: "split", pane: "p4", direction: "down"))
        XCTAssertEqual(try parse(["read", "p2", "--lines", "5"], environment: environment).pane, "p2", "位置参数指定的窗格优先")
        XCTAssertEqual(try parse(["send", "-t", "p9", "ls", "-la"], environment: environment), ControlRequest(command: "send", pane: "p9", text: "ls -la"))
        XCTAssertNil(try parse(["ls"], environment: environment).pane, "ls 不针对某个窗格")
        XCTAssertNil(try parse(["focus"]).pane, "不在 Timeline 终端里时交给应用选当前窗格")
    }

    func testClosingOwnPaneDoesNotCountTlAsARunningProgram() throws {
        let environment = [ControlProtocol.paneEnvironmentKey: "p4"]
        XCTAssertEqual(try parse(["close"], environment: environment).force, true)
        XCTAssertNil(try parse(["close", "p5"], environment: environment).force, "关别的窗格仍要确认")
        XCTAssertEqual(try parse(["close", "p5", "--force"], environment: environment).force, true)
    }

    func testNewAndSplitTakeTheCommandAfterDoubleDashAndResolveDirectories() throws {
        let request = try parse(["new", "--tab", "--cwd", "sub/../repo", "--", "npm", "test"], environment: ["HOME": "/Users/me"])
        XCTAssertEqual(request.kind, "tab")
        XCTAssertEqual(request.cwd, "/work/repo")
        XCTAssertEqual(request.run, "npm test")
        XCTAssertEqual(try parse(["split", "--cwd", "~/code"], environment: ["HOME": "/Users/me"]).cwd, "/Users/me/code")
        XCTAssertThrowsError(try parse(["split", "npm"]), "命令必须写在 -- 之后")
    }

    func testSendReadsStandardInputWhenNoTextIsGiven() throws {
        let request = try parse(["send", "--no-enter"], stdin: "line one\nline two")
        XCTAssertEqual(request.text, "line one\nline two")
        XCTAssertEqual(request.enter, false)
        XCTAssertThrowsError(try parse(["send"], stdin: nil))
    }

    func testUsageErrors() {
        XCTAssertThrowsError(try parse(["frobnicate"]))
        XCTAssertThrowsError(try parse(["ls", "--bogus"]))
        XCTAssertThrowsError(try parse(["read", "--lines", "0"]))
        XCTAssertThrowsError(try parse(["split", "-t"]))
        XCTAssertEqual(try ControlCommandLine.parse([], environment: [:], currentDirectory: "/"), .help)
        XCTAssertEqual(try ControlCommandLine.parse(["--help"], environment: [:], currentDirectory: "/"), .help)
    }

    func testListingIsReadableAndAbbreviatesHome() {
        let response = ControlResponse(windows: [
            WindowInfo(id: "w1", title: "zsh", visible: true, workspace: true, tabGroup: nil, panes: [
                PaneInfo(id: "p1", pid: 10, cwd: "/Users/me/repo", busy: false, focused: true, cols: 80, rows: 24),
                PaneInfo(id: "p12", pid: 11, cwd: "/Users/me", busy: true, focused: false, cols: 100, rows: 30),
            ]),
        ])
        let text = ControlCommandLine.format(response, for: ControlRequest(command: "ls"), home: "/Users/me")
        XCTAssertEqual(text, """
        w1  zsh  (显示中, 主窗口)
          * p1    空闲  80x24  pid 10  ~/repo
            p12   运行中  100x30  pid 11  ~

        """)
        XCTAssertEqual(ControlCommandLine.format(ControlResponse(panes: ["p3", "p4"]), for: ControlRequest(command: "split")), "p3\np4\n")
        XCTAssertEqual(ControlCommandLine.format(ControlResponse(text: "a\nb"), for: ControlRequest(command: "read")), "a\nb\n")
    }

    func testRequestsSurviveTheWireFormat() throws {
        let request = ControlRequest(command: "send", pane: "p1", text: "echo \"引号\"\n第二行", enter: false)
        let line = try ControlSocket.encodeLine(request)
        XCTAssertEqual(line.last, 10)
        XCTAssertEqual(line.filter { $0 == 10 }.count, 1, "换行被转义，一条消息只占一行")
        XCTAssertEqual(try JSONDecoder().decode(ControlRequest.self, from: line.dropLast()), request)
    }
}

/// 应用里的命令处理与 socket 服务：真实的 zsh 窗格，窗口由 Headless 保持不可见。
@MainActor
final class TerminalControlTests: XCTestCase {
    private func wait(_ seconds: TimeInterval, until condition: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !condition() { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    private func controller() -> ShellWindowController {
        let controller = ShellWindowController()
        controller.arguments = ["-f", "-i"]
        controller.layoutOverride = .single
        controller.confirmClose = { _ in false }
        addTeardownBlock { @MainActor in controller.terminateAll(); controller.windows.forEach { $0.close() } }
        return controller
    }

    private func socketPath() -> String {
        // sockaddr_un 只能放 104 字节：用短名字。
        let path = NSTemporaryDirectory() + "tlc-\(UUID().uuidString.prefix(8)).sock"
        addTeardownBlock { unlink(path) }
        return path
    }

    private func panes(_ controller: ShellWindowController) -> [PaneInfo] {
        (controller.handleControl(ControlRequest(command: "ls")).windows ?? []).flatMap(\.panes)
    }

    func testEachPaneKnowsItsIDAndTheSocket() async throws {
        let controller = controller()
        controller.controlSocketPath = "/tmp/timeline-test.sock"
        let window = controller.newWindow()
        let pane = try XCTUnwrap(window.panes.first as? PaneTerminalView)
        XCTAssertEqual(pane.paneID, "p1")
        XCTAssertEqual(window.windowID, "w1")
        pane.send(txt: "echo \"id=$TIMELINE_PANE_ID sock=$TIMELINE_SOCKET\"\r")
        await wait(5) { pane.transcript().contains("id=p1 sock=/tmp/timeline-test.sock") }
        XCTAssertTrue(pane.transcript().contains("id=p1 sock=/tmp/timeline-test.sock"), pane.transcript())
        let split = try XCTUnwrap(controller.handleControl(ControlRequest(command: "split", pane: "p1")).panes?.first)
        XCTAssertEqual(split, "p2", "分出来的窗格有新编号")
    }

    func testSplitSendReadAndClosePanesByID() async throws {
        let controller = controller()
        _ = controller.newWindow()
        XCTAssertEqual(panes(controller).map(\.id), ["p1"])

        let split = controller.handleControl(ControlRequest(command: "split", pane: "p1", direction: "down"))
        XCTAssertTrue(split.ok, split.error ?? "")
        let id = try XCTUnwrap(split.panes?.first)
        XCTAssertEqual(panes(controller).map(\.id), ["p1", id])

        XCTAssertTrue(controller.handleControl(ControlRequest(command: "send", pane: id, text: "echo tl-$((6*7))-ok")).ok)
        var screen = ""
        await wait(5) {
            screen = controller.handleControl(ControlRequest(command: "read", pane: id)).text ?? ""
            return screen.contains("tl-42-ok")
        }
        XCTAssertTrue(screen.contains("tl-42-ok"), screen)
        XCTAssertFalse(controller.handleControl(ControlRequest(command: "read", pane: "p1")).text?.contains("tl-42-ok") ?? true, "只读目标窗格")
        XCTAssertEqual(controller.handleControl(ControlRequest(command: "read", pane: id, lines: 1)).text?.split(separator: "\n").count, 1)

        _ = controller.handleControl(ControlRequest(command: "send", pane: id, text: "sleep 30"))
        await wait(5) { panes(controller).first { $0.id == id }?.busy == true }
        let refused = controller.handleControl(ControlRequest(command: "close", pane: id))
        XCTAssertEqual(refused.code, "busy", "前台有程序时不带 --force 不关")
        XCTAssertEqual(panes(controller).count, 2)
        XCTAssertTrue(controller.handleControl(ControlRequest(command: "close", pane: id, force: true)).ok)
        XCTAssertEqual(panes(controller).map(\.id), ["p1"], "其余窗格补位")
    }

    func testNewWindowRunsCommandInRequestedDirectoryAndErrorsAreReported() async throws {
        let controller = controller()
        // 内核报的是真实路径（/private/var/…），URL.resolvingSymlinksInPath 会把 /private 去掉。
        let directory = try XCTUnwrap(realpath(NSTemporaryDirectory(), nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) })
        let created = controller.handleControl(ControlRequest(command: "new", cwd: directory, run: "echo started-$((1+1))"))
        XCTAssertTrue(created.ok, created.error ?? "")
        let id = try XCTUnwrap(created.panes?.first)
        await wait(5) { panes(controller).first?.cwd == directory && (controller.handleControl(ControlRequest(command: "read", pane: id)).text ?? "").contains("started-2") }
        XCTAssertEqual(panes(controller).first?.cwd, directory)
        XCTAssertTrue(controller.handleControl(ControlRequest(command: "read", pane: id)).text?.contains("started-2") == true)

        XCTAssertEqual(controller.handleControl(ControlRequest(command: "read", pane: "p99")).code, "not_found")
        XCTAssertEqual(controller.handleControl(ControlRequest(command: "new", cwd: "/no/such/dir")).code, "usage")
        XCTAssertEqual(controller.handleControl(ControlRequest(command: "split", pane: id, direction: "sideways")).code, "usage")
        XCTAssertEqual(controller.handleControl(ControlRequest(command: "nope")).code, "usage")
    }

    func testSocketServesSameUserAndRefusesToStealALiveSocket() async throws {
        let path = socketPath()
        let server = ControlServer(path: path) { request in
            ControlResponse(text: "echo:\(request.command):\(request.pane ?? "-")")
        }
        try server.start()
        defer { server.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "只有当前用户能连接")

        // 服务端要回到主线程处理，客户端必须在别的线程上等。
        let response = try await Task.detached { try ControlSocket.send(ControlRequest(command: "ls", pane: "p7"), path: path) }.value
        XCTAssertEqual(response.text, "echo:ls:p7")

        let second = ControlServer(path: path) { _ in ControlResponse() }
        XCTAssertThrowsError(try second.start()) { XCTAssertEqual($0 as? ControlServerError, .inUse) }

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "停止后删除 socket 文件")
        do {
            _ = try await Task.detached { try ControlSocket.send(ControlRequest(command: "ls"), path: path) }.value
            XCTFail("服务已停止")
        } catch let error as ControlSocketError {
            XCTAssertTrue(error.isNotListening, "\(error)")
        }
    }

    func testServiceFollowsTheSettingAndInjectsTheSocketPath() async throws {
        let controller = controller()
        let defaults = InMemoryDefaults()
        let path = socketPath()
        let service = TerminalControlService(shell: controller, defaults: defaults, path: path)
        defer { service.stop() }
        XCTAssertTrue(service.isRunning, "默认开启")
        XCTAssertEqual(controller.controlSocketPath, path)
        let response = try await Task.detached { try ControlSocket.send(ControlRequest(command: "ping"), path: path) }.value
        XCTAssertEqual(response.text, "\(ControlProtocol.version)")

        defaults.set(false, forKey: Prefs.terminalControl)
        service.update()
        XCTAssertFalse(service.isRunning)
        XCTAssertNil(controller.controlSocketPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
