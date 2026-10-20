import AppKit
import TimelineCore

/// 处理命令行（`timeline`）发来的写请求。直接操作应用里正在用的 JournalStore，所以界面立刻更新、撤销栈也一致；
/// 每次写入后立即落盘，命令行紧接着读数据文件就能看到。
@MainActor
final class TimelineService {
    let store: JournalStore
    var appVersion: String
    /// 保存图片文件后补识别文字；测试里替换掉，避免真的跑 Vision。
    var indexImages: () -> Void

    init(store: JournalStore, appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
         indexImages: (() -> Void)? = nil) {
        self.store = store
        self.appVersion = appVersion
        self.indexImages = indexImages ?? { [store] in ImageIndexer.run(store: store) }
    }

    static let maxImages = 10
    static let maxImageBytes = 50 * 1024 * 1024

    func handle(_ request: WireRequest) -> WireResponse {
        guard request.version <= TimelineWire.version else {
            return .failure("命令行版本比应用新（协议 \(request.version) > \(TimelineWire.version)），请更新应用。")
        }
        switch request.op {
        case .ping: return WireResponse(ok: true, message: "pong")
        case .status: return status()
        case .log: return log(request)
        case .todo: return todo(request)
        case .done: return setCompleted(true, request)
        case .undone: return setCompleted(false, request)
        case .drop: return dropTask(request)
        case .priority:
            guard !store.isReadOnly else { return .failure("当前数据只读，无法写入。") }
            guard let number = request.task, let item = store.locate(number: number), let priority = request.priority else {
                return .failure("请提供有效任务编号和优先级。")
            }
            store.setPriority(priority, for: item.id)
            store.save()
            guard !store.hasPendingSave else { return .failure("保存失败，请在应用中重试。") }
            return WireResponse(ok: true, message: "已设置优先级：" + priority.title, number: number)
        }
    }

    private func status() -> WireResponse {
        let open = store.sortedTasks().filter { !$0.task.completed }.count
        var info = ["version": appVersion, "open": String(open), "readOnly": store.isReadOnly ? "1" : "0"]
        info["focus"] = store.focusTask?.task.number.map(String.init) ?? ""
        return WireResponse(ok: true, message: "运行中", info: info)
    }

    private func label(_ item: ScheduledTask) -> String {
        let title = String(TaskText.rendered(item.task.title).characters)
        let short = title.count > 28 ? String(title.prefix(28)) + "…" : title
        return "#\(item.task.number ?? 0) \(short)"
    }

    private func log(_ request: WireRequest) -> WireResponse {
        guard !store.isReadOnly else { return .failure("当前数据只读（读取出错或被保护），无法写入。") }
        let raw = (request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var kind = DailyLogKind.note
        var body = raw
        if !raw.isEmpty {
            do {
                switch try LogCommand.parse(raw) {
                case .entry(let parsedKind, let parsedBody): kind = parsedKind; body = parsedBody
                default: return .failure("timeline log 不支持 /link /unlink /filter /summary /help；要关联任务请用 -t N 或在正文开头写 #N。")
                }
            } catch { return .failure(error.localizedDescription) }
        }
        // 任务：明确的 -t 优先，否则正文开头的 #N。
        var number = request.task
        if number == nil {
            let split = LogCommand.splitTaskReference(body)
            if let found = split.number { number = found; body = split.rest }
        }
        var located: ScheduledTask?
        if let number {
            guard let item = store.locate(number: number) else { return .failure("没有编号为 #\(number) 的任务。") }
            located = item
        }
        var names: [String] = []
        let paths = request.images ?? []
        if !paths.isEmpty {
            guard paths.count <= Self.maxImages else { return .failure("一次最多附 \(Self.maxImages) 张图片。") }
            var datas: [Data] = []
            for path in paths {
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: url.path) else { return .failure("找不到图片文件：\(path)") }
                guard ImageTools.isImageFile(url) else { return .failure("不是图片文件：\(path)") }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= Self.maxImageBytes else { return .failure("图片太大（超过 50MB）：\(path)") }
                guard let data = try? Data(contentsOf: url) else { return .failure("无法读取图片：\(path)") }
                datas.append(data)
            }
            names = ImageTools.save(datas, in: store)
            guard names.count == datas.count else { return .failure("有图片无法处理（格式损坏？），未写入任何内容。") }
        }
        guard !body.isEmpty || !names.isEmpty else { return .failure("日志内容为空。") }
        let now = Date()
        do {
            // 总是带上 /kind 前缀：正文本身以 / 开头时也不会被当成命令再解析一遍。
            _ = try store.quickLog(body.isEmpty ? "" : "/\(kind.rawValue) \(body)", images: names, taskID: located?.id, on: now, now: now)
        } catch { return .failure(error.localizedDescription) }
        var completed = false
        // 和界面一致：明确指定任务的 /done 同时完成这个任务。
        if kind == .done, let located, !located.task.completed {
            store.toggleTodo(located.id, on: located.date)
            completed = true
        }
        let logged = store.entry(for: now).logs.last
        // 没有明确指定任务时，专注中的任务会兜底关联（和界面一致），回显实际关联到了谁。
        let linkedNumber = logged?.taskNumber
        let linked = logged?.taskID.flatMap { store.locate($0) }
        store.save()
        if !names.isEmpty { indexImages() }
        var message = "已记录"
        if let linked { message += " → " + label(linked) } else if let linkedNumber { message += " → #\(linkedNumber)" }
        if !names.isEmpty { message += "，含 \(names.count) 张图片" }
        if completed { message += "，并完成了任务" }
        return WireResponse(ok: true, message: message, number: linkedNumber, logID: logged.map { String($0.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)) })
    }

    private func todo(_ request: WireRequest) -> WireResponse {
        guard !store.isReadOnly else { return .failure("当前数据只读，无法写入。") }
        let text = (request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure("待办内容为空。") }
        guard let added = store.addParsedTodo(text, on: Date(), priority: request.priority ?? .normal) else { return .failure("添加失败。") }
        store.save()
        guard !store.hasPendingSave else { return .failure("保存失败，请在应用中重试。") }
        var message = "已添加 " + label(added)
        if let due = added.task.dueDate {
            var text = due.relativeLabel
            if added.task.dueHasTime {
                let parts = JournalDates.calendar.dateComponents([.hour, .minute], from: due)
                text += String(format: " %02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
            }
            message += "，截止 \(text)"
        } else {
            message += "，还没有截止日期"
        }
        if !added.task.tags.isEmpty { message += "，标签 " + added.task.tags.map { "#" + $0 }.joined(separator: " ") }
        return WireResponse(ok: true, message: message, number: added.task.number)
    }

    private func setCompleted(_ completed: Bool, _ request: WireRequest) -> WireResponse {
        guard !store.isReadOnly else { return .failure("当前数据只读，无法写入。") }
        guard let number = request.task else { return .failure("缺少任务编号。") }
        guard let item = store.locate(number: number) else { return .failure("没有编号为 #\(number) 的任务。") }
        if item.task.isDropped {
            // 放弃的待办：done 先恢复再完成，undone 就是恢复。
            store.toggleTodo(item.id, on: item.date)
            if completed { store.toggleTodo(item.id, on: item.date) }
            store.save()
            return WireResponse(ok: true, message: (completed ? "已完成 " : "已恢复 ") + label(item), number: number)
        }
        if item.task.completed == completed {
            return WireResponse(ok: true, message: label(item) + (completed ? " 本来就是完成状态" : " 本来就没有完成"), number: number)
        }
        store.toggleTodo(item.id, on: item.date)
        store.save()
        return WireResponse(ok: true, message: (completed ? "已完成 " : "已取消完成 ") + label(item), number: number)
    }

    /// 放弃一个待办（不用再做了，留着记录）；已经放弃的恢复。已完成的先 undone。
    private func dropTask(_ request: WireRequest) -> WireResponse {
        guard !store.isReadOnly else { return .failure("当前数据只读，无法写入。") }
        guard let number = request.task else { return .failure("缺少任务编号。") }
        guard let item = store.locate(number: number) else { return .failure("没有编号为 #\(number) 的任务。") }
        guard store.dropTodo(item.id, on: item.date) else { return .failure(label(item) + " 已经完成，不能放弃；要改请先 timeline undone \(number)。") }
        store.save()
        return WireResponse(ok: true, message: (item.task.isDropped ? "已恢复 " : "已放弃 ") + label(item), number: number)
    }
}

/// 监听 Unix 域 socket：一行一个 JSON 请求，一行一个 JSON 响应。
/// 只接受同一用户的连接（socket 文件权限 0600，并校验对端 uid）。
final class TimelineServer {
    enum StartError: Error, Equatable {
        case alreadyRunning
        case io(String)
    }

    let path: String
    private let handler: @MainActor (WireRequest) -> WireResponse
    private var source: DispatchSourceRead?
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "timeline.socket.accept")
    private let workQueue = DispatchQueue(label: "timeline.socket.work", attributes: .concurrent)

    init(path: String, handler: @escaping @MainActor (WireRequest) -> WireResponse) {
        self.path = path
        self.handler = handler
    }

    deinit { stop() }

    var isRunning: Bool { source != nil }

    func start() throws {
        guard source == nil else { return }
        // 客户端随时可能断开（Ctrl-C、只探测一下就走）：往已关闭的连接写数据不能让整个应用收到 SIGPIPE 退出。
        signal(SIGPIPE, SIG_IGN)
        // 已经有别的实例在监听就不抢；留下的是上次崩溃遗留的死 socket 才清掉。
        if FileManager.default.fileExists(atPath: path) {
            if Self.canConnect(path) { throw StartError.alreadyRunning }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.io("socket: \(String(cString: strerror(errno)))") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); throw StartError.io("socket 路径太长") }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: bytes.count + 1) { dest in
                for (index, byte) in bytes.enumerated() { dest[index] = byte }
                dest[bytes.count] = 0
            }
        }
        let previousMask = umask(0o177)   // 新建的 socket 文件只有当前用户可读写
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previousMask)
        guard bound == 0 else { let message = String(cString: strerror(errno)); close(fd); throw StartError.io("bind: \(message)") }
        chmod(path, 0o600)
        guard listen(fd, 128) == 0 else { let message = String(cString: strerror(errno)); close(fd); unlink(path); throw StartError.io("listen: \(message)") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        let socketPath = path
        source.setCancelHandler { close(fd); unlink(socketPath) }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        listenFD = -1
    }

    static func canConnect(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: bytes.count + 1) { dest in
                for (index, byte) in bytes.enumerated() { dest[index] = byte }
                dest[bytes.count] = 0
            }
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }   // EAGAIN：没有更多等待的连接
            // macOS 上 accept 出来的连接会继承监听 socket 的非阻塞标志；必须清掉，否则客户端连上后稍晚一点才发数据时，
            // recv 会立刻返回「没数据」，被当成空请求而断开连接。
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            // 对端（比如只探测一下「有没有实例在监听」的客户端）可能已经走了：往里写不能让整个应用收到 SIGPIPE 而退出。
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            workQueue.async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // 只接受同一用户。
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
            reply(fd, .failure("拒绝：连接不属于当前用户。"))
            return
        }
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !received.contains(0x0A) {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            received.append(chunk, count: n)
            if received.count > TimelineWire.maxRequestBytes {
                reply(fd, .failure("请求太大（超过 \(TimelineWire.maxRequestBytes / 1024) KB）。"))
                return
            }
        }
        guard let line = received.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: true).first else {
            reply(fd, .failure("空请求。"))
            return
        }
        guard let request = try? JSONDecoder().decode(WireRequest.self, from: Data(line)) else {
            reply(fd, .failure("无法解析请求（需要一行 JSON）。"))
            return
        }
        var response = WireResponse.failure("应用忙，处理超时。")
        let done = DispatchSemaphore(value: 0)
        let handler = self.handler
        DispatchQueue.main.async {
            MainActor.assumeIsolated { response = handler(request) }
            done.signal()
        }
        if done.wait(timeout: .now() + 10) == .timedOut { response = .failure("应用忙，处理超时。") }
        reply(fd, response)
    }

    private func reply(_ fd: Int32, _ response: WireResponse) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        var offset = 0
        let count = data.count
        while offset < count {
            let n = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + offset, count - offset, 0) }
            if n <= 0 { return }
            offset += n
        }
    }
}
