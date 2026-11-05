import AppKit
import Darwin
import XCTest
import SwiftTerm
import TimelineControl
@testable import Timeline

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
private func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

/// 帧、detach 键、输出过滤：纯逻辑。
final class AttachProtocolTests: XCTestCase {
    func testFramesSurviveArbitrarySplits() throws {
        let frames = [AttachFrame(.input, bytes("ls -la\r")), .resize(cols: 213, rows: 61), AttachFrame(.detach), .exit(code: -3), .exit(code: nil),
                      AttachFrame(.output, Array(repeating: 7, count: 70_000))]
        let wire = frames.flatMap(\.encoded)
        for chunk in [1, 3, 5, 4096, wire.count] {
            var decoder = AttachFrameDecoder()
            var decoded: [AttachFrame] = []
            var index = 0
            while index < wire.count {
                decoded += try decoder.append(wire[index..<min(index + chunk, wire.count)])
                index += chunk
            }
            XCTAssertEqual(decoded, frames, "每 \(chunk) 字节切一刀")
        }
        XCTAssertEqual(AttachFrame.resize(cols: 213, rows: 61).size?.cols, 213)
        XCTAssertEqual(AttachFrame.resize(cols: 213, rows: 61).size?.rows, 61)
        XCTAssertEqual(AttachFrame.exit(code: -3).exitCode, -3)
        XCTAssertNil(AttachFrame.exit(code: nil).exitCode)
        var decoder = AttachFrameDecoder()
        XCTAssertThrowsError(try decoder.append([99, 0, 0, 0, 0]))
    }

    func testDetachKeyIsCtrlBracketThenD() {
        var keys = DetachKeyFilter()
        XCTAssertEqual(keys.feed(bytes("ab")).forward, bytes("ab"))
        let split = keys.feed([0x1d])
        XCTAssertEqual(split.forward, [])
        XCTAssertFalse(split.detach, "前缀单独到达时先等下一个键")
        XCTAssertTrue(keys.feed(bytes("d")).detach)

        var literal = DetachKeyFilter()
        XCTAssertEqual(literal.feed([0x1d, 0x1d, 0x61]).forward, [0x1d, 0x61], "按两次送出一个 Ctrl-]")
        var other = DetachKeyFilter()
        XCTAssertEqual(other.feed([0x1d, 0x78]).forward, [0x1d, 0x78], "前缀后面不是 d：两个都原样送出")
        var upper = DetachKeyFilter()
        let result = upper.feed([0x61, 0x1d, 0x44, 0x62])
        XCTAssertEqual(result.forward, [0x61])
        XCTAssertTrue(result.detach, "大写 D 也算")
    }

    func testFilterTracksModesAndDropsQueries() {
        let filter = TerminalStreamFilter()
        let input = "\u{1b}[?1049h\u{1b}[?1h\u{1b}=\u{1b}[?2004h\u{1b}[?1000;1006h\u{1b}[?25l"
            + "\u{1b}[31mred\u{1b}[0m"
            + "\u{1b}[6n\u{1b}[c\u{1b}[>c\u{1b}[5n\u{1b}[14t\u{1b}[>q\u{1b}[?u\u{1b}[?2026$p"
            + "\u{1b}]11;?\u{1b}\\\u{1b}]10;?\u{07}\u{1b}P$qm\u{1b}\\\u{1b}P+q544e\u{1b}\\\u{1b}_Ga=q;AAAA\u{1b}\\"
            + "\u{1b}]0;title\u{07}\u{1b}]8;;https://x.y\u{1b}\\link\u{1b}]8;;\u{1b}\\\u{1b}[>1u"
        let output = text(filter.process(bytes(input)[...], forward: true))
        XCTAssertEqual(output, "\u{1b}[?1049h\u{1b}[?1h\u{1b}=\u{1b}[?2004h\u{1b}[?1000;1006h\u{1b}[?25l\u{1b}[31mred\u{1b}[0m"
                       + "\u{1b}]0;title\u{07}\u{1b}]8;;https://x.y\u{1b}\\link\u{1b}]8;;\u{1b}\\\u{1b}[>1u",
                       "查询（位置、设备属性、颜色、能力、kitty 图片）都去掉，其余原样保留")
        let modes = filter.modes
        XCTAssertTrue(modes.isOn(1))
        XCTAssertTrue(modes.isOn(2004))
        XCTAssertTrue(modes.isOn(1000))
        XCTAssertTrue(modes.isOn(1006))
        XCTAssertFalse(modes.isOn(25))
        XCTAssertTrue(modes.keypadApplication)
        let restore = text(modes.restoreSequence)
        XCTAssertTrue(restore.contains("\u{1b}[?2004h") && restore.contains("\u{1b}[?25l") && restore.contains("\u{1b}[?1003l") && restore.hasSuffix("\u{1b}="))
        XCTAssertFalse(restore.contains("1049"), "备用屏幕由快照处理")

        _ = filter.process(bytes("\u{1b}c")[...], forward: false)
        XCTAssertEqual(filter.modes, TerminalModes(), "RIS 复位所有模式")
    }

    func testFilterGivesTheSameResultWhenInputArrivesByteByByte() {
        let input = bytes("a\u{1b}[?2004hb\u{1b}[6nc\u{1b}]11;?\u{1b}\\d\u{1b}]2;t\u{07}e\u{1b}P$qm\u{1b}\\f\u{1b}[38;2;1;2;3mg\u{1b}\u{1b}[1mh")
        let whole = TerminalStreamFilter().process(input[...], forward: true)
        let pieces = TerminalStreamFilter()
        var split: [UInt8] = []
        for byte in input { split += pieces.process([byte][...], forward: true) }
        XCTAssertEqual(text(split), text(whole))
        XCTAssertEqual(text(whole), "a\u{1b}[?2004hbcd\u{1b}]2;t\u{07}ef\u{1b}[38;2;1;2;3mg\u{1b}\u{1b}[1mh")
    }

    func testHugeStringSequencesStreamInsteadOfBuffering() {
        let filter = TerminalStreamFilter()
        let sixel = "\u{1b}Pq" + String(repeating: "#0;2;0;0;0~", count: 20_000) + "\u{1b}\\"
        let image = "\u{1b}_G" + String(repeating: "A", count: 100_000) + "\u{1b}\\"
        let output = text(filter.process(bytes(sixel + "x" + image + "y")[...], forward: true))
        XCTAssertEqual(output, sixel + "xy", "超长的 sixel 边收边转发，kitty 图片整段丢掉")
    }

    func testFilterThroughputLeavesRoomForRendering() {
        // 和 cat 大文件时的输出相似：大部分是普通文字，夹着颜色序列。
        let line = bytes("\u{1b}[32m2026-11-05\u{1b}[0m INFO request handled in 12ms path=/api/v1/items?id=42 status=200\r\n")
        let chunk = Array((0..<500).flatMap { _ in line })   // ~45KB
        let filter = TerminalStreamFilter()
        for (forward, label) in [(false, "没有外部终端"), (true, "有外部终端")] {
            let start = DispatchTime.now().uptimeNanoseconds
            var total = 0
            for _ in 0..<100 { total += filter.process(chunk[...], forward: forward).count + chunk.count }
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            let megabytes = Double(chunk.count * 100) / 1_048_576
            print("[perf] 输出过滤（\(label)）：\(String(format: "%.0f", megabytes / seconds)) MB/s")
            XCTAssertGreaterThan(total, 0)
        }
        // 对照：SwiftTerm 解析同样的输出（Timeline 本来就要做的事）。
        final class Sink: TerminalDelegate { func send(source: Terminal, data: ArraySlice<UInt8>) {} }
        let sink = Sink()
        let terminal = Terminal(delegate: sink, options: TerminalOptions(cols: 160, rows: 50, scrollback: 10_000))
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<100 { terminal.feed(byteArray: chunk) }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        print("[perf] 对照：SwiftTerm 解析同样的输出：\(String(format: "%.0f", Double(chunk.count * 100) / 1_048_576 / seconds)) MB/s")
    }
}

final class AttachCommandLineTests: XCTestCase {
    private func parse(_ arguments: [String], pane: String? = nil) throws -> ControlRequest {
        let environment = pane.map { [ControlProtocol.paneEnvironmentKey: $0] } ?? [:]
        guard case .run(let request, _) = try ControlCommandLine.parse(arguments, environment: environment, currentDirectory: "/") else {
            XCTFail("应当是要执行的命令")
            return ControlRequest(command: "")
        }
        return request
    }

    func testAttachOptionsAndOwnPaneGuard() throws {
        XCTAssertEqual(try parse(["attach", "p3", "-r", "--history", "200"]), ControlRequest(command: "attach", pane: "p3", readOnly: true, history: 200))
        XCTAssertEqual(try parse(["split", "-r"]).direction, "right", "-r 在 split 里仍然是向右")
        XCTAssertNil(try parse(["attach"]).pane, "在 Timeline 外：交给应用选当前窗格")
        XCTAssertEqual(try parse(["attach", "-t", "p2"], pane: "p1").pane, "p2")
        XCTAssertThrowsError(try parse(["attach"], pane: "p1"), "在 Timeline 里必须指定窗格")
        XCTAssertThrowsError(try parse(["attach", "p1"], pane: "p1"), "不能 attach 自己所在的窗格")
        XCTAssertThrowsError(try parse(["attach", "--history", "-1"]))
        let help = try XCTUnwrap(ControlHelp.help(for: "attach"))
        XCTAssertTrue(help.contains("Ctrl-] then d") && help.contains("Ctrl-] 然后 d"))
        XCTAssertTrue(ControlHelp.overview.contains("  attach "))
    }
}

/// tl attach 的收发循环：用管道和 socketpair 代替真终端和 Timeline。
final class AttachClientTests: XCTestCase {
    private final class Pipes {
        var socket: [Int32] = [0, 0]
        var input: [Int32] = [0, 0]
        var output: [Int32] = [0, 0]
        var wake: [Int32] = [0, 0]
        init() {
            socketpair(AF_UNIX, SOCK_STREAM, 0, &socket)
            pipe(&input); pipe(&output); pipe(&wake)
            _ = fcntl(output[0], F_SETFL, O_NONBLOCK)
        }
        deinit { (socket + input + output + wake).forEach { close($0) } }

        func readOutput() -> String {
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = read(output[0], &buffer, buffer.count)
            return count > 0 ? text(Array(buffer[0..<count])) : ""
        }
    }

    private func readFrames(_ fd: Int32, until done: ([AttachFrame]) -> Bool) -> [AttachFrame] {
        var decoder = AttachFrameDecoder()
        var frames: [AttachFrame] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        ControlSocket.setTimeout(fd, seconds: 3)
        while !done(frames) {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            frames += (try? decoder.append(buffer[0..<count])) ?? []
        }
        return frames
    }

    private func start(_ pipes: Pipes, readOnly: Bool = false, sizes: [(Int, Int)] = [(80, 24)]) -> (Thread, () -> AttachOutcome?) {
        let lock = NSLock()
        var outcome: AttachOutcome?
        var remaining = sizes
        let client = AttachClient(socket: pipes.socket[0], input: pipes.input[0], output: pipes.output[1], wake: pipes.wake[0], readOnly: readOnly) {
            lock.lock(); defer { lock.unlock() }
            return remaining.count > 1 ? remaining.removeFirst() : remaining.first.map { (cols: $0.0, rows: $0.1) }
        }
        let thread = Thread {
            let result = client.run(leftover: AttachFrame(.output, bytes("hello ")).encoded)
            lock.lock(); outcome = result; lock.unlock()
        }
        thread.start()
        return (thread, { lock.lock(); defer { lock.unlock() }; return outcome })
    }

    private func waitFor(_ condition: () -> Bool) {
        let end = Date().addingTimeInterval(3)
        while Date() < end, !condition() { usleep(5_000) }
    }

    func testOutputInputResizeAndDetach() throws {
        let pipes = Pipes()
        let (_, outcome) = start(pipes, sizes: [(80, 24), (120, 40)])
        var shown = ""
        waitFor { shown += pipes.readOutput(); return shown.contains("hello") }
        XCTAssertEqual(shown, "hello ", "握手后已到达的字节先显示")
        try ControlSocket.writeAll(pipes.socket[1], Data(AttachFrame(.output, bytes("world")).encoded))
        waitFor { shown += pipes.readOutput(); return shown.contains("world") }
        XCTAssertEqual(shown, "hello world")

        _ = bytes("ls\r").withUnsafeBytes { write(pipes.input[1], $0.baseAddress, $0.count) }
        var frames = readFrames(pipes.socket[1]) { $0.count >= 1 }
        XCTAssertEqual(frames, [AttachFrame(.input, bytes("ls\r"))])

        var signal = AttachClient.wakeResize
        write(pipes.wake[1], &signal, 1)
        frames = readFrames(pipes.socket[1]) { $0.count >= 1 }
        XCTAssertEqual(frames.first?.size?.cols, 120)
        XCTAssertEqual(frames.first?.size?.rows, 40)

        _ = [UInt8]([0x78, 0x1d, 0x64]).withUnsafeBytes { write(pipes.input[1], $0.baseAddress, $0.count) }
        frames = readFrames(pipes.socket[1]) { $0.contains { $0.type == .detach } }
        XCTAssertEqual(frames, [AttachFrame(.input, [0x78]), AttachFrame(.detach)], "detach 键之前的输入照常送出")
        waitFor { outcome() != nil }
        XCTAssertEqual(outcome(), .detached)
    }

    func testPaneExitAndLostConnectionEndTheLoop() throws {
        let exited = Pipes()
        let (_, exitOutcome) = start(exited)
        try ControlSocket.writeAll(exited.socket[1], Data(AttachFrame.exit(code: 3).encoded))
        waitFor { exitOutcome() != nil }
        XCTAssertEqual(exitOutcome(), .exited(3))

        let lost = Pipes()
        let (_, lostOutcome) = start(lost)
        shutdown(lost.socket[1], SHUT_RDWR)
        waitFor { lostOutcome() != nil }
        XCTAssertEqual(lostOutcome(), .disconnected)

        let terminated = Pipes()
        let (_, terminatedOutcome) = start(terminated)
        var signal = AttachClient.wakeTerminate
        write(terminated.wake[1], &signal, 1)
        waitFor { terminatedOutcome() != nil }
        XCTAssertEqual(terminatedOutcome(), .detached, "SIGTERM / SIGHUP 时也正常断开")
    }

    func testReadOnlyClientNeverSendsInput() throws {
        let pipes = Pipes()
        let (_, outcome) = start(pipes, readOnly: true)
        _ = [UInt8]([0x61, 0x62, 0x1d, 0x64]).withUnsafeBytes { write(pipes.input[1], $0.baseAddress, $0.count) }
        let frames = readFrames(pipes.socket[1]) { $0.contains { $0.type == .detach } }
        XCTAssertEqual(frames, [AttachFrame(.detach)])
        waitFor { outcome() != nil }
        XCTAssertEqual(outcome(), .detached)
    }

    func testRawModeIsRestoredOnARealTerminal() throws {
        var master: Int32 = -1, slave: Int32 = -1
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
        defer { close(master); close(slave) }
        var before = termios()
        tcgetattr(slave, &before)
        XCTAssertNotEqual(before.c_lflag & tcflag_t(ICANON), 0)
        let raw = try XCTUnwrap(RawTerminalMode(fd: slave))
        var during = termios()
        tcgetattr(slave, &during)
        XCTAssertEqual(during.c_lflag & tcflag_t(ICANON | ECHO | ISIG), 0, "raw 模式：不按行缓冲、不回显、Ctrl-C 不变成信号")
        raw.restore()
        var after = termios()
        tcgetattr(slave, &after)
        // 离开 raw 模式时内核会临时加上 PENDIN（重显未读的输入），不算差异。
        XCTAssertEqual(after.c_lflag & ~tcflag_t(PENDIN), before.c_lflag & ~tcflag_t(PENDIN))
        XCTAssertNil(RawTerminalMode(fd: STDIN_FILENO == slave ? -1 : open("/dev/null", O_RDONLY)), "不是 tty 时不切换")
    }
}

/// 屏幕快照：喂给一个新终端后，屏幕上的每一格（字符和样式）和光标都应当和原来一样。
@MainActor
final class ScreenSnapshotTests: XCTestCase {
    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }
    private let sink = Sink()

    private func terminal(cols: Int, rows: Int) -> Terminal {
        Terminal(delegate: sink, options: TerminalOptions(cols: cols, rows: rows, scrollback: 500))
    }

    private func plain(_ line: String) -> String {
        line.replacingOccurrences(of: "\u{1b}\\[[0-9;:?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private func assertSameScreen(_ a: Terminal, _ b: Terminal, file: StaticString = #filePath, line: UInt = #line) {
        let topA = ScreenRenderer.screenTop(a), topB = ScreenRenderer.screenTop(b)
        for row in 0..<a.rows {
            let lineA = ScreenRenderer.line(a, topA + row), lineB = ScreenRenderer.line(b, topB + row)
            for col in 0..<a.cols {
                let cellA = lineA?[col], cellB = lineB?[col]
                let charA = cellA.map { a.getCharacter(for: $0) } ?? " ", charB = cellB.map { b.getCharacter(for: $0) } ?? " "
                let blank: Set<Character> = [" ", "\u{0}"]
                XCTAssertTrue(charA == charB || (blank.contains(charA) && blank.contains(charB)), "第 \(row) 行第 \(col) 列：\(charA) ≠ \(charB)", file: file, line: line)
                if let cellA, let cellB, !blank.contains(charA) {
                    XCTAssertEqual(cellA.attribute, cellB.attribute, "第 \(row) 行第 \(col) 列的样式", file: file, line: line)
                }
            }
        }
        XCTAssertEqual(a.buffer.x, b.buffer.x, "光标列", file: file, line: line)
        XCTAssertEqual(a.buffer.y, b.buffer.y, "光标行", file: file, line: line)
    }

    func testStyledScreenWithWideCharactersRoundTrips() {
        let source = terminal(cols: 40, rows: 8)
        source.feed(text: (1...20).map { "scroll line \($0)" }.joined(separator: "\r\n") + "\r\n")
        source.feed(text: "\u{1b}[1;31mbold red\u{1b}[0m \u{1b}[3;4;38;2;10;200;30mitalic\u{1b}[0m \u{1b}[7mrev\u{1b}[0m\r\n")
        source.feed(text: "中文宽字符 和 emoji ✅ \u{1b}[48;5;236m bg \u{1b}[0m\r\n")
        source.feed(text: "\u{1b}[4:3m curly \u{1b}[0m \u{1b}[9;2mgone\u{1b}[0m\r\nprompt $ ")
        let modes = TerminalModes()
        let copy = terminal(cols: 40, rows: 8)
        copy.feed(byteArray: ScreenRenderer.snapshot(source, modes: modes, history: 0))
        assertSameScreen(source, copy)
    }

    func testAlternateScreenSnapshotKeepsThePrimaryScreenUnderneath() {
        let source = terminal(cols: 30, rows: 6)
        source.feed(text: "$ vim notes.txt\r\n")
        source.feed(text: "\u{1b}[?1049h\u{1b}[H\u{1b}[2J\u{1b}[44m~ editor ~\u{1b}[0m\u{1b}[3;5Hx")
        let copy = terminal(cols: 30, rows: 6)
        copy.feed(byteArray: ScreenRenderer.snapshot(source, modes: TerminalModes(), history: 0))
        XCTAssertTrue(copy.isCurrentBufferAlternate)
        assertSameScreen(source, copy)
        copy.feed(text: "\u{1b}[?1049l")
        XCTAssertTrue(String(decoding: copy.getBufferAsData(), as: UTF8.self).contains("$ vim notes.txt"), "退出备用屏幕后下面是原来的 shell 画面")
    }

    func testHistoryLinesGoIntoTheExternalScrollback() {
        let source = terminal(cols: 30, rows: 4)
        source.feed(text: (1...12).map { "line \($0)" }.joined(separator: "\r\n"))
        let copy = terminal(cols: 30, rows: 4)
        copy.feed(byteArray: ScreenRenderer.snapshot(source, modes: TerminalModes(), history: 3))
        assertSameScreen(source, copy)
        let all = String(decoding: copy.getBufferAsData(), as: UTF8.self)
        XCTAssertTrue(all.contains("line 6") && all.contains("line 8"), "屏幕上方的 3 行进了外部终端的回滚区")
        XCTAssertFalse(all.contains("line 5\n"), "只要 3 行")
    }

    func testScrollRegionAndHiddenCursorAreRestored() {
        let source = terminal(cols: 20, rows: 10)
        source.feed(text: "\u{1b}[3;8r\u{1b}[5;2Hmid")
        var modes = TerminalModes()
        let filter = TerminalStreamFilter()
        _ = filter.process(bytes("\u{1b}[?25l")[...], forward: false)
        modes = filter.modes
        let snapshot = text(ScreenRenderer.snapshot(source, modes: modes, history: 0))
        XCTAssertTrue(snapshot.contains("\u{1b}[3;8r"))
        XCTAssertTrue(snapshot.hasSuffix("\u{1b}[?25l"))
        let copy = terminal(cols: 20, rows: 10)
        copy.feed(text: snapshot)
        XCTAssertEqual(copy.buffer.scrollTop, 2)
        XCTAssertEqual(copy.buffer.scrollBottom, 7)
        assertSameScreen(source, copy)
    }

    func testFramesForOtherSizesAreCroppedOrBordered() {
        let source = terminal(cols: 20, rows: 4)
        source.feed(text: "0123456789abcdefghij\r\nsecond")
        let small = ScreenRenderer.frame(source, cols: 10, rows: 3, paneID: "p3").map(plain)
        XCTAssertEqual(small.count, 3)
        XCTAssertEqual(small[0], "0123456789", "宽度不够：裁掉右边")
        let large = ScreenRenderer.frame(source, cols: 50, rows: 30, paneID: "p3")
        XCTAssertEqual(large.count, 30)
        XCTAssertTrue(large[0].contains("│"), "宽度富余：画出右边界")
        XCTAssertTrue(large[4].contains("─") && large[4].contains("┘"), "高度富余：画出下边界")
        let croppedWide = ScreenRenderer.frame(source, cols: 40, rows: 2, paneID: "p3")
        XCTAssertTrue(croppedWide[1].contains("p3 20x4 cropped"), "被裁剪时右下角标出")
    }
}

/// 真实的 zsh 窗格 + 真实的 socket：attach 的完整流程。窗口由 Headless 保持不可见。
@MainActor
final class TerminalAttachTests: XCTestCase {
    /// 测试里的外部终端：后台线程收帧，主线程随时查看。
    private final class Remote: @unchecked Sendable {
        let fd: Int32
        private let lock = NSLock()
        private var frames: [AttachFrame] = []
        private var arrivals: [UInt64] = []
        private var closed = false
        var screen: Terminal?

        init(fd: Int32, rest: [UInt8]) {
            self.fd = fd
            let thread = Thread { [self] in
                var decoder = AttachFrameDecoder()
                var pending = rest
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    if let decoded = try? decoder.append(pending), !decoded.isEmpty {
                        let now = DispatchTime.now().uptimeNanoseconds
                        lock.lock(); frames += decoded; arrivals += decoded.map { _ in now }; lock.unlock()
                    }
                    let count = read(fd, &buffer, buffer.count)
                    if count <= 0 { break }
                    pending = Array(buffer[0..<count])
                }
                lock.lock(); closed = true; lock.unlock()
            }
            thread.start()
        }

        var received: [AttachFrame] { lock.lock(); defer { lock.unlock() }; return frames }
        /// 第 index 帧之后第一帧输出到达的时刻。
        func firstOutput(after index: Int) -> UInt64? {
            lock.lock(); defer { lock.unlock() }
            return frames.indices.first { $0 >= index && frames[$0].type == .output }.map { arrivals[$0] }
        }
        var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
        var output: String { text(received.filter { $0.type == .output }.flatMap(\.payload)) }

        func send(_ frame: AttachFrame) { try? ControlSocket.writeAll(fd, Data(frame.encoded)) }
        func type(_ string: String) { send(AttachFrame(.input, bytes(string))) }
        deinit { close(fd) }
    }

    private func wait(_ seconds: TimeInterval = 5, until condition: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    private func setUp(layout: TerminalLayout = .single) -> (ShellWindowController, String) {
        let controller = ShellWindowController()
        controller.arguments = ["-f", "-i"]
        controller.layoutOverride = layout
        controller.confirmClose = { _ in false }
        let path = NSTemporaryDirectory() + "tla-\(UUID().uuidString.prefix(8)).sock"
        let service = TerminalControlService(shell: controller, defaults: InMemoryDefaults(), path: path)
        addTeardownBlock { @MainActor in
            service.stop()
            controller.terminateAll()
            controller.windows.forEach { $0.close() }
            unlink(path)
        }
        return (controller, path)
    }

    private func attach(_ path: String, pane: String, cols: Int, rows: Int, readOnly: Bool = false, history: Int = 0) async throws -> (ControlResponse, Remote?) {
        let request = ControlRequest(command: "attach", pane: pane, cols: cols, rows: rows, readOnly: readOnly, history: history)
        let (fd, response, rest) = try await Task.detached { try ControlSocket.open(request, path: path) }.value
        guard response.ok else { close(fd); return (response, nil) }
        return (response, Remote(fd: fd, rest: rest))
    }

    private func pane(_ controller: ShellWindowController, _ id: String = "p1") throws -> PaneTerminalView {
        try XCTUnwrap(controller.pane(withID: id))
    }

    func testAttachSharesThePaneAndFollowsTheLatestTypist() async throws {
        let (controller, path) = setUp()
        let window = controller.newWindow()
        let pane = try pane(controller)
        window.contentView?.layoutSubtreeIfNeeded()
        let own = (cols: pane.getTerminal().cols, rows: pane.getTerminal().rows)
        XCTAssertNotEqual(own.cols, 100)
        await wait { pane.transcript().contains("%") || pane.transcript().contains("$") || pane.transcript().contains("#") }

        let (response, maybeRemote) = try await attach(path, pane: "p1", cols: 100, rows: 30)
        let remote = try XCTUnwrap(maybeRemote, response.error ?? "")
        XCTAssertEqual(response.panes, ["p1"])
        XCTAssertEqual(pane.getTerminal().cols, 100, "attach 的一方成为尺寸主人")
        XCTAssertEqual(pane.getTerminal().rows, 30)
        let frame = try XCTUnwrap(pane.superview as? PaneFrameView)
        XCTAssertNotNil(frame.fixedTerminalSize, "Timeline 窗口按外部尺寸排版并裁剪")
        XCTAssertEqual(frame.badgeText?.trimmingCharacters(in: .whitespaces), "外部终端 ×1 · 尺寸 100×30")
        XCTAssertEqual(controller.handleControl(ControlRequest(command: "ls")).windows?.first?.panes.first?.attached, 1)
        await wait { remote.output.contains("\u{1b}[H\u{1b}[2J") }
        XCTAssertTrue(remote.output.hasPrefix("\u{1b}[?1h") || remote.output.hasPrefix("\u{1b}[?1l"), "先同步终端模式，再发快照")

        remote.type("echo attach-$((6*7))\r")
        await wait { remote.output.contains("attach-42") && pane.transcript().contains("attach-42") }
        XCTAssertTrue(remote.output.contains("attach-42"), "外部终端收到输出")
        XCTAssertTrue(pane.transcript().contains("attach-42"), "Timeline 窗口同步显示")

        // 程序查询光标位置：SwiftTerm 的自动应答不能被当成 Timeline 窗口里的输入。
        remote.type("printf '\\e[6n'; read -s -t 2 -d R reply; echo got-reply\r")
        await wait { pane.transcript().contains("got-reply") }
        XCTAssertTrue(pane.attach.owner != nil, "查询应答不改变尺寸主人")
        XCTAssertFalse(remote.output.contains("\u{1b}[6n"), "查询没有转发给外部终端（否则会收到两份应答）")

        // Timeline 窗口里打字：尺寸回到窗格本身，外部终端改为按自己的大小看裁剪 / 加边框的画面。
        pane.send(data: [0x0c][...])
        XCTAssertNil(pane.attach.owner)
        XCTAssertEqual(pane.getTerminal().cols, own.cols)
        XCTAssertEqual(pane.getTerminal().rows, own.rows)
        XCTAssertNil(frame.fixedTerminalSize)
        XCTAssertEqual(frame.badgeText?.trimmingCharacters(in: .whitespaces), "外部终端 ×1")
        let mark = remote.output.count
        await wait { remote.output.count > mark && remote.output.suffix(from: remote.output.index(remote.output.startIndex, offsetBy: mark)).contains("\u{1b}[?1049h") }
        await wait(1) { false }
        XCTAssertTrue(remote.output.contains("│") || remote.output.contains("cropped"), "尺寸不同的外部终端看到边框或裁剪标记")

        // 外部终端调整到和窗格一样大：直接接收原始输出。
        remote.send(.resize(cols: own.cols, rows: own.rows))
        await wait { pane.attach.sessions.first?.passthrough == true }
        XCTAssertTrue(pane.attach.sessions.first?.passthrough == true)
        XCTAssertNil(pane.attach.owner, "调整尺寸不是输入，不抢尺寸")

        // 外部终端再打字：尺寸又归它。
        remote.send(.resize(cols: 90, rows: 25))
        remote.type(" ")
        await wait { pane.getTerminal().cols == 90 }
        XCTAssertEqual(pane.getTerminal().rows, 25)

        remote.send(AttachFrame(.detach))
        await wait { pane.attach.count == 0 }
        XCTAssertEqual(pane.attach.count, 0)
        XCTAssertEqual(pane.getTerminal().cols, own.cols, "断开后尺寸交回 Timeline 窗口")
        XCTAssertNil(frame.badgeText)
        await wait { remote.isClosed }
        XCTAssertTrue(remote.isClosed)
    }

    func testReadOnlyViewerAndMultipleClients() async throws {
        let (controller, path) = setUp()
        let window = controller.newWindow()
        window.contentView?.layoutSubtreeIfNeeded()
        let pane = try pane(controller)
        let own = pane.getTerminal().cols
        let (_, viewerOrNil) = try await attach(path, pane: "p1", cols: 70, rows: 20, readOnly: true)
        let viewer = try XCTUnwrap(viewerOrNil)
        XCTAssertNil(pane.attach.owner, "只读的一方不接管尺寸")
        XCTAssertEqual(pane.getTerminal().cols, own)
        viewer.type("echo should-not-run\r")

        let (_, writerOrNil) = try await attach(path, pane: "p1", cols: 120, rows: 35)
        let writer = try XCTUnwrap(writerOrNil)
        XCTAssertEqual(pane.getTerminal().cols, 120)
        XCTAssertEqual(pane.attach.count, 2)
        writer.type("echo from-writer\r")
        await wait { pane.transcript().contains("from-writer") }
        await wait { viewer.output.contains("from-writer") }
        XCTAssertTrue(viewer.output.contains("from-writer"), "只读的一方按自己的尺寸看到画面")
        XCTAssertFalse(pane.transcript().contains("should-not-run"), "只读的输入被忽略")

        // 写的一方断开：尺寸交回 Timeline（只读的一方从未输入）。
        writer.send(AttachFrame(.detach))
        await wait { pane.attach.count == 1 }
        XCTAssertNil(pane.attach.owner)
        XCTAssertEqual(pane.getTerminal().cols, own)
    }

    func testPaneExitIsReportedToEveryClient() async throws {
        let (controller, path) = setUp()
        _ = controller.newWindow()
        let (_, remoteOrNil) = try await attach(path, pane: "p1", cols: 80, rows: 24)
        let remote = try XCTUnwrap(remoteOrNil)
        remote.type("exit 7\r")
        await wait { remote.received.contains { $0.type == .exit } }
        XCTAssertEqual(remote.received.last { $0.type == .exit }?.exitCode, 7)
        await wait { remote.isClosed }
        XCTAssertTrue(remote.isClosed)

        _ = controller.newWindow()
        let (_, closedOrNil) = try await attach(path, pane: "p2", cols: 80, rows: 24)
        let closed = try XCTUnwrap(closedOrNil)
        XCTAssertTrue(controller.handleControl(ControlRequest(command: "close", pane: "p2", force: true)).ok)
        await wait { closed.received.contains { $0.type == .exit } }
        XCTAssertTrue(closed.received.contains { $0.type == .exit }, "在 Timeline 里关闭窗格也通知外部终端")

        let (missing, _) = try await attach(path, pane: "p99", cols: 80, rows: 24)
        XCTAssertEqual(missing.code, "not_found")
        let (noSize, _) = try await attach(path, pane: "p1", cols: 0, rows: 0)
        XCTAssertFalse(noSize.ok)
    }

    func testSlowClientIsResyncedInsteadOfGrowingWithoutBound() async throws {
        let (controller, _) = setUp()
        _ = controller.newWindow()
        let pane = try pane(controller)
        let hub = pane.attach
        // 还没开始收发的连接：发送队列只进不出，相当于一个完全卡住的客户端。
        let session = hub.attach(cols: pane.getTerminal().cols, rows: pane.getTerminal().rows, readOnly: true, history: 0)
        XCTAssertTrue(session.passthrough)
        let chunk = Array(repeating: UInt8(ascii: "x"), count: 1 << 20)
        for _ in 0..<5 { hub.received(chunk[...]) }
        XCTAssertTrue(session.resyncing, "积压超过上限：丢掉并等待重发快照")
        await wait { !session.resyncing }
        XCTAssertFalse(session.resyncing)
        hub.remove(session)
    }

    func testAttachLatencyThroughRealZsh() async throws {
        let (controller, path) = setUp()
        _ = controller.newWindow()
        let pane = try pane(controller)
        await wait { !pane.transcript().isEmpty }
        let (_, remoteOrNil) = try await attach(path, pane: "p1", cols: 80, rows: 24)
        let remote = try XCTUnwrap(remoteOrNil)
        try await Task.sleep(nanoseconds: 300_000_000)
        var arrivedInTimeline: UInt64 = 0
        pane.attach.onReceived = { if arrivedInTimeline == 0 { arrivedInTimeline = DispatchTime.now().uptimeNanoseconds } }
        var total: [Double] = [], echo: [Double] = [], relay: [Double] = []
        for index in 0..<40 {
            let key = String(UnicodeScalar(UInt8(97 + index % 26)))
            let mark = remote.received.count
            arrivedInTimeline = 0
            let start = DispatchTime.now().uptimeNanoseconds
            remote.type(key)
            await wait(2) { remote.firstOutput(after: mark) != nil }
            guard let end = remote.firstOutput(after: mark), arrivedInTimeline > 0 else { continue }
            total.append(Double(end - start) / 1e6)
            echo.append(Double(arrivedInTimeline - start) / 1e6)
            relay.append(Double(end - arrivedInTimeline) / 1e6)
        }
        pane.attach.onReceived = nil
        func describe(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return String(format: "中位 %.2f ms，p95 %.2f ms", sorted[sorted.count / 2], sorted[max(0, Int(Double(sorted.count) * 0.95) - 1)])
        }
        XCTAssertGreaterThan(total.count, 30)
        print("[perf] attach 按键 → 外部终端看到回显：\(describe(total))")
        print("[perf]   其中 输入经 socket 进 PTY、zsh 回显、Timeline 收到：\(describe(echo))")
        print("[perf]   其中 Timeline 收到 → 外部终端收到：\(describe(relay))")
        XCTAssertLessThan(total.sorted()[total.count / 2], 16, "本机往返应当小于一帧")
    }
}
