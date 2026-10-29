import Combine
import CryptoKit
import Foundation

/// 一台设备在共享文件夹里留下的完整状态。每台设备只写自己的这一份，所以文件本身不会冲突。
struct SyncSnapshot: Codable {
    static let currentFormat = 1
    var format = currentFormat
    var device: String
    var name: String
    var exportedAt: Date
    var records: [String: SyncRecord]
}

/// 本机的同步状态，存在数据目录的 `Sync/state.json`：上次同步后的全部记录（用来认出本机改了什么）
/// 和已经合并过的其他设备文件（没变的就不再读）。
struct SyncState: Codable, Equatable {
    var device: String
    var records: [String: SyncRecord] = [:]
    var remote: [String: RemoteMark] = [:]
    var names: [String: String] = [:]
    var ledger: IncrementalState?

    struct RemoteMark: Codable, Equatable {
        var modified: Date
        var size: Int
        var digest: String?
        var exportedAt: Date?
    }
}

/// 通过一个普通的共享文件夹（通常是 iCloud Drive 里的「Timeline」）和其他设备同步，不需要 iCloud 权限。
///
/// - `streams/<设备>/`：不可变字段增量及定期完整检查点（包含删除标记）。
/// - `receipts/`：接收序号回执；`devices/`、`updates/` 只用于旧格式迁移。
/// - `images/`：按内容摘要去重的原图，写入后不再修改，查看时下载。
///
/// 读写文件夹（可能要等 iCloud 下载）都在后台进行；只有合并结果写回 `JournalStore` 时回到主线程。
/// 后台合并期间本机又有修改的话，这次结果作废，下一轮重来，不会把本机刚做的修改当成旧数据覆盖掉。
@MainActor
public final class FolderSync: ObservableObject {
    public struct Device: Equatable, Identifiable {
        public var id: String
        public var name: String
        public var exportedAt: Date
        public var hasReceivedLocalChanges: Bool? = nil
    }

    public enum SyncError: LocalizedError {
        case readOnly
        case folderUnavailable(String)
        case newerFormat(String)
        case timeout

        public var errorDescription: String? {
            switch self {
            case .timeout: return "同步尚未完成，请检查网络和 iCloud 云盘状态后重试。"
            case .readOnly: return "当前数据只读，已暂停同步。"
            case .folderUnavailable(let path): return "无法访问同步文件夹：\(path)"
            case .newerFormat(let name): return "「\(name)」上的 Timeline 版本更新，请先更新本机的应用。"
            }
        }
    }

    public let store: JournalStore
    public let folder: URL
    public let deviceName: String
    /// 网页编辑器先取回尚未通过防抖写入的正文，再捕获同步快照；同步和进后台都必须等待。
    public var prepareForSync: (() async -> Void)?
    @Published public private(set) var isSyncing = false
    @Published public private(set) var lastSync: Date?
    @Published public private(set) var lastCheck: Date?
    @Published public private(set) var lastExport: Date?
    @Published public private(set) var lastUpload: Date?
    @Published public private(set) var uploadWaitingSince: Date?
    @Published public private(set) var lastErrorCode: String?
    @Published public private(set) var lastReadBytes = 0
    @Published public private(set) var lastWrittenBytes = 0
    @Published public private(set) var pendingUploadBytes = 0
    @Published public private(set) var pendingUploadFiles = 0

    /// 界面先显示持续状态，后台检查不让「等待上传」反复切成「正在同步」。
    public var statusTitle: String {
        if lastError != nil { return "同步未完成" }
        if waitingForUpload { return "等待 iCloud 上传" }
        if waitingForDownload { return "等待 iCloud 下载" }
        if isSyncing { return "正在检查同步" }
        return lastSync == nil ? "尚未完成同步检查" : "本轮同步检查已完成"
    }
    @Published public private(set) var lastError: String?
    /// 连续失败的轮数：偶尔一次失败（文件正被 iCloud 占用之类）下一轮通常就好了，界面只在连续失败时提醒。
    @Published public private(set) var failureStreak = 0
    /// 值得在设置页以外提醒用户的同步问题：连续失败两轮以上。
    public var persistentError: String? { failureStreak >= 2 ? lastError : nil }
    @Published public private(set) var devices: [Device] = []
    /// 其他设备的文件在 iCloud 上有更新、本机还没下载到：已经请系统下载，几秒后再看。
    @Published public private(set) var waitingForDownload = false
    /// 本机更新已写入，但 iCloud 还未确认上传完成。
    @Published public private(set) var waitingForUpload = false
    /// 测试里可以替换「现在」。
    var now: () -> Date = Date.init
    var uploadPending: @Sendable (URL) throws -> Bool = { try FolderSync.isUploadPending($0) }

    private var state: SyncState
    private var syncedContent: SyncContent?
    private var rerun = false
    /// 本机状态变了还没成功导出：导出失败时下一轮接着导。
    private var needsExport = true
    private var exportedRevision: URL?
    /// 连续等下载的轮数：iCloud 一直没下载下来时别无限地每几秒查一次。
    private var downloadWaits = 0
    private var automatic: AnyCancellable?
    private var timer: Timer?
    private var retryTask: Task<Void, Never>?
    private var imageRequests: Set<String> = []
    private var queuedImageRequests: Set<String> = []
    private var deferredImageRequests: Set<String> = []

    public var deviceID: String { state.device }
    var stateURL: URL { Self.stateURL(in: store.directory) }
    nonisolated static func stateURL(in directory: URL) -> URL { directory.appendingPathComponent("Sync/state.json") }
    public nonisolated static let devicesFolder = "devices"
    public nonisolated static let imagesFolder = "images"
    public nonisolated static let updatesFolder = "updates"

    public init(store: JournalStore, folder: URL, deviceName: String) {
        self.store = store
        self.folder = folder
        self.deviceName = deviceName
        let url = Self.stateURL(in: store.directory)
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(SyncState.self, from: data) {
            state = saved
        } else {
            state = SyncState(device: Self.makeDeviceID())
        }
        let transportURL = url.deletingLastPathComponent().appendingPathComponent("transport.json")
        if let data = try? Data(contentsOf: transportURL), let ledger = try? JSONDecoder().decode(IncrementalState.self, from: data),
           ledger.revision >= (state.ledger?.revision ?? -1) { state.ledger = ledger }
        let statusURL = url.deletingLastPathComponent().appendingPathComponent("status.json")
        if let data = try? Data(contentsOf: statusURL), let report = try? JSONDecoder().decode([String: String].self, from: data) {
            let formatter = ISO8601DateFormatter()
            lastCheck = report["lastCheck"].flatMap { formatter.date(from: $0) }
            lastExport = report["lastExport"].flatMap { formatter.date(from: $0) }
            lastUpload = report["lastUpload"].flatMap { formatter.date(from: $0) }
        }
        store.requestImage = { [weak self] name in
            self?.enqueueImage(name)
        }
        store.fetchImage = { [weak self] name in
            guard let self else { return false }
            return try await self.downloadImage(name)
        }
    }

    deinit { timer?.invalidate(); retryTask?.cancel() }

    private func enqueueImage(_ name: String) {
        guard !imageRequests.contains(name) else { return }
        queuedImageRequests.insert(name)
        drainImageRequests()
    }

    private func drainImageRequests() {
        // 大量配图同时出现时，限制整张原图的并行读取和解码前的内存占用。
        while imageRequests.count < 3, let name = queuedImageRequests.first {
            queuedImageRequests.remove(name)
            imageRequests.insert(name)
            Task { [weak self] in await self?.fetchVisibleImage(name) }
        }
    }

    private func fetchVisibleImage(_ name: String) async {
        defer { imageRequests.remove(name); drainImageRequests() }
        for _ in 0..<20 {
            if (try? await downloadImage(name)) == true { deferredImageRequests.remove(name); return }
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        // iCloud 下载超过一分钟时，后续同步轮询继续重试，不把占位图永久留住。
        deferredImageRequests.insert(name)
    }

    /// 可见缩略图或原图打开时才下载；下载和校验不占用主线程。
    @discardableResult
    public func downloadImage(_ name: String) async throws -> Bool {
        guard !name.contains("/"), !name.hasPrefix("."), !name.isEmpty else { throw CocoaError(.fileReadInvalidFileName) }
        let local = store.imagesDirectory.appendingPathComponent(name), folder = self.folder
        if FileManager.default.fileExists(atPath: local.path) { return true }
        let downloaded = try await Task.detached(priority: .utility) {
            try Self.accessing(folder) {
                var remote = folder.appendingPathComponent(Self.imagesFolder).appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: remote.path) {
                    let recovered = folder.appendingPathComponent(SyncImageMaintenance.quarantine).appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: recovered.path) { remote = recovered }
                }
                guard try IncrementalSync.available(remote), let data = try Self.coordinatedRead(remote) else { return false }
                let stem = remote.deletingPathExtension().lastPathComponent
                if stem.count == 64 && stem.allSatisfy({ $0.isHexDigit }), IncrementalSync.digest(data) != stem { throw CocoaError(.fileReadCorruptFile) }
                try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: local, options: .atomic)
                return true
            }
        }.value
        if downloaded { NotificationCenter.default.post(name: JournalStore.imageAvailable, object: local) }
        return downloaded
    }

    nonisolated static func makeDeviceID() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<8).map { _ in letters.randomElement()! })
    }

    /// 本机数据一改（停 `delay` 秒没有新修改）就同步，另外每隔 `interval` 秒看一次其他设备有没有新内容。
    public func startAutomaticSync(delay: TimeInterval = 2, interval: TimeInterval = 30) {
        automatic = store.objectWillChange
            .debounce(for: .seconds(delay), scheduler: RunLoop.main)
            .sink { [weak self] in self?.syncSoon() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSoon() }
        }
        syncSoon()
    }

    public func stopAutomaticSync() {
        automatic = nil
        retryTask?.cancel()
        retryTask = nil
        timer?.invalidate()
        timer = nil
    }

    /// 发起一次同步，不等结果；正在同步时，结束后再补一轮。
    public func syncSoon(after delay: TimeInterval = 0) {
        Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            _ = try? await sync()
        }
    }

    /// 手动等待与自动检查共用一个重试任务，避免每轮都排一个新的检查、导致按钮和 I/O 高频刷新。
    private func retry(after delay: TimeInterval) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            _ = try? await self?.sync()
        }
    }

    /// 同步一轮：合并远端增量、发布本机变更及新原图。返回本机数据有没有被改动。
    @discardableResult
    public func sync() async throws -> Bool {
        guard !isSyncing else { rerun = true; return false }
        retryTask?.cancel()
        retryTask = nil
        isSyncing = true
        defer {
            isSyncing = false
            if rerun { rerun = false; retry(after: 2) }
            else if waitingForDownload || waitingForUpload, downloadWaits < 40 { downloadWaits += 1; retry(after: 3) }
        }
        do {
            await recordProgress("preparing")
            await prepareForSync?()
            let changed = try await runOnce()
            for name in deferredImageRequests { enqueueImage(name) }
            lastCheck = now()
            if !rerun && !waitingForDownload && !waitingForUpload { lastSync = now() }
            if !waitingForUpload && !waitingForDownload {
                lastError = nil
                lastErrorCode = nil
                if failureStreak != 0 { failureStreak = 0 }
            }
            await recordProgress(waitingForUpload ? "waitingForUpload" : (waitingForDownload ? "waitingForDownload" : "finished"))
            return changed
        } catch {
            let underlying = error as NSError
            lastErrorCode = "\(underlying.domain) (\(underlying.code))"
            await recordProgress("failed", error: error.localizedDescription)
            lastError = error.localizedDescription
            failureStreak += 1
            throw error
        }
    }

    /// 进后台前用：`sync()` 遇上正在进行的一轮会直接返回、等之后补一轮，可应用挂起后那一轮就不会来了。
    /// 等到最新内容导出、iCloud 确认上传且远端下载完成；超时要明确提示，不能显示同步完成。
    public func syncUntilExported(timeout: TimeInterval = 20) async {
        let deadline = Date().addingTimeInterval(timeout)
        var attempt: Task<Void, Never>?
        var finished = false
        var failed = false
        var nextAttempt = Date.distantPast
        defer { attempt?.cancel() }
        while Date() < deadline {
            if finished {
                attempt = nil
                finished = false
                if failed { return }
                nextAttempt = Date().addingTimeInterval(1)
                if !isSyncing, !needsExport, syncedContent == store.syncContent, !waitingForUpload, !waitingForDownload { return }
            }
            if !isSyncing, attempt == nil, Date() >= nextAttempt {
                // 不直接 await：文件协调可能被系统挂起。调用者仍需在期限内恢复按钮、结束后台任务。
                attempt = Task {
                    do { _ = try await sync() } catch { failed = true }
                    finished = true
                }
            }
            if Task.isCancelled { return }
            let pause = min(0.1, max(0, deadline.timeIntervalSinceNow))
            try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
        }
        lastErrorCode = "Timeline.SyncTimeout"
        lastError = SyncError.timeout.localizedDescription
        await recordProgress("timedOut", error: lastError)
    }

    /// 保存阶段和错误，应用重启后也能诊断是哪一步没有完成；不记录正文或授权书签。
    private func recordProgress(_ stage: String, error: String? = nil) async {
        let url = stateURL.deletingLastPathComponent().appendingPathComponent("status.json")
        let formatter = ISO8601DateFormatter()
        var report = ["stage": stage, "time": formatter.string(from: Date()), "error": error ?? lastError ?? "", "device": state.device]
        report["lastCheck"] = lastCheck.map(formatter.string)
        report["lastExport"] = lastExport.map(formatter.string)
        report["lastUpload"] = lastUpload.map(formatter.string)
        report["errorCode"] = lastErrorCode
        report["revision"] = exportedRevision?.lastPathComponent
        await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(report) { try? data.write(to: url, options: .atomic) }
        }.value
    }

    private struct Outcome: @unchecked Sendable {
        var state: SyncState
        var content: SyncContent
        var stateChanged: Bool
        var devices: [Device]
        var firstMerge: Bool
        var pendingDownload = false
        var readBytes = 0
    }

    private func runOnce() async throws -> Bool {
        guard !store.isReadOnly else { throw SyncError.readOnly }
        let content = store.syncContent
        let previous = state
        let localChanged = content != syncedContent
        let folder = self.folder, deviceName = self.deviceName, time = now()
        await recordProgress("readingRemote")
        let outcome = try await Task.detached(priority: .utility) {
            try Self.merge(content: content, state: previous, localChanged: localChanged, folder: folder, deviceName: deviceName, now: time)
        }.value
        // 合并期间本机又改了：作废这次结果，稍后重来。
        guard store.syncContent == content else { rerun = true; return false }
        if outcome.firstMerge {
            try? FileManager.default.createDirectory(at: store.backupsDirectory, withIntermediateDirectories: true)
            try? store.export(to: store.backupsDirectory.appendingPathComponent("before-first-sync-\(JournalDates.key(time)).json"))
        }
        let applied = outcome.content != content
        if applied { store.applySyncContent(outcome.content) }
        if waitingForDownload != outcome.pendingDownload { waitingForDownload = outcome.pendingDownload }
        if !outcome.pendingDownload && !waitingForUpload { downloadWaits = 0 }
        if applied { store.save() }
        if outcome.stateChanged { needsExport = true }
        let images = store.imagesDirectory, stateURL = self.stateURL
        var snapshotState = outcome.state
        if time.timeIntervalSince(snapshotState.ledger?.lastImageInventory ?? .distantPast) >= 86400 {
            let inventory = await store.retainedImagesForSync()
            if let inventory { snapshotState.ledger?.protectedImages = inventory }
            snapshotState.ledger?.imageInventoryComplete = inventory != nil
            snapshotState.ledger?.lastImageInventory = time
        }
        let names = (localChanged || applied || previous.ledger == nil) ? outcome.content.imageNames : []
        snapshotState.ledger?.protectedImages?.formUnion(names)
        let queuedImages = (snapshotState.ledger?.queuedImages ?? []).union(names)
        snapshotState.ledger?.queuedImages = queuedImages
        if snapshotState.ledger != outcome.state.ledger { snapshotState.ledger?.revision += 1 }
        let uploadPending = self.uploadPending
        let recordsChanged = previous.records != snapshotState.records || previous.ledger == nil
        await recordProgress("exporting")
        // 先落盘再推进内存基线。写盘失败后下轮仍能认出同一批本机修改；
        // 云端发布失败则保留已落盘的序号、批次和图片队列供重试。
        let durableState = snapshotState
        try await Task.detached(priority: .utility) {
            if recordsChanged { try Self.write(state: durableState, to: stateURL) }
            if let ledger = durableState.ledger, ledger != previous.ledger { try Self.writeTransport(ledger, to: stateURL) }
        }.value
        state = durableState
        syncedContent = outcome.content
        devices = outcome.devices.map { device in
            var device = device
            if let ledger = durableState.ledger, let peer = ledger.peers[device.id] {
                device.hasReceivedLocalChanges = (peer.seen[durableState.device] ?? 0) >= ledger.sequence && ledger.sequence > 0
            }
            return device
        }
        let transfer = try await Task.detached(priority: .utility) {
            let persisted = snapshotState
            return try Self.accessing(folder) { () throws -> (Int, Int, URL, IncrementalState, Int, Int) in
                var ledger = persisted.ledger ?? IncrementalState()
                let imageBytes = try Self.syncImages(ledger.queuedImages ?? [], local: images, folder: folder, ledger: &ledger)
                let leaseBytes = try SyncImageMaintenance.publish(protected: ledger.protectedImages ?? names, folder: folder, device: persisted.device, now: time, state: &ledger)
                let publication = try IncrementalSync.publish(folder: folder, device: persisted.device, name: deviceName, now: time, state: &ledger)
                try IncrementalSync.compact(folder: folder, device: persisted.device, uploadPending: uploadPending)
                for relative in ledger.pendingCloud {
                    let url = folder.appendingPathComponent(relative)
                    if FileManager.default.fileExists(atPath: url.path), try uploadPending(url) { continue }
                    ledger.pendingCloud.remove(relative)
                }
                try SyncImageMaintenance.collect(folder: folder, device: persisted.device, now: time, state: &ledger, uploadPending: uploadPending)
                let pendingCount = ledger.pendingCloud.count
                let pendingBytes = ledger.pendingCloud.reduce(0) { total, relative in
                    total + ((try? folder.appendingPathComponent(relative).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
                if ledger != persisted.ledger { ledger.revision += 1 }
                if ledger != persisted.ledger { try Self.writeTransport(ledger, to: stateURL) }
                return (pendingCount, pendingBytes, publication.url, ledger, publication.bytes + imageBytes + leaseBytes, publication.batches)
            }
        }.value
        let revisionChanged = exportedRevision != transfer.2
        exportedRevision = transfer.2
        state.ledger = transfer.3
        needsExport = !transfer.3.pending.isEmpty
        lastReadBytes = outcome.readBytes
        lastWrittenBytes = transfer.4
        pendingUploadFiles = transfer.0
        pendingUploadBytes = transfer.1
        if transfer.5 > 0 { lastExport = now() }
        if transfer.0 > 0 {
            if uploadWaitingSince == nil || revisionChanged { uploadWaitingSince = now() }
        } else {
            uploadWaitingSince = nil
            if revisionChanged || waitingForUpload || lastUpload == nil { lastUpload = now() }
        }
        if waitingForUpload != (transfer.0 > 0) { waitingForUpload = transfer.0 > 0 }
        if store.syncContent != syncedContent { rerun = true }
        return applied
    }

    // MARK: - 后台部分

    nonisolated private static func merge(content: SyncContent, state previous: SyncState, localChanged: Bool,
                                          folder: URL, deviceName: String, now: Date) throws -> Outcome {
        var state = previous
        var merge = SyncMerge(device: state.device, now: now)
        if localChanged || state.records.isEmpty { merge.stampLocalChanges(try content.records(), into: &state.records) }
        let hadRemote = !previous.remote.isEmpty || (previous.ledger?.received.keys.contains { $0 != state.device } ?? false)
        var devices: [Device] = []
        var mergedRemote = false
        var pendingDownload = false
        var ledger = state.ledger ?? IncrementalState()
        var readBytes = 0
        try accessing(folder) {
            let incoming = try IncrementalSync.read(folder: folder, device: state.device, state: &ledger, merge: &merge, records: &state.records)
            readBytes = incoming.bytes
            mergedRemote = incoming.changed
            pendingDownload = incoming.waiting
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(devicesFolder), withIntermediateDirectories: true)
            let (files, placeholders) = try remoteFiles(in: folder, excluding: state.device, ignoring: ledger.migrated)
            pendingDownload = pendingDownload || placeholders
            let present = Set(files.map { $0.deletingPathExtension().lastPathComponent })
            // 云端占位文件尚未下载时保留原缓存；其余已被清理的旧版本不再占本地状态。
            if !placeholders { state.remote = state.remote.filter { present.contains($0.key) } }
            for file in files {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                let id = file.deletingPathExtension().lastPathComponent
                let ownerID = file.deletingLastPathComponent().lastPathComponent == updatesFolder ? String(id.split(separator: "-", maxSplits: 1).first ?? Substring(id)) : id
                if ledger.migrated.contains(ownerID) { continue }
                // iCloud 云盘不会主动把别的设备更新过的文件拉到本机（iOS 上尤其如此）：本机这份不是最新的，
                // 就请系统下载，这一轮先用手上的，下载完修改时间变了再合并。
                if values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus, status != .current {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: file)
                    pendingDownload = true
                }
                // iCloud 替换文件时可能保留修改时间和字节数。必须按实际内容判断，
                // 否则等长的 Board 编辑会一直被当成“已经同步过”。读取、摘要均在后台。
                guard let data = try coordinatedRead(file) else { continue }
                readBytes += data.count
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                var mark = SyncState.RemoteMark(modified: values?.contentModificationDate ?? .distantPast, size: data.count, digest: digest)
                if state.remote[id]?.digest == digest, let name = state.names[id], let exportedAt = state.remote[id]?.exportedAt {
                    devices.append(Device(id: ownerID, name: name, exportedAt: exportedAt))
                    continue
                }
                let snapshot = try JSONDecoder().decode(SyncSnapshot.self, from: data)
                if snapshot.format == 2 && snapshot.records.isEmpty { pendingDownload = true; continue }
                guard snapshot.format <= SyncSnapshot.currentFormat else { throw SyncError.newerFormat(snapshot.name) }
                mark.exportedAt = snapshot.exportedAt
                state.names[snapshot.device] = snapshot.name
                state.names[id] = snapshot.name
                merge.describeDevice = { [names = state.names] in names[$0] ?? $0 }
                merge.merge(snapshot.records, into: &state.records)
                state.remote[id] = mark
                mergedRemote = true
                devices.append(Device(id: snapshot.device, name: snapshot.name, exportedAt: snapshot.exportedAt))
            }
        }
        for peer in ledger.peers.values {
            state.names[peer.device] = peer.name
            devices.append(Device(id: peer.device, name: peer.name, exportedAt: peer.date,
                                  hasReceivedLocalChanges: (peer.seen[state.device] ?? 0) >= ledger.sequence && ledger.sequence > 0))
        }
        let shouldApply = localChanged || mergedRemote || state.records != previous.records
        var merged = shouldApply ? content.applying(state.records) : content
        if shouldApply {
            merge.stampLocalChanges(try merged.records(), into: &state.records)
            merged.nextTaskNumber = max(merged.nextTaskNumber, content.nextTaskNumber)
        }
        if shouldApply || ledger.sequence == 0 {
            try IncrementalSync.prepare(state: &ledger, previous: previous.records, records: state.records,
                                        device: state.device, name: deviceName, now: now)
        }
        if ledger != previous.ledger { ledger.revision += 1 }
        state.ledger = ledger
        return Outcome(state: state, content: merged, stateChanged: state.records != previous.records,
                       devices: uniqueDevices(devices), firstMerge: mergedRemote && !hadRemote && !content.days.isEmpty && merged != content,
                       pendingDownload: pendingDownload, readBytes: readBytes)
    }

    nonisolated private static func writeTransport(_ ledger: IncrementalState, to stateURL: URL) throws {
        let url = stateURL.deletingLastPathComponent().appendingPathComponent("transport.json")
        let data = try IncrementalSync.encode(ledger)
        if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
    }

    nonisolated private static func uniqueDevices(_ devices: [Device]) -> [Device] {
        Dictionary(grouping: devices, by: \.id).values.compactMap { $0.max { $0.exportedAt < $1.exportedAt } }.sorted { $0.name < $1.name }
    }

    nonisolated static func isUploadPending(_ url: URL) throws -> Bool {
        // URL 会缓存资源属性；每轮重新取 URL，避免一直读到写入当刻的上传状态。
        let fresh = URL(fileURLWithPath: url.path)
        let values = try fresh.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey])
        if let error = values.ubiquitousItemUploadingError { throw error }
        return values.isUbiquitousItem == true && values.ubiquitousItemIsUploaded != true
    }

    nonisolated static func snapshotURL(_ folder: URL, _ device: String) -> URL {
        folder.appendingPathComponent(devicesFolder).appendingPathComponent(device + ".json")
    }

    /// 其他设备的快照文件。iCloud 还没下载的文件在旧系统上显示为 `.名字.icloud`：先触发下载，这一轮跳过（第二个返回值为 true）。
    nonisolated private static func remoteFiles(in folder: URL, excluding device: String, ignoring migrated: Set<String> = []) throws -> ([URL], Bool) {
        var files: [URL] = []
        var placeholders = false
        for subfolder in [devicesFolder, updatesFolder] {
            let directory = folder.appendingPathComponent(subfolder)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                let real = placeholderTarget(name) ?? name
                let owner = subfolder == updatesFolder ? String(real.split(separator: "-", maxSplits: 1).first ?? "") : String(real.dropLast(5))
                if migrated.contains(owner) { continue }
                guard real.hasSuffix(".json"), !real.hasPrefix("."),
                      real != device + ".json", !real.hasPrefix(device + "-") else { continue }
                let url = directory.appendingPathComponent(real)
                if placeholderTarget(name) != nil {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                    placeholders = true
                } else { files.append(url) }
            }
        }
        return (files.sorted { $0.path < $1.path }, placeholders)
    }

    nonisolated private static func placeholderTarget(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    nonisolated private static func write(state: SyncState, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    /// 原图仅上传一次；未查看的远端原图保持在云端。
    nonisolated private static func syncImages(_ names: Set<String>, local: URL, folder: URL, ledger: inout IncrementalState) throws -> Int {
        let manager = FileManager.default
        var written = 0
        let remote = folder.appendingPathComponent(imagesFolder)
        try manager.createDirectory(at: remote, withIntermediateDirectories: true)
        for name in names.subtracting(ledger.uploadedImages).sorted() where !name.contains("/") && !name.hasPrefix(".") {
            let mine = local.appendingPathComponent(name), theirs = remote.appendingPathComponent(name)
            if manager.fileExists(atPath: mine.path) {
                if !manager.fileExists(atPath: theirs.path) {
                    let data = try Data(contentsOf: mine)
                    try coordinatedWrite(data, to: theirs)
                    written += data.count
                }
                ledger.pendingCloud.insert(imagesFolder + "/" + name)
                ledger.uploadedImages.insert(name)
            } else if manager.fileExists(atPath: theirs.path) {
                ledger.uploadedImages.insert(name)
            }
        }
        // 尚未下载到本地的远端图片不需要本机上传；本机的待发图片在失败时
        // 仍保留于持久化队列，只有整轮传输成功才会提交这个清空操作。
        ledger.queuedImages = []
        return written
    }

    // MARK: - 文件协调

    /// iOS 上通过文件选择器授权的文件夹要先声明访问；macOS 上普通路径调用也无妨。
    @discardableResult
    nonisolated static func accessing<Value>(_ folder: URL, _ body: () throws -> Value) throws -> Value {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) || (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
        else { throw SyncError.folderUnavailable(folder.path) }
        return try body()
    }

    /// 协调读取：文件还在云端时，系统会先下载再交给我们。
    nonisolated static func coordinatedRead(_ url: URL) throws -> Data? {
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { actual in
            result = Result { try Data(contentsOf: actual) }
        }
        if let coordinationError { throw coordinationError }
        return try result?.get()
    }

    nonisolated static func coordinatedWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { actual in
            do { try data.write(to: actual, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }
}
