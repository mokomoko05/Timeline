import Darwin
import Foundation

public enum AttachOutcome: Equatable, Sendable {
    /// 按了 detach 键（或被要求结束）。
    case detached
    /// 窗格里的 shell 结束了。
    case exited(Int32?)
    /// 和 Timeline 的连接断了（比如 Timeline 退出）。
    case disconnected
}

/// `tl attach` 的收发循环。只依赖文件描述符：正式运行时是 tty，测试里可以换成管道或 openpty。
public struct AttachClient {
    /// 唤醒管道里的信号：终端尺寸变了 / 要求结束。
    public static let wakeResize = UInt8(ascii: "w")
    public static let wakeTerminate = UInt8(ascii: "t")

    public let socket: Int32
    public let input: Int32
    public let output: Int32
    /// SIGWINCH、SIGTERM 之类的信号写到这个管道里，循环借此醒来。
    public let wake: Int32?
    public let readOnly: Bool
    public let currentSize: () -> (cols: Int, rows: Int)?

    public init(socket: Int32, input: Int32, output: Int32, wake: Int32?, readOnly: Bool, currentSize: @escaping () -> (cols: Int, rows: Int)?) {
        self.socket = socket
        self.input = input
        self.output = output
        self.wake = wake
        self.readOnly = readOnly
        self.currentSize = currentSize
    }

    private func send(_ frame: AttachFrame) -> Bool {
        (try? ControlSocket.writeAll(socket, Data(frame.encoded))) != nil
    }

    private func writeOutput(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(output, base + offset, raw.count - offset)
                if written < 0 { if errno == EINTR { continue }; return }
                offset += written
            }
        }
    }

    /// 一直运行到 detach、窗格结束或连接断开。`leftover` 是握手应答之后已经读到的字节。
    public func run(leftover: [UInt8] = []) -> AttachOutcome {
        var decoder = AttachFrameDecoder()
        var keys = DetachKeyFilter()
        var lastSize = currentSize()
        func handle(_ bytes: [UInt8]) -> AttachOutcome? {
            guard let frames = try? decoder.append(bytes) else { return .disconnected }
            for frame in frames {
                switch frame.type {
                case .output: writeOutput(frame.payload)
                case .exit: return .exited(frame.exitCode)
                default: break
                }
            }
            return nil
        }
        if !leftover.isEmpty, let outcome = handle(leftover) { return outcome }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var inputOpen = true
        while true {
            var fds = [pollfd(fd: socket, events: Int16(POLLIN), revents: 0)]
            if inputOpen { fds.append(pollfd(fd: input, events: Int16(POLLIN), revents: 0)) }
            if let wake { fds.append(pollfd(fd: wake, events: Int16(POLLIN), revents: 0)) }
            let ready = poll(&fds, nfds_t(fds.count), -1)
            if ready < 0 {
                if errno == EINTR { continue }
                return .disconnected
            }
            for entry in fds where entry.revents != 0 {
                if entry.fd == socket {
                    let count = read(socket, &buffer, buffer.count)
                    if count < 0, errno == EINTR { continue }
                    if count <= 0 { return .disconnected }
                    if let outcome = handle(Array(buffer[0..<count])) { return outcome }
                } else if entry.fd == input {
                    let count = read(input, &buffer, buffer.count)
                    if count < 0, errno == EINTR { continue }
                    if count <= 0 {
                        // 输入关了（比如被重定向的文件读完）：继续看输出，直到 detach 或结束。
                        inputOpen = false
                        continue
                    }
                    let (forward, detach) = keys.feed(buffer[0..<count])
                    if !forward.isEmpty, !readOnly, !send(AttachFrame(.input, forward)) { return .disconnected }
                    if detach {
                        _ = send(AttachFrame(.detach))
                        return .detached
                    }
                } else if let wake, entry.fd == wake {
                    var signals = [UInt8](repeating: 0, count: 64)
                    let count = read(wake, &signals, signals.count)
                    guard count > 0 else { continue }
                    if signals[0..<count].contains(Self.wakeTerminate) {
                        _ = send(AttachFrame(.detach))
                        return .detached
                    }
                    if let size = currentSize(), size.cols != lastSize?.cols || size.rows != lastSize?.rows {
                        lastSize = size
                        if !send(AttachFrame.resize(cols: size.cols, rows: size.rows)) { return .disconnected }
                    }
                }
            }
        }
    }
}

/// 把 tty 切成 raw 模式，结束时恢复。
public struct RawTerminalMode {
    private let fd: Int32
    private let saved: termios

    public init?(fd: Int32) {
        var attributes = termios()
        guard isatty(fd) == 1, tcgetattr(fd, &attributes) == 0 else { return nil }
        self.fd = fd
        saved = attributes
        var raw = attributes
        cfmakeraw(&raw)
        guard tcsetattr(fd, TCSANOW, &raw) == 0 else { return nil }
    }

    public func restore() {
        var attributes = saved
        tcsetattr(fd, TCSANOW, &attributes)
    }
}

public enum TerminalSize {
    public static func of(_ fd: Int32) -> (cols: Int, rows: Int)? {
        var size = winsize()
        guard ioctl(fd, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else { return nil }
        return (Int(size.ws_col), Int(size.ws_row))
    }
}
