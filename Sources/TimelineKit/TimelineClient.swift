import Foundation
import TimelineCore

public enum ClientError: LocalizedError, Equatable {
    case notRunning
    case timeout
    case io(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: return "Timeline 没有在运行（连不上 socket）。请先打开应用，或去掉 --no-launch 让命令自动启动它。"
        case .timeout: return "等待 Timeline 响应超时。"
        case .io(let text): return "与 Timeline 通信失败：\(text)"
        case .badResponse(let text): return "Timeline 返回了无法理解的内容：\(text)"
        }
    }
}

/// 通过 Unix 域 socket 把写操作交给运行中的应用。
public struct TimelineClient {
    public var socketPath: String
    public var timeout: TimeInterval = 5
    /// 应用没在运行时，用它启动应用；nil 表示不自动启动。
    public var launch: (() -> Void)?
    public var launchWait: TimeInterval = 12

    public init(socketPath: String, launch: (() -> Void)? = nil) {
        self.socketPath = socketPath
        self.launch = launch
    }

    public static func openApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-b", "local.timeline.app"]
        try? process.run()
        process.waitUntilExit()
    }

    /// 连接。服务端同时来了很多连接（比如脚本里并行调用 timeline）时，系统会短暂拒绝多出来的连接，
    /// 这和「应用没在运行」要区分开：socket 文件还在就是忙，稍等重试；文件不存在才是真的没在运行。
    private func connectWithRetry() -> Int32? {
        for attempt in 0..<16 {
            if let fd = connect() { return fd }
            guard FileManager.default.fileExists(atPath: socketPath) else { return nil }
            Thread.sleep(forTimeInterval: 0.01 * Double(min(attempt + 1, 6)))
        }
        return nil
    }

    public func send(_ request: WireRequest) -> Result<WireResponse, ClientError> {
        var descriptor = connectWithRetry()
        if descriptor == nil, let launch {
            launch()
            let deadline = Date().addingTimeInterval(launchWait)
            while descriptor == nil, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.2)
                descriptor = connect()
            }
        }
        guard let fd = descriptor else { return .failure(.notRunning) }
        defer { close(fd) }
        guard var payload = try? JSONEncoder().encode(request) else { return .failure(.io("无法编码请求")) }
        payload.append(0x0A)
        var offset = 0
        while offset < payload.count {
            let n = payload.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + offset, payload.count - offset, 0) }
            if n <= 0 { return .failure(errno == EAGAIN ? .timeout : .io(String(cString: strerror(errno)))) }
            offset += n
        }
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !received.contains(0x0A), received.count < 1_000_000 {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n < 0 { return .failure(errno == EAGAIN || errno == EWOULDBLOCK ? .timeout : .io(String(cString: strerror(errno)))) }
            if n == 0 { break }
            received.append(chunk, count: n)
        }
        guard let line = received.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: true).first else { return .failure(.badResponse("空响应")) }
        do { return .success(try JSONDecoder().decode(WireResponse.self, from: Data(line))) }
        catch { return .failure(.badResponse(String(decoding: line.prefix(200), as: UTF8.self))) }
    }

    /// 连接成功返回描述符；连不上（没有 socket 文件、没人监听）返回 nil。
    private func connect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: bytes.count + 1) { dest in
                for (index, byte) in bytes.enumerated() { dest[index] = byte }
                dest[bytes.count] = 0
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Foundation.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); return nil }
        return fd
    }
}
