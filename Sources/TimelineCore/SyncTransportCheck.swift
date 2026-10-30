import Foundation

extension FolderSync {
    /// 开发诊断：只交换随机校验串，不写日志、任务或同步记录。
    /// 另一端读到 request 后原样写 reply，才能证明真实双向传输完成。
    public func verifyTransport(probe: String, timeout: TimeInterval = 45) async throws -> TimeInterval {
        guard IncrementalSync.safe(probe) else { throw CocoaError(.fileWriteInvalidFileName) }
        let folder = folder
        let task = Task.detached(priority: .utility) {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            let root = folder.appendingPathComponent("transport-checks").appendingPathComponent(probe)
            let request = root.appendingPathComponent("request.txt")
            let reply = root.appendingPathComponent("reply.txt")
            let payload = Data(probe.utf8)
            let started = ProcessInfo.processInfo.systemUptime
            defer {
                // 只清理本次随机目录，不触碰正式同步文件。
                try? IncrementalSync.remove(root)
            }
            try Self.coordinatedWrite(payload, to: request)
            while ProcessInfo.processInfo.systemUptime - started < timeout {
                try Task.checkCancellation()
                // 目录同样要协调枚举，云端新文件可能尚未成为本地可见条目。
                _ = try Self.coordinatedDirectoryContents(root)
                if try IncrementalSync.available(reply),
                   try Self.coordinatedRead(reply) == payload {
                    return ProcessInfo.processInfo.systemUptime - started
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            throw SyncError.timeout
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
