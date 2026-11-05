import Darwin
import Foundation

public enum ControlSocketError: Error, Equatable, CustomStringConvertible {
    case pathTooLong(String)
    case system(String, Int32)
    case tooLarge
    case closed
    case malformed

    public var description: String {
        switch self {
        case .pathTooLong(let path): return "socket 路径太长：\(path)"
        case .system(let call, let code): return "\(call) 失败：\(String(cString: strerror(code)))"
        case .tooLarge: return "消息超过上限"
        case .closed: return "连接已断开"
        case .malformed: return "无法解析的消息"
        }
    }

    /// 连接失败是因为没有服务在监听（应用没开，或关掉了命令行控制）。
    public var isNotListening: Bool {
        if case .system("connect", let code) = self { return code == ENOENT || code == ECONNREFUSED }
        return false
    }
}

/// Unix domain socket 的收发小工具，应用和 `tl` 共用。
public enum ControlSocket {
    public static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw ControlSocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    public static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSocketError.system("socket", errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    public static func setTimeout(_ fd: Int32, seconds: TimeInterval) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    public static func connect(path: String, timeout: TimeInterval = 15) throws -> Int32 {
        var address = try address(path)
        let fd = try makeSocket()
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw ControlSocketError.system("connect", code)
        }
        setTimeout(fd, seconds: timeout)
        return fd
    }

    /// 读到换行或对方关闭为止（不含换行）。
    public static func readLine(_ fd: Int32, limit: Int = ControlProtocol.maxMessageBytes) throws -> Data {
        try readLineWithRest(fd, limit: limit).line
    }

    /// 同上，另外交回换行之后已经读到的字节（attach 握手后紧跟着的帧）。
    public static func readLineWithRest(_ fd: Int32, limit: Int = ControlProtocol.maxMessageBytes) throws -> (line: Data, rest: [UInt8]) {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw ControlSocketError.system("read", errno)
            }
            if count == 0 {
                guard !result.isEmpty else { throw ControlSocketError.closed }
                return (result, [])
            }
            if let newline = buffer[0..<count].firstIndex(of: 10) {
                result.append(contentsOf: buffer[0..<newline])
                return (result, Array(buffer[(newline + 1)..<count]))
            }
            result.append(contentsOf: buffer[0..<count])
            if result.count > limit { throw ControlSocketError.tooLarge }
        }
    }

    public static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ControlSocketError.system("write", errno)
                }
                offset += written
            }
        }
    }

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(10)
        return data
    }

    /// attach：发请求、读应答，连接保持打开（不再有超时）。返回连接和应答之后已经到达的字节。
    public static func open(_ request: ControlRequest, path: String, timeout: TimeInterval = 15) throws -> (fd: Int32, response: ControlResponse, rest: [UInt8]) {
        let fd = try connect(path: path, timeout: timeout)
        do {
            try writeAll(fd, try encodeLine(request))
            let (line, rest) = try readLineWithRest(fd)
            guard let response = try? JSONDecoder().decode(ControlResponse.self, from: line) else { throw ControlSocketError.malformed }
            setTimeout(fd, seconds: 0)
            return (fd, response, rest)
        } catch {
            close(fd)
            throw error
        }
    }

    /// 发一条请求、等一条应答。会阻塞调用线程，不要在应用主线程上调用。
    public static func send(_ request: ControlRequest, path: String, timeout: TimeInterval = 15) throws -> ControlResponse {
        let fd = try connect(path: path, timeout: timeout)
        defer { close(fd) }
        try writeAll(fd, try encodeLine(request))
        let line = try readLine(fd)
        guard let response = try? JSONDecoder().decode(ControlResponse.self, from: line) else { throw ControlSocketError.malformed }
        return response
    }
}
