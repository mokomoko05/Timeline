import Darwin
import Foundation

/// 程序通过 DECSET / DECRST 打开的终端模式。外部终端中途 attach 时要按这些状态补发一遍，
/// 否则 vim 开着鼠标上报、agent 开着 bracketed paste 时，外部终端并不知道。
public struct TerminalModes: Equatable, Sendable {
    /// 要同步给外部终端的私有模式及默认值（备用屏幕由快照单独处理）。
    public static let tracked: [(mode: Int, defaultOn: Bool)] = [
        (1, false),     // 光标键应用模式 DECCKM
        (7, true),      // 自动换行
        (25, true),     // 显示光标
        (66, false),    // 小键盘应用模式 DECNKM
        (1000, false), (1002, false), (1003, false),   // 鼠标上报
        (1004, false),  // 焦点上报
        (1005, false), (1006, false), (1015, false),   // 鼠标编码
        (2004, false),  // bracketed paste
    ]
    private static let trackedSet = Set(tracked.map(\.mode))

    private var values: [Int: Bool] = [:]
    /// `ESC =`：小键盘应用模式。
    public var keypadApplication = false

    public init() {}

    public func isOn(_ mode: Int) -> Bool {
        values[mode] ?? Self.tracked.first { $0.mode == mode }?.defaultOn ?? false
    }

    mutating func set(_ mode: Int, _ on: Bool) {
        guard Self.trackedSet.contains(mode) else { return }
        values[mode] = on
    }

    /// 让刚连上的终端进入同样的模式：每个模式都明确写一遍，不依赖外部终端原来的状态。
    public var restoreSequence: [UInt8] {
        var text = ""
        for (mode, _) in Self.tracked { text += "\u{1b}[?\(mode)\(isOn(mode) ? "h" : "l")" }
        text += keypadApplication ? "\u{1b}=" : "\u{1b}>"
        return Array(text.utf8)
    }

    /// detach 时把外部终端恢复成普通 shell 能用的状态。
    public static let resetSequence: [UInt8] = Array(
        ("\u{1b}[?1049l\u{1b}[r\u{1b}[0m" + tracked.map { "\u{1b}[?\($0.mode)\($0.defaultOn ? "h" : "l")" }.joined() + "\u{1b}>").utf8)
}

/// 处理窗格的输出流：一路跟踪终端模式；有外部终端时，去掉需要终端应答的查询序列再转发。
/// Timeline 自己的 SwiftTerm 已经应答了这些查询，外部终端再答一次，程序就会收到两份应答（屏幕上出现乱码）。
public final class TerminalStreamFilter {
    private enum State {
        case ground
        case escape
        case escapeIntermediate
        case csi
        /// OSC、DCS、APC、PM、SOS：以 ST（ESC \）结束，OSC 也可以用 BEL 结束。
        case string(kind: UInt8)
        case stringEscape(kind: UInt8)
    }

    public private(set) var modes = TerminalModes()
    private var state = State.ground
    private var sequence: [UInt8] = []
    /// 超长的字符串序列（比如 sixel 图片）不再缓存，直接边收边转发（或丢弃）。
    private var streaming = false
    private var streamingDrops = false
    private static let maxBuffered = 64 * 1024

    public init() {}

    /// 处理一段输出。`forward` 为 false 时只更新模式，返回空数组。
    public func process(_ bytes: ArraySlice<UInt8>, forward: Bool) -> [UInt8] {
        var output: [UInt8] = []
        if forward { output.reserveCapacity(bytes.count) }
        bytes.withUnsafeBufferPointer { buffer in
            var index = 0
            let count = buffer.count
            while index < count {
                if case .ground = state {
                    // 普通文字：一次跳到下一个 ESC，整段交出去。
                    let base = buffer.baseAddress!
                    let end = memchr(base + index, 0x1b, count - index).map { UnsafePointer($0.assumingMemoryBound(to: UInt8.self)) - base } ?? count
                    if forward, end > index { output.append(contentsOf: UnsafeBufferPointer(rebasing: buffer[index..<end])) }
                    index = end
                    if index == count { break }
                }
                step(buffer[index], forward: forward, into: &output)
                index += 1
            }
        }
        return output
    }

    private func emitSequence(_ forward: Bool, _ output: inout [UInt8]) {
        if forward { output.append(contentsOf: sequence) }
        sequence.removeAll(keepingCapacity: true)
    }

    private func step(_ byte: UInt8, forward: Bool, into output: inout [UInt8]) {
        switch state {
        case .ground:
            if byte == 0x1b {
                sequence.append(byte)
                state = .escape
            } else if forward {
                output.append(byte)
            }
        case .escape:
            sequence.append(byte)
            switch byte {
            case UInt8(ascii: "["): state = .csi
            case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "_"), UInt8(ascii: "^"), UInt8(ascii: "X"):
                state = .string(kind: byte)
            case 0x20...0x2f: state = .escapeIntermediate
            case 0x1b:
                // ESC ESC：前一个 ESC 单独成立。
                sequence.removeLast()
                emitSequence(forward, &output)
                sequence.append(0x1b)
            default:
                if byte == UInt8(ascii: "=") { modes.keypadApplication = true }
                if byte == UInt8(ascii: ">") { modes.keypadApplication = false }
                if byte == UInt8(ascii: "c") { modes = TerminalModes() }
                emitSequence(forward, &output)
                state = .ground
            }
        case .escapeIntermediate:
            sequence.append(byte)
            if (0x30...0x7e).contains(byte) || byte < 0x20 {
                emitSequence(forward, &output)
                state = .ground
            }
        case .csi:
            if byte == 0x1b {
                // 被新的 ESC 打断：把已收到的部分原样交出去。
                emitSequence(forward, &output)
                sequence.append(byte)
                state = .escape
                return
            }
            sequence.append(byte)
            if (0x40...0x7e).contains(byte) {
                if handleCSI() { emitSequence(forward, &output) } else { sequence.removeAll(keepingCapacity: true) }
                state = .ground
            } else if sequence.count > 256 {
                emitSequence(forward, &output)
                state = .ground
            }
        case .string(let kind):
            if byte == 0x1b {
                // 可能是 ST（ESC \）的开头，先不交出去。
                state = .stringEscape(kind: kind)
            } else if byte == 0x07, kind == UInt8(ascii: "]") {
                finishString([byte], forward: forward, into: &output)
            } else if streaming {
                if forward && !streamingDrops { output.append(byte) }
            } else {
                sequence.append(byte)
                if sequence.count > Self.maxBuffered {
                    streaming = true
                    streamingDrops = !keepString()
                    if !streamingDrops { emitSequence(forward, &output) } else { sequence.removeAll(keepingCapacity: true) }
                }
            }
        case .stringEscape:
            if byte == UInt8(ascii: "\\") {
                finishString([0x1b, byte], forward: forward, into: &output)
            } else {
                // ESC 后不是 \：字符串到此结束，这个 ESC 开始新的序列。
                if streaming {
                    streaming = false
                } else if keepString() {
                    emitSequence(forward, &output)
                } else {
                    sequence.removeAll(keepingCapacity: true)
                }
                sequence = [0x1b]
                state = .escape
                step(byte, forward: forward, into: &output)
            }
        }
    }

    private func finishString(_ terminator: [UInt8], forward: Bool, into output: inout [UInt8]) {
        if streaming {
            if forward && !streamingDrops { output.append(contentsOf: terminator) }
            streaming = false
        } else {
            sequence.append(contentsOf: terminator)
            if keepString() { emitSequence(forward, &output) } else { sequence.removeAll(keepingCapacity: true) }
        }
        state = .ground
    }

    /// 字符串序列是否转发给外部终端。
    private func keepString() -> Bool {
        guard sequence.count >= 2 else { return true }
        let kind = sequence[1]
        let body = sequence.dropFirst(2)
        switch kind {
        case UInt8(ascii: "_"), UInt8(ascii: "^"), UInt8(ascii: "X"):
            // APC（kitty 图片协议等）、PM、SOS：不转发，图片也不保证。
            return false
        case UInt8(ascii: "P"):
            // DECRQSS（$q）、XTGETTCAP（+q）是查询。
            let head = Array(body.prefix(2))
            return !(head == Array("$q".utf8) || head == Array("+q".utf8))
        case UInt8(ascii: "]"):
            // OSC 10;? / 11;? / 4;1;? / 52;c;? 之类的颜色和剪贴板查询。
            var payload = Array(body)
            while let last = payload.last, last == 0x07 || last == 0x1b || last == UInt8(ascii: "\\") { payload.removeLast() }
            return payload.last != UInt8(ascii: "?")
        default:
            return true
        }
    }

    /// 处理完整的 CSI：更新模式；返回 false 表示这是查询，不转发。
    private func handleCSI() -> Bool {
        guard let final = sequence.last else { return true }
        // 绝大多数 CSI（颜色、光标移动、擦除）既不是模式也不是查询：不必解析参数。
        switch final {
        case UInt8(ascii: "h"), UInt8(ascii: "l"), UInt8(ascii: "p"), UInt8(ascii: "c"), UInt8(ascii: "n"),
             UInt8(ascii: "t"), UInt8(ascii: "q"), UInt8(ascii: "u"): break
        default: return true
        }
        let body = sequence.dropFirst(2)
        let inner = body.dropLast()
        let prefix = inner.first.flatMap { (0x3c...0x3f).contains($0) ? $0 : nil }
        let intermediates = inner.filter { (0x20...0x2f).contains($0) }
        let parameters = inner.drop(while: { (0x3c...0x3f).contains($0) }).filter { (0x30...0x3b).contains($0) }
        switch final {
        case UInt8(ascii: "h"), UInt8(ascii: "l"):
            if prefix == UInt8(ascii: "?") {
                for part in parameters.split(separator: UInt8(ascii: ";")) {
                    if let mode = Int(String(decoding: part, as: UTF8.self)) { modes.set(mode, final == UInt8(ascii: "h")) }
                }
            }
            return true
        case UInt8(ascii: "p") where intermediates == [UInt8(ascii: "!")]:
            // DECSTR 软复位。
            modes = TerminalModes()
            return true
        case UInt8(ascii: "p") where intermediates.contains(UInt8(ascii: "$")):
            return false   // DECRQM 查询模式
        case UInt8(ascii: "c"), UInt8(ascii: "n"), UInt8(ascii: "t"):
            return false   // 设备属性、状态 / 光标位置报告、窗口操作与报告
        case UInt8(ascii: "q") where prefix == UInt8(ascii: ">"):
            return false   // XTVERSION
        case UInt8(ascii: "u") where prefix == UInt8(ascii: "?"):
            return false   // kitty 键盘协议查询
        default:
            return true
        }
    }
}
