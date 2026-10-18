import Foundation

/// 命令行（`sched`）和运行中的应用之间的通信约定：Unix 域 socket，一行一个 JSON 请求、一行一个 JSON 响应。
/// 所有写入都经过运行中的应用，不直接改 journal.json，否则会被应用下一次保存覆盖。
public enum SchedulerWire {
    public static let version = 1
    /// 单个请求的最大字节数（含图片路径列表），防止异常客户端占满内存。
    public static let maxRequestBytes = 256 * 1024

    /// socket 文件路径：放在数据目录里。Unix socket 路径上限约 104 字节，数据目录路径太长时改用 /tmp 下按目录哈希命名的短路径。
    public static func socketPath(directory: URL) -> String {
        let preferred = directory.appendingPathComponent("scheduler.sock").path
        guard preferred.utf8.count > 100 else { return preferred }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in directory.standardizedFileURL.path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "/tmp/scheduler-\(String(hash, radix: 16)).sock"
    }
}

public struct WireRequest: Codable, Equatable {
    public enum Op: String, Codable { case ping, status, log, todo, done, undone, drop, priority }
    public var version = SchedulerWire.version
    public var op: Op
    /// log：日志正文（可以以 /done /block /plan 开头）；todo：待办（支持「明天 15:00 开会」等自然语言）。
    public var text: String?
    /// log：关联到这个编号的任务；done / undone：要操作的任务编号。
    public var task: Int?
    /// log：要附上的图片文件路径（由应用读取、缩放并保存）。
    public var images: [String]?
    public var priority: TaskPriority?

    public init(op: Op, text: String? = nil, task: Int? = nil, images: [String]? = nil) {
        self.op = op
        self.text = text
        self.task = task
        self.images = images
    }
}

public struct WireResponse: Codable, Equatable {
    public var ok: Bool
    /// 给人看的结果说明。
    public var message: String?
    public var error: String?
    /// 新建的任务或日志的编号 / 短标识。
    public var number: Int?
    public var logID: String?
    /// status：应用版本、今天未完成数、正在专注的任务编号。
    public var info: [String: String]?

    public init(ok: Bool, message: String? = nil, error: String? = nil, number: Int? = nil, logID: String? = nil, info: [String: String]? = nil) {
        self.ok = ok
        self.message = message
        self.error = error
        self.number = number
        self.logID = logID
        self.info = info
    }

    public static func failure(_ error: String) -> WireResponse { WireResponse(ok: false, error: error) }
}
