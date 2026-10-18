import AppKit
import XCTest
import DayleafCore
import SchedKit
@testable import Dayleaf

@MainActor
final class SchedulerServiceTests: XCTestCase {
    private func make() throws -> (SchedulerService, JournalStore, Int) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("svc-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        store.addTodo("读论文 [链接](https://a.example.com/x)", on: Date())
        store.addTodo("写周报", on: Date())
        var indexed = 0
        let service = SchedulerService(store: store, appVersion: "9.9", indexImages: { indexed += 1 })
        _ = indexed
        return (service, store, 0)
    }

    private func todayLogs(_ store: JournalStore) -> [DailyLogEntry] { store.entry(for: Date()).logs.filter { !$0.focus } }

    func testPriorityRequestsPersistAndRejectMissingArguments() throws {
        let (service, store, _) = try make()
        var request = WireRequest(op: .priority, task: 1)
        XCTAssertFalse(service.handle(request).ok)
        request.priority = .high
        XCTAssertTrue(service.handle(request).ok)
        XCTAssertEqual(JournalStore(directory: store.directory, readOnlySnapshot: true).locate(number: 1)?.task.priority, .high)
        request.task = 999
        XCTAssertFalse(service.handle(request).ok)
        var create = WireRequest(op: .todo, text: "明天 15:00 Review")
        create.priority = .low
        let response = service.handle(create)
        XCTAssertTrue(response.ok)
        let item = try XCTUnwrap(store.locate(number: try XCTUnwrap(response.number)))
        XCTAssertEqual(item.task.priority, .low)
        XCTAssertTrue(item.task.dueHasTime)
    }

    func testLogLinksByExplicitTaskInlineReferenceAndFocusFallbackWithPrecedence() throws {
        let (service, store, _) = try make()
        var response = service.handle(WireRequest(op: .log, text: "读到第三节", task: 1))
        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.number, 1)
        XCTAssertTrue(response.message?.contains("#1 读论文") == true, response.message ?? "")
        XCTAssertEqual(todayLogs(store).last?.taskNumber, 1)
        XCTAssertEqual(response.logID, String(todayLogs(store).last!.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)))

        response = service.handle(WireRequest(op: .log, text: "#2 周报写了一半"))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(todayLogs(store).last?.taskNumber, 2)
        XCTAssertEqual(todayLogs(store).last?.text, "周报写了一半", "正文开头的 #N 被当作关联，不留在正文里")

        response = service.handle(WireRequest(op: .log, text: "#2 显式的优先", task: 1))
        XCTAssertEqual(todayLogs(store).last?.taskNumber, 1, "-t 优先于正文里的 #N")

        response = service.handle(WireRequest(op: .log, text: "没有任务"))
        XCTAssertNil(todayLogs(store).last?.taskID)
        XCTAssertEqual(response.message, "已记录")

        store.setFocusTask(store.locate(number: 2)?.id)
        response = service.handle(WireRequest(op: .log, text: "专注期间的日志"))
        XCTAssertEqual(todayLogs(store).last?.taskNumber, 2, "专注中自动关联到专注的任务，和界面一致")
        XCTAssertTrue(response.message?.contains("#2") == true)
        response = service.handle(WireRequest(op: .log, text: "显式指定", task: 1))
        XCTAssertEqual(todayLogs(store).last?.taskNumber, 1, "显式指定仍然优先")
    }

    func testDropAndRestoreThroughTheService() throws {
        let (service, store, _) = try make()
        var response = service.handle(WireRequest(op: .drop, task: 2))
        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertTrue(response.message?.contains("已放弃") == true)
        XCTAssertTrue(store.locate(number: 2)!.task.isDropped)

        response = service.handle(WireRequest(op: .done, task: 2))
        XCTAssertTrue(response.ok)
        XCTAssertTrue(store.locate(number: 2)!.task.isDone, "放弃的可以直接标记完成")

        response = service.handle(WireRequest(op: .drop, task: 2))
        XCTAssertFalse(response.ok, "已完成的不能放弃")

        _ = service.handle(WireRequest(op: .undone, task: 2))
        _ = service.handle(WireRequest(op: .drop, task: 2))
        response = service.handle(WireRequest(op: .undone, task: 2))
        XCTAssertTrue(response.message?.contains("已恢复") == true)
        XCTAssertFalse(store.locate(number: 2)!.task.completed)
        XCTAssertFalse(service.handle(WireRequest(op: .drop, task: 99)).ok)
    }

    func testLogKindsDoneCompletesOnlyAnExplicitTaskAndBadInputIsRejected() throws {
        let (service, store, _) = try make()
        var response = service.handle(WireRequest(op: .log, text: "/block 卡在公式", task: 1))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(todayLogs(store).last?.kind, .block)
        XCTAssertFalse(store.locate(number: 1)!.task.completed)

        response = service.handle(WireRequest(op: .log, text: "/done 读完了", task: 1))
        XCTAssertTrue(response.ok)
        XCTAssertTrue(store.locate(number: 1)!.task.completed, "明确指定任务的 /done 同时完成任务，和界面一致")
        XCTAssertTrue(response.message?.contains("并完成了任务") == true)

        response = service.handle(WireRequest(op: .log, text: "/done 没有指定任务"))
        XCTAssertTrue(response.ok)
        XCTAssertFalse(store.locate(number: 2)!.task.completed)

        for text in ["/link #1", "/filter 1", "/help", "/summary"] {
            XCTAssertFalse(service.handle(WireRequest(op: .log, text: text)).ok, text)
        }
        XCTAssertEqual(service.handle(WireRequest(op: .log, text: "/bogus x")).ok, false)
        XCTAssertEqual(service.handle(WireRequest(op: .log, text: "   ")).ok, false, "空内容")
        XCTAssertEqual(service.handle(WireRequest(op: .log, text: "x", task: 99)).error, "没有编号为 #99 的任务。")
        XCTAssertEqual(service.handle(WireRequest(op: .log, text: "#99 x")).error, "没有编号为 #99 的任务。")
        XCTAssertEqual(service.handle(WireRequest(op: .log, text: "/etc/hosts 是个文件", task: 2)).ok, true, "以 / 开头但不是命令的路径正文照常记录")
        XCTAssertEqual(todayLogs(store).last?.text, "/etc/hosts 是个文件")
    }

    func testImagesAreStoredAndValidated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("svc-img-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory.appendingPathComponent("data"))
        store.addTodo("任务", on: Date())
        var indexed = 0
        let service = SchedulerService(store: store, indexImages: { indexed += 1 })
        let png = directory.appendingPathComponent("a.png")
        let image = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        let text = directory.appendingPathComponent("b.txt")
        try Data("not an image".utf8).write(to: text)

        var response = service.handle(WireRequest(op: .log, text: "看图", task: 1, images: [png.path]))
        XCTAssertTrue(response.ok, response.error ?? "")
        let log = try XCTUnwrap(store.entry(for: Date()).logs.last)
        XCTAssertEqual(log.images.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageURL(log.images[0]).path), "图片被复制进数据目录的 Images")
        XCTAssertEqual(indexed, 1, "保存图片后触发识别文字")
        XCTAssertTrue(response.message?.contains("含 1 张图片") == true)

        response = service.handle(WireRequest(op: .log, text: nil, images: [png.path]))
        XCTAssertTrue(response.ok, "只有图片、没有文字也可以")
        let before = store.entry(for: Date()).logs.count
        XCTAssertFalse(service.handle(WireRequest(op: .log, text: "x", images: [text.path])).ok, "不是图片")
        XCTAssertFalse(service.handle(WireRequest(op: .log, text: "x", images: [directory.appendingPathComponent("none.png").path])).ok)
        XCTAssertFalse(service.handle(WireRequest(op: .log, text: "x", images: Array(repeating: png.path, count: 11))).ok, "最多 10 张")
        XCTAssertEqual(store.entry(for: Date()).logs.count, before, "任何一张图有问题都不写入")
    }

    func testTodoDoneUndoneStatusAndVersionAndReadOnly() throws {
        let (service, store, _) = try make()
        var response = service.handle(WireRequest(op: .todo, text: "明天 15:00 开会 提前30分钟"))
        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.number, 3)
        XCTAssertTrue(response.message?.contains("#3") == true && response.message?.contains("明天 15:00") == true, response.message ?? "")
        XCTAssertNotNil(store.locate(number: 3)?.task.dueDate)
        XCTAssertEqual(store.locate(number: 3)?.task.reminderMinutes, 30, "自然语言解析和界面里的快速添加一致")
        response = service.handle(WireRequest(op: .todo, text: "买牛奶"))
        XCTAssertTrue(response.message?.contains("还没有截止日期") == true)
        response = service.handle(WireRequest(op: .todo, text: "写报告 #项目A #紧急"))
        XCTAssertEqual(store.locate(number: response.number ?? 0)?.task.tags, ["项目A", "紧急"], "命令行添加待办也能带标签")
        XCTAssertTrue(response.message?.contains("#项目A") == true, response.message ?? "")
        XCTAssertFalse(service.handle(WireRequest(op: .todo, text: "  ")).ok)

        response = service.handle(WireRequest(op: .done, task: 2))
        XCTAssertTrue(response.ok)
        XCTAssertTrue(store.locate(number: 2)!.task.completed)
        XCTAssertTrue(service.handle(WireRequest(op: .done, task: 2)).message?.contains("本来就是完成状态") == true)
        XCTAssertTrue(service.handle(WireRequest(op: .undone, task: 2)).ok)
        XCTAssertFalse(store.locate(number: 2)!.task.completed)
        XCTAssertFalse(service.handle(WireRequest(op: .done, task: 77)).ok)
        XCTAssertFalse(service.handle(WireRequest(op: .done)).ok)

        response = service.handle(WireRequest(op: .status))
        XCTAssertEqual(response.info?["version"], "9.9")
        XCTAssertEqual(response.info?["open"], "5", "含上面带标签的那条")
        XCTAssertEqual(response.info?["focus"], "")
        store.setFocusTask(store.locate(number: 1)?.id)
        XCTAssertEqual(service.handle(WireRequest(op: .status)).info?["focus"], "1")
        XCTAssertEqual(service.handle(WireRequest(op: .ping)).message, "pong")

        var future = WireRequest(op: .ping)
        future.version = SchedulerWire.version + 1
        XCTAssertFalse(service.handle(future).ok, "命令行比应用新时明确拒绝")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("svc-ro-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Data("{ broken".utf8).write(to: directory.appendingPathComponent("journal.json"))
        let protected = SchedulerService(store: JournalStore(directory: directory))
        for request in [WireRequest(op: .log, text: "x"), WireRequest(op: .todo, text: "x"), WireRequest(op: .done, task: 1)] {
            XCTAssertFalse(protected.handle(request).ok, "读取出错被保护的数据，一律拒绝写入")
        }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("journal.json")), "{ broken")
    }

    func testEveryWriteIsFlushedToDiskImmediately() throws {
        let (service, store, _) = try make()
        _ = service.handle(WireRequest(op: .log, text: "立刻落盘", task: 1))
        _ = service.handle(WireRequest(op: .todo, text: "新待办"))
        let onDisk = JournalStore(directory: store.directory, readOnlySnapshot: true)
        XCTAssertTrue(onDisk.allLogs().contains { $0.log.text == "立刻落盘" }, "命令行紧接着读数据文件就能看到，不用等应用的 250ms 合并保存")
        XCTAssertNotNil(onDisk.locate(number: 3))
    }
}

@MainActor
final class SchedulerSocketTests: XCTestCase {
    private struct Rig {
        let directory: URL
        let store: JournalStore
        let service: SchedulerService
        let server: SchedulerServer
        var path: String { server.path }
    }

    private func rig(path customPath: String? = nil, start: Bool = true) throws -> Rig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sock-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        store.addTodo("读论文", on: Date())
        store.addTodo("写周报", on: Date())
        let service = SchedulerService(store: store, appVersion: "test", indexImages: {})
        let server = SchedulerServer(path: customPath ?? SchedulerWire.socketPath(directory: directory)) { [service] in service.handle($0) }
        addTeardownBlock { server.stop() }
        if start { try server.start() }
        return Rig(directory: directory, store: store, service: service, server: server)
    }

    /// 客户端在后台线程发请求，主线程空出来给服务处理（和真实情况一样：客户端是另一个进程）。
    private func send(_ request: WireRequest, to path: String) async -> Result<WireResponse, ClientError> {
        await Task.detached { SchedulerClient(socketPath: path).send(request) }.value
    }

    private func raw(_ bytes: Data, to path: String, closeWrite: Bool = true) async -> String {
        await Task.detached {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let chars = Array(path.utf8)
            withUnsafeMutablePointer(to: &address.sun_path) { p in
                p.withMemoryRebound(to: UInt8.self, capacity: chars.count + 1) { d in
                    for (i, b) in chars.enumerated() { d[i] = b }
                    d[chars.count] = 0
                }
            }
            let rc = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard rc == 0 else { return "CONNECT-FAILED" }
            var tv = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var offset = 0
            let total = bytes.count
            while offset < total {
                let n = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + offset, total - offset, 0) }
                if n <= 0 { break }
                offset += n
            }
            var out = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while !out.contains(0x0A) {
                let n = recv(fd, &chunk, chunk.count, 0)
                if n <= 0 { break }
                out.append(chunk, count: n)
            }
            return String(decoding: out, as: UTF8.self)
        }.value
    }

    func testRoundTripOverTheRealSocketUpdatesTheLiveStore() async throws {
        let rig = try rig()
        let pong = await send(WireRequest(op: .ping), to: rig.path)
        XCTAssertEqual(try pong.get().message, "pong")
        let logged = try await send(WireRequest(op: .log, text: "通过 socket 写入", task: 1), to: rig.path).get()
        XCTAssertTrue(logged.ok, logged.error ?? "")
        XCTAssertEqual(rig.store.allLogs().last?.log.text, "通过 socket 写入", "写进了应用里正在用的 store（界面会立刻更新）")
        XCTAssertEqual(rig.store.allLogs().last?.log.taskNumber, 1)
        let todo = try await send(WireRequest(op: .todo, text: "后天 10:00 面试"), to: rig.path).get()
        XCTAssertEqual(todo.number, 3)
        let done = try await send(WireRequest(op: .done, task: 1), to: rig.path).get()
        XCTAssertTrue(done.ok)
        XCTAssertTrue(rig.store.locate(number: 1)!.task.completed)
        let snapshot = JournalStore(directory: rig.directory, readOnlySnapshot: true)
        XCTAssertTrue(snapshot.locate(number: 1)!.task.completed, "响应返回时数据已经落盘")
        // undo 栈是应用里同一个：命令行的写入也能在应用里撤销。
        rig.store.undo()
        XCTAssertFalse(rig.store.locate(number: 1)!.task.completed)
    }

    func testSocketFileIsOwnerOnlyAndIsRemovedOnStop() throws {
        let rig = try rig()
        var info = stat()
        XCTAssertEqual(stat(rig.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600, "只有当前用户能连")
        XCTAssertTrue(rig.server.isRunning)
        rig.server.stop()
        let deadline = Date().addingTimeInterval(2)
        while FileManager.default.fileExists(atPath: rig.path), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.path), "退出时清掉 socket 文件")
        XCTAssertFalse(rig.server.isRunning)
    }

    func testMalformedEmptyAndOversizedRequestsGetErrorsAndNeverCrashTheServer() async throws {
        let rig = try rig()
        for (name, bytes) in [("乱码", Data("not json\n".utf8)), ("缺字段", Data("{\"hello\":1}\n".utf8)), ("空行", Data("\n".utf8))] {
            let reply = await raw(bytes, to: rig.path)
            let response = try JSONDecoder().decode(WireResponse.self, from: Data(reply.utf8))
            XCTAssertFalse(response.ok, name)
        }
        let huge = Data(repeating: UInt8(ascii: "a"), count: SchedulerWire.maxRequestBytes + 10_000)
        let reply = await raw(huge, to: rig.path)
        XCTAssertTrue(reply.contains("请求太大"), reply)
        // 一个字节都不发就断开：服务不会卡住，之后的请求照常处理。
        _ = await raw(Data(), to: rig.path)
        let alive = try await send(WireRequest(op: .ping), to: rig.path).get()
        XCTAssertTrue(alive.ok, "异常请求之后服务仍然正常")
        XCTAssertEqual(rig.store.allLogs().count, 0, "异常请求没有写入任何数据")
    }

    /// 回归测试：客户端连上之后过一会儿才发请求（比如命令行先做别的事、网络慢），服务不能把它当成空请求。
    func testAClientThatConnectsFirstAndSendsLaterIsStillServed() async throws {
        let rig = try rig()
        let path = rig.path
        let reply = await Task.detached { () -> String in
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let chars = Array(path.utf8)
            withUnsafeMutablePointer(to: &address.sun_path) { p in
                p.withMemoryRebound(to: UInt8.self, capacity: chars.count + 1) { d in
                    for (i, b) in chars.enumerated() { d[i] = b }
                    d[chars.count] = 0
                }
            }
            let rc = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard rc == 0 else { return "CONNECT-FAILED" }
            Thread.sleep(forTimeInterval: 0.4)   // 先连上，晚点再发
            let payload = Array("{\"version\":1,\"op\":\"ping\"}\n".utf8)
            guard Darwin.send(fd, payload, payload.count, 0) == payload.count else { return "SEND-FAILED \(errno)" }
            var chunk = [UInt8](repeating: 0, count: 1024)
            let n = recv(fd, &chunk, chunk.count, 0)
            return n > 0 ? String(decoding: chunk[0..<n], as: UTF8.self) : "RECV-\(n)"
        }.value
        XCTAssertTrue(reply.contains("pong"), reply)
    }

    /// 回归测试：客户端发出请求后立刻断开（Ctrl-C），服务回写时不能因为 SIGPIPE 让整个进程退出。
    func testClientsThatHangUpImmediatelyNeverKillTheServer() async throws {
        let rig = try rig()
        let path = rig.path
        await Task.detached {
            for _ in 0..<30 {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                let chars = Array(path.utf8)
                withUnsafeMutablePointer(to: &address.sun_path) { p in
                    p.withMemoryRebound(to: UInt8.self, capacity: chars.count + 1) { d in
                        for (i, b) in chars.enumerated() { d[i] = b }
                        d[chars.count] = 0
                    }
                }
                _ = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
                let payload = Array("{\"version\":1,\"op\":\"ping\"}\n".utf8)
                _ = Darwin.send(fd, payload, payload.count, 0)
                close(fd)   // 不等响应
            }
        }.value
        try await Task.sleep(nanoseconds: 300_000_000)
        let alive = try await send(WireRequest(op: .ping), to: rig.path).get()
        XCTAssertTrue(alive.ok)
    }

    func testManyConcurrentClientsAreAllHandledWithoutLosingWrites() async throws {
        let rig = try rig()
        let path = rig.path
        // 60 个同时连接，远超监听积压：多出来的连接会被系统短暂拒绝，客户端必须重试而不是报「应用没在运行」。
        // 真实场景里每个 sched 是独立进程，所以这里每个客户端用独立线程（阻塞调用不能占用 Swift 并发的协作线程池）。
        let results: [Bool] = await withCheckedContinuation { continuation in
            let lock = NSLock()
            var collected: [Bool] = []
            let group = DispatchGroup()
            for index in 0..<60 {
                group.enter()
                Thread.detachNewThread {
                    let ok = (try? SchedulerClient(socketPath: path).send(WireRequest(op: .log, text: "并发 \(index)", task: 1)).get().ok) ?? false
                    lock.lock(); collected.append(ok); lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .global()) { continuation.resume(returning: collected) }
        }
        XCTAssertEqual(results.filter { $0 }.count, 60)
        let texts = rig.store.allLogs().map(\.log.text)
        XCTAssertEqual(Set(texts).count, 60, "60 条并发写入一条不丢")
    }

    func testStaleSocketFromACrashIsReplacedButALiveOneIsNeverStolen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stale-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = SchedulerWire.socketPath(directory: directory)
        // 上次崩溃遗留的普通文件（没人监听）。
        try Data("stale".utf8).write(to: URL(fileURLWithPath: path))
        let store = JournalStore(directory: directory)
        let first = SchedulerServer(path: path) { _ in .failure("a") }
        try first.start()
        addTeardownBlock { first.stop() }
        XCTAssertTrue(SchedulerServer.canConnect(path), "死 socket 被清理后重新监听")
        let second = SchedulerServer(path: path) { _ in .failure("b") }
        XCTAssertThrowsError(try second.start()) { XCTAssertEqual($0 as? SchedulerServer.StartError, .alreadyRunning) }
        XCTAssertTrue(SchedulerServer.canConnect(path), "第二个实例没有抢走活着的 socket")
        _ = store
    }

    func testLongDataDirectoryFallsBackToAShortSocketPathThatFitsTheLimit() throws {
        let long = URL(fileURLWithPath: "/tmp/" + String(repeating: "很长的目录名", count: 12), isDirectory: true)
        let path = SchedulerWire.socketPath(directory: long)
        XCTAssertLessThan(path.utf8.count, 104)
        XCTAssertTrue(path.hasPrefix("/tmp/scheduler-"))
        XCTAssertEqual(path, SchedulerWire.socketPath(directory: long), "同一目录总是同一路径，命令行和应用能对上")
        XCTAssertNotEqual(path, SchedulerWire.socketPath(directory: long.appendingPathComponent("另一个")))
        let short = URL(fileURLWithPath: "/tmp/data", isDirectory: true)
        XCTAssertEqual(SchedulerWire.socketPath(directory: short), "/tmp/data/scheduler.sock")
        let rig = try rig(path: path)
        XCTAssertTrue(rig.server.isRunning)
    }

    func testClientReportsNotRunningAndLaunchesTheAppAndWaitsForIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("launch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = SchedulerWire.socketPath(directory: directory)
        let notRunning = await send(WireRequest(op: .ping), to: path)
        XCTAssertEqual(notRunning, .failure(.notRunning))

        // 模拟「启动应用」：稍后才开始监听，客户端要等到它起来。
        let store = JournalStore(directory: directory)
        let service = SchedulerService(store: store, indexImages: {})
        let server = SchedulerServer(path: path) { [service] in service.handle($0) }
        addTeardownBlock { server.stop() }
        let launched = Task.detached { () -> (Int, Result<WireResponse, ClientError>) in
            let counter = LaunchCounter()
            var client = SchedulerClient(socketPath: path) { counter.hit(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { try? server.start() } } }
            client.launchWait = 6
            return (0, client.send(WireRequest(op: .ping)))
        }
        let (_, result) = await launched.value
        XCTAssertEqual(try result.get().message, "pong", "应用没开时先启动它，等 socket 就绪后再发请求")
    }
}

private final class LaunchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    func hit() { lock.lock(); count += 1; lock.unlock() }
}

/// 端到端：用真正的 `sched` 可执行文件，通过真实 socket 和应用里的服务交互。
@MainActor
final class SchedEndToEndTests: XCTestCase {
    private var schedURL: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("sched") }

    private func rig() throws -> (store: JournalStore, directory: URL, server: SchedulerServer) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        store.addTodo("读论文", on: Date())
        store.addTodo("写周报", on: Date())
        store.save()
        let service = SchedulerService(store: store, indexImages: {})
        let server = SchedulerServer(path: SchedulerWire.socketPath(directory: directory)) { [service] in service.handle($0) }
        try server.start()
        addTeardownBlock { server.stop() }
        return (store, directory, server)
    }

    private func sched(_ arguments: [String], directory: URL, stdin: String? = nil) async throws -> (code: Int32, out: String, err: String) {
        let executable = schedURL
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments + ["--no-launch"]
            var environment = ProcessInfo.processInfo.environment
            environment["DAYLEAF_DATA_DIR"] = directory.path
            environment["NO_COLOR"] = "1"
            process.environment = environment
            let out = Pipe(), err = Pipe(), input = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = input
            process.terminationHandler = { p in
                let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: (p.terminationStatus, o, e))
            }
            do {
                try process.run()
                if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
                try? input.fileHandleForWriting.close()
            } catch { continuation.resume(throwing: error) }
        }
    }

    func testWriteThenReadBackThroughTheRealBinary() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: schedURL.path), "sched 可执行文件不存在：\(schedURL.path)")
        let rig = try rig()
        var result = try await sched(["log", "-t", "1", "读到第三节，公式很绕"], directory: rig.directory)
        XCTAssertEqual(result.code, 0, result.err)
        XCTAssertTrue(result.out.contains("✓ 已记录 → #1 读论文"), result.out)
        result = try await sched(["logs", "--porcelain"], directory: rig.directory)
        XCTAssertTrue(result.out.contains("读到第三节，公式很绕"), "写完马上能读到：\(result.out)")

        result = try await sched(["log", "#2 周报写了一半"], directory: rig.directory)
        XCTAssertEqual(result.code, 0, result.err)
        XCTAssertEqual(rig.store.allLogs().last?.log.taskNumber, 2)

        result = try await sched(["log", "-"], directory: rig.directory, stdin: "来自标准输入\n第二行")
        XCTAssertEqual(result.code, 0, result.err)
        XCTAssertEqual(rig.store.allLogs().last?.log.text, "来自标准输入\n第二行")

        result = try await sched(["todo", "--priority", "high", "明天", "15:00", "开会"], directory: rig.directory)
        XCTAssertTrue(result.out.contains("已添加 #3 开会，截止 明天 15:00"), result.out)
        XCTAssertEqual(rig.store.locate(number: 3)?.task.priority, .high)
        result = try await sched(["priority", "3", "low"], directory: rig.directory)
        XCTAssertEqual(result.code, 0, result.err)
        XCTAssertEqual(rig.store.locate(number: 3)?.task.priority, .low)
        result = try await sched(["priority", "3", "invalid"], directory: rig.directory)
        XCTAssertEqual(result.code, 2)
        result = try await sched(["tasks", "--json"], directory: rig.directory)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { $0["number"] as? Int == 3 })
        XCTAssertEqual(row["priority"] as? String, "low")
        XCTAssertEqual(row["due_has_time"] as? Bool, true)
        result = try await sched(["done", "1"], directory: rig.directory)
        XCTAssertTrue(result.out.contains("已完成 #1"), result.out)
        XCTAssertTrue(rig.store.locate(number: 1)!.task.completed)
        result = try await sched(["tasks"], directory: rig.directory)
        XCTAssertTrue(result.out.contains("#3") && result.out.contains("开会"), result.out)
        result = try await sched(["undone", "1"], directory: rig.directory)
        XCTAssertFalse(rig.store.locate(number: 1)!.task.completed)

        result = try await sched(["status"], directory: rig.directory)
        XCTAssertTrue(result.out.contains("运行中"), result.out)
    }

    func testAttachingAnImageAndErrorsComeBackWithNonZeroExit() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: schedURL.path))
        let rig = try rig()
        let png = rig.directory.appendingPathComponent("shot.png")
        let image = NSImage(size: NSSize(width: 60, height: 30), flipped: false) { rect in NSColor.blue.setFill(); rect.fill(); return true }
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: png)
        var result = try await sched(["log", "-t", "1", "-i", "shot.png", "附一张图"], directory: rig.directory)
        // 子进程的当前目录不是临时目录，相对路径 shot.png 找不到文件 → 明确报错且不写入。
        XCTAssertEqual(result.code, 1)
        XCTAssertTrue(result.err.contains("找不到图片文件"), result.err)
        XCTAssertEqual(rig.store.allLogs().count, 0)
        result = try await sched(["log", "-t", "1", "-i", png.path, "附一张图"], directory: rig.directory)
        XCTAssertEqual(result.code, 0, result.err)
        XCTAssertEqual(rig.store.allLogs().last?.log.images.count, 1)
        let lastLog = try XCTUnwrap(rig.store.allLogs().last)
        result = try await sched(["show", String(rig.store.allLogs().last!.log.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(6))], directory: rig.directory)
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.out.contains(rig.store.allLogs().last!.log.images[0]), "show 打印图片路径（管道里不画图）")

        result = try await sched(["log", "-t", "99", "x"], directory: rig.directory)
        XCTAssertEqual(result.code, 1)
        XCTAssertTrue(result.err.contains("没有编号为 #99 的任务"), result.err)
        rig.server.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        result = try await sched(["log", "应用已退出"], directory: rig.directory)
        XCTAssertEqual(result.code, 1)
        XCTAssertTrue(result.err.contains("没有在运行"), result.err)
        result = try await sched(["logs", "-n", "1"], directory: rig.directory)
        XCTAssertEqual(result.code, 0, "应用不在运行时读取命令照常可用")
    }
}

/// 内置终端的环境：zsh 自带的 sched 内置命令不能盖住命令行工具。用真实的 zsh 进程验证，不开任何窗口。
@MainActor
final class ShellEnvironmentTests: XCTestCase {
    private func runZsh(_ script: String, environment: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-i", "-c", script]
        var env: [String: String] = [:]
        for pair in environment { if let eq = pair.firstIndex(of: "=") { env[String(pair[..<eq])] = String(pair[pair.index(after: eq)...]) } }
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    func testStartupDirectoryDisablesTheBuiltinAndKeepsYourOwnConfigLoading() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("zhome-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        try "export FROM_USER_ZSHENV=yes\n".write(to: home.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        try "export FROM_USER_ZSHRC=yes\nalias myalias='echo hi'\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\necho REAL-SCHED\n".write(to: bin.appendingPathComponent("sched"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("sched").path)

        var environment = ShellWindowController.shellEnvironment(base: [:])
        environment = environment.filter { !$0.hasPrefix("PATH=") && !$0.hasPrefix("HOME=") }
        environment += ["HOME=\(home.path)", "PATH=\(bin.path):/usr/bin:/bin"]
        XCTAssertTrue(environment.contains { $0.hasPrefix("ZDOTDIR=") }, "终端用应用提供的启动目录")

        // 没有启动目录时：zsh 的内置命令盖住了 sched（这就是要解决的问题）。
        let plain = try runZsh("whence -w sched", environment: ["HOME=\(home.path)", "PATH=\(bin.path):/usr/bin:/bin"])
        XCTAssertTrue(plain.contains("builtin"), plain)
        // 有启动目录时：sched 指向真正的命令行工具，且你自己的 .zshenv / .zshrc 照常加载。
        let fixed = try runZsh("whence -w sched; sched; echo $FROM_USER_ZSHENV $FROM_USER_ZSHRC; myalias; echo \"ZDOTDIR=[$ZDOTDIR]\"", environment: environment)
        XCTAssertTrue(fixed.contains("sched: command"), fixed)
        XCTAssertTrue(fixed.contains("REAL-SCHED"), fixed)
        XCTAssertTrue(fixed.contains("yes yes"), "你的 .zshenv 和 .zshrc 都照常加载：\(fixed)")
        XCTAssertTrue(fixed.contains("hi"), "你的别名可用")
        XCTAssertTrue(fixed.contains("ZDOTDIR=[]"), "ZDOTDIR 已还原，不影响你在终端里再启动别的 zsh：\(fixed)")
    }

    func testAUserSuppliedZdotdirIsHonoured() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("zhome2-" + UUID().uuidString)
        let custom = home.appendingPathComponent("zconf")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        try "export CUSTOM_RC=loaded\n".write(to: custom.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        var environment = ShellWindowController.shellEnvironment(base: ["ZDOTDIR": custom.path])
        environment = environment.filter { !$0.hasPrefix("PATH=") && !$0.hasPrefix("HOME=") }
        environment += ["HOME=\(home.path)", "PATH=/usr/bin:/bin"]
        XCTAssertTrue(environment.contains("SCHED_REAL_ZDOTDIR=\(custom.path)"))
        let out = try runZsh("echo \"$CUSTOM_RC [$ZDOTDIR]\"", environment: environment)
        XCTAssertTrue(out.contains("loaded"), "原来的 ZDOTDIR 里的配置照常加载：\(out)")
        XCTAssertTrue(out.contains("[\(custom.path)]"), "ZDOTDIR 还原成用户原来的值：\(out)")
    }

    func testStartupDirectoryIsPrivateRewrittenWhenStaleAndFailsSoft() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("zbase-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let path = try XCTUnwrap(ShellWindowController.startupDirectory(base: base))
        let file = URL(fileURLWithPath: path).appendingPathComponent(".zshenv")
        XCTAssertEqual(try String(contentsOf: file), ShellWindowController.startupZshenv)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int) ?? 0, 0o700, "启动目录只有当前用户可访问")
        try "tampered".write(to: file, atomically: true, encoding: .utf8)
        _ = ShellWindowController.startupDirectory(base: base)
        XCTAssertEqual(try String(contentsOf: file), ShellWindowController.startupZshenv, "内容被改过会被还原")
        XCTAssertNil(ShellWindowController.startupDirectory(base: URL(fileURLWithPath: "/dev/null/不可写")), "写不出来时不报错，终端照常启动")
    }
}
