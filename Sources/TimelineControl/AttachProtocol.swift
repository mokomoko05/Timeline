import Foundation

/// `tl attach` 握手之后的二进制帧：`[类型 1 字节][长度 4 字节，大端][数据]`。
public enum AttachFrameType: UInt8, Sendable {
    /// 客户端 → Timeline：键盘输入。
    case input = 1
    /// Timeline → 客户端：要写到终端上的字节。
    case output = 2
    /// 客户端 → Timeline：终端尺寸（列、行各 2 字节）。
    case resize = 3
    /// 客户端 → Timeline：断开。
    case detach = 4
    /// Timeline → 客户端：窗格里的 shell 结束了（1 字节有无退出码 + 4 字节退出码）。
    case exit = 5
}

public struct AttachFrame: Equatable, Sendable {
    public var type: AttachFrameType
    public var payload: [UInt8]

    public init(_ type: AttachFrameType, _ payload: [UInt8] = []) {
        self.type = type
        self.payload = payload
    }

    public static let maxPayload = 16 << 20

    public var encoded: [UInt8] {
        let count = UInt32(payload.count)
        return [type.rawValue, UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)] + payload
    }

    public static func resize(cols: Int, rows: Int) -> AttachFrame {
        let c = UInt16(clamping: cols), r = UInt16(clamping: rows)
        return AttachFrame(.resize, [UInt8(c >> 8), UInt8(c & 255), UInt8(r >> 8), UInt8(r & 255)])
    }

    public var size: (cols: Int, rows: Int)? {
        guard type == .resize, payload.count == 4 else { return nil }
        return (Int(payload[0]) << 8 | Int(payload[1]), Int(payload[2]) << 8 | Int(payload[3]))
    }

    public static func exit(code: Int32?) -> AttachFrame {
        let value = UInt32(bitPattern: code ?? 0)
        return AttachFrame(.exit, [code == nil ? 0 : 1, UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
    }

    public var exitCode: Int32? {
        guard type == .exit, payload.count == 5, payload[0] == 1 else { return nil }
        return Int32(bitPattern: UInt32(payload[1]) << 24 | UInt32(payload[2]) << 16 | UInt32(payload[3]) << 8 | UInt32(payload[4]))
    }
}

public enum AttachProtocolError: Error, Equatable {
    case unknownFrame(UInt8)
    case tooLarge
}

/// 按到达顺序拼出完整的帧；数据可以在任意位置被切开。
public struct AttachFrameDecoder {
    private var buffer: [UInt8] = []
    private var offset = 0

    public init() {}

    public mutating func append<C: Collection>(_ bytes: C) throws -> [AttachFrame] where C.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var frames: [AttachFrame] = []
        while buffer.count - offset >= 5 {
            let length = Int(buffer[offset + 1]) << 24 | Int(buffer[offset + 2]) << 16 | Int(buffer[offset + 3]) << 8 | Int(buffer[offset + 4])
            guard length <= AttachFrame.maxPayload else { throw AttachProtocolError.tooLarge }
            guard buffer.count - offset - 5 >= length else { break }
            guard let type = AttachFrameType(rawValue: buffer[offset]) else { throw AttachProtocolError.unknownFrame(buffer[offset]) }
            frames.append(AttachFrame(type, Array(buffer[(offset + 5)..<(offset + 5 + length)])))
            offset += 5 + length
        }
        if offset > 0, offset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            offset = 0
        } else if offset > 64 * 1024 {
            buffer.removeFirst(offset)
            offset = 0
        }
        return frames
    }
}

/// detach 键：`Ctrl-]` 然后 `d`；`Ctrl-]` 按两次送出一个真正的 `Ctrl-]`；`Ctrl-]` 后面跟别的键时两个都原样送出。
public struct DetachKeyFilter {
    public static let prefix: UInt8 = 0x1d
    public static let detachKey = UInt8(ascii: "d")
    private var pending = false

    public init() {}

    public mutating func feed<C: Collection>(_ bytes: C) -> (forward: [UInt8], detach: Bool) where C.Element == UInt8 {
        var forward: [UInt8] = []
        forward.reserveCapacity(bytes.count)
        for byte in bytes {
            if pending {
                pending = false
                if byte == Self.detachKey || byte == Self.detachKey - 32 { return (forward, true) }
                if byte == Self.prefix { forward.append(Self.prefix); continue }
                forward.append(Self.prefix)
                forward.append(byte)
            } else if byte == Self.prefix {
                pending = true
            } else {
                forward.append(byte)
            }
        }
        return (forward, false)
    }
}
