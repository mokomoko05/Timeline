import Foundation
import TimelineCore

private var savedTermios = termios()
private var savedValid = false

/// 进入原始模式 + 备用屏幕；无论怎么退出（正常、信号）都会还原终端，否则用户的终端会停在乱码状态。
public final class RawTerminal {
    private var buffer: [UInt8] = []
    private var entered = false

    public init() {}

    public static func size() -> (columns: Int, rows: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 { return (Int(ws.ws_col), Int(ws.ws_row)) }
        return (80, 24)
    }

    public func enter() {
        guard !entered, isatty(STDIN_FILENO) != 0 else { return }
        if tcgetattr(STDIN_FILENO, &savedTermios) == 0 { savedValid = true }
        var raw = savedTermios
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL | INLCR)
        withUnsafeMutablePointer(to: &raw.c_cc) { pointer in
            pointer.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 0
                cc[Int(VTIME)] = 0
            }
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[2J")
        entered = true
        for signalNumber in [SIGTERM, SIGHUP, SIGQUIT] {
            signal(signalNumber) { code in
                if savedValid { var original = savedTermios; tcsetattr(STDIN_FILENO, TCSAFLUSH, &original) }
                let reset = "\u{1B}[?25h\u{1B}[?1049l"
                _ = reset.withCString { Foundation.write(STDOUT_FILENO, $0, strlen($0)) }
                _exit(128 + code)
            }
        }
    }

    public func leave() {
        guard entered else { return }
        write("\u{1B}[?25h\u{1B}[?1049l")
        if savedValid { var original = savedTermios; tcsetattr(STDIN_FILENO, TCSAFLUSH, &original) }
        entered = false
    }

    deinit { leave() }

    public func write(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let count = bytes.count
            let n = bytes.withUnsafeBytes { Foundation.write(STDOUT_FILENO, $0.baseAddress! + offset, count - offset) }
            if n <= 0 { break }
            offset += n
        }
    }

    /// 等最多 `timeout` 秒，读到按键就返回；超时返回空数组（调用方借此检查窗口大小变化）。
    public func readKeys(timeout: TimeInterval) -> [Key] {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return [] }
        var chunk = [UInt8](repeating: 0, count: 256)
        let n = read(STDIN_FILENO, &chunk, chunk.count)
        if n == 0 { return [.ctrl("c")] }   // 输入被关闭
        guard n > 0 else { return [] }
        buffer += chunk[0..<n]
        let decoded = KeyDecoder.decode(buffer)
        buffer = decoded.rest
        return decoded.keys
    }
}

/// 交互式选择器的真实终端驱动。
public enum InteractivePicker {
    public struct Outcome { public var selected: LogRow?; public var message: String? }

    @MainActor
    public static func run(state initial: PickerState, ctx baseContext: RenderContext, store: JournalStore) -> Outcome {
        var state = initial
        let terminal = RawTerminal()
        terminal.enter()
        defer { terminal.leave() }
        var (columns, rows) = RawTerminal.size()
        var last: [String] = []

        func context() -> RenderContext {
            var ctx = baseContext
            ctx.width = max(20, columns)
            // 全屏界面里不内联画图（图片高度未知会破坏布局），按 i 单独查看。
            ctx.imageProtocol = .none
            return ctx
        }
        func detailLines(_ row: LogRow) -> [String] { LogRenderer.detail(row, ctx: context()) }
        func draw(force: Bool = false) {
            let detail = state.mode == .detail ? state.current.map(detailLines) : nil
            let frame = state.render(width: columns, height: rows, style: baseContext.style, detailLines: detail)
            guard force || frame != last else { return }
            terminal.write("\u{1B}[H" + frame.map { $0 + "\u{1B}[K" }.joined(separator: "\r\n"))
            last = frame
        }

        draw(force: true)
        while true {
            let keys = terminal.readKeys(timeout: 0.25)
            let size = RawTerminal.size()
            if size.columns != columns || size.rows != rows {
                (columns, rows) = size
                terminal.write("\u{1B}[2J")
                draw(force: true)
            }
            for key in keys {
                switch state.handle(key, height: rows, detailProvider: detailLines) {
                case .none: break
                case .quit: return Outcome(selected: nil, message: nil)
                case .select(let row): return Outcome(selected: row, message: nil)
                case .copy(let text): copyToPasteboard(text)
                case .showImages(let row):
                    terminal.write("\u{1B}[2J\u{1B}[H")
                    var ctx = baseContext
                    ctx.width = columns
                    let lines = LogRenderer.imageLines(row, ctx: ctx, indent: 0)
                    terminal.write(lines.joined(separator: "\r\n") + "\r\n\r\n" + baseContext.style.dim("按任意键返回"))
                    while terminal.readKeys(timeout: 30).isEmpty { }
                    terminal.write("\u{1B}[2J")
                    last = []
                }
            }
            draw(force: !keys.isEmpty && last.isEmpty)
        }
    }

    private static func copyToPasteboard(_ text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        process.standardInput = pipe
        guard (try? process.run()) != nil else { return }
        pipe.fileHandleForWriting.write(Data(text.utf8))
        try? pipe.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}
