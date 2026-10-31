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

/// 本机的同步状态，与正文一起存在 SQLite：上次同步后的全部记录（用来认出本机改了什么）
/// 和已经合并过的其他设备文件（没变的就不再读）。旧 state.json 仅作为迁移源。
struct SyncState: Codable, Equatable {
    var device: String
    var commitID: String?
    var folderPath: String?
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
        public var isRetired = false
        public var supportsRetirement = false
    }

    public enum SyncError: LocalizedError {
        case readOnly
        case folderUnavailable(String)
        case newerFormat(String)
        case timeout
        case upgradeRequired
        case retirementUnavailable
        case retirementBlocked

        public var errorDescription: String? {
            switch self {
            case .upgradeRequired: return "这台设备需要先升级 Timeline 并完成同步，才能安全停用。旧版设备仍可正常同步。"
            case .retirementUnavailable: return "正在同步或找不到这台设备，请稍后再试。"
            case .retirementBlocked: return "还有其他内容没有同步完，暂时不能停用这台设备。请等同步完成后再试。"
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
    /// 编辑器可能被系统挂起、永远不回话：等这么久就用已经写回的内容同步，没取到的修改下一轮再带上。
    var prepareDeadline: TimeInterval = 5
    /// 正在停用这台数据已损坏的设备：这一轮不再因为它报错或等待。
    private var retiringDevice: String?
    @Published public private(set) var isSyncing = false
    @Published public private(set) var phase: SyncPhase = .idle
    @Published public private(set) var hasLocalChanges = false
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
    @Published public private(set) var fileErrors: [String: String] = [:]
    @Published public private(set) var stageDurations: [String: Double] = [:]
    @Published public private(set) var blockingFiles: [String] = []
    @Published public private(set) var localSavedAt: Date?
    /// 本机和同步文件夹里都找不到的原图：不算同步失败，也不挡住「已同步」；每轮重试，找回后自动补传。
    @Published public private(set) var missingImages: Set<String> = []
    private var stageStarted = ProcessInfo.processInfo.systemUptime
    private var timedPhase: SyncPhase = .idle

    /// 界面先显示持续状态，后台检查不让「等待上传」反复切成「正在同步」。
    public var statusTitle: String {
        if lastError != nil || !fileErrors.isEmpty { return "同步未完成" }
        if waitingForUpload { return "等待 iCloud 上传" }
        if waitingForDownload { return "等待 iCloud 下载" }
        if isSyncing { return "正在检查同步" }
        return lastSync == nil ? "尚未完成同步检查" : "本轮同步检查已完成"
    }
    @Published public private(set) var lastError: String?
    /// 连续失败的轮数。
    @Published public private(set) var failureStreak = 0
    /// 值得在设置页以外提醒用户的同步问题：从第一次失败起过了 `persistentErrorDelay` 还没成功过。
    /// 不按轮数算：打字时每次停顿都同步一轮，文件被 iCloud 占用这类小问题几秒内就能连败好几轮，其实很快就好了。
    public var persistentError: String? { failurePersisted ? lastError : nil }
    var persistentErrorDelay: TimeInterval = 30
    private var failingSince: TimeInterval?
    @Published private var failurePersisted = false
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
    private var contentObservation: AnyCancellable?
    private var observedContent: SyncContent?
    private var contentCheckScheduled = false
    private var applyingRemoteContent = false
    private var folderAccess: SyncFolderAccess?
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
        observedContent = store.syncContent
        let url = Self.stateURL(in: store.directory)
        state = (try? store.persistedSyncState()) ?? SyncState(device: Self.makeDeviceID())
        let folderPath = folder.standardizedFileURL.resolvingSymlinksInPath().path
        if let previousFolder = state.folderPath, previousFolder != folderPath {
            state = SyncState(device: Self.makeDeviceID(), records: state.records)
        }
        state.folderPath = folderPath
        hasLocalChanges = state.ledger?.pending.isEmpty == false || state.ledger?.pendingCloud.contains(where: { $0.hasPrefix("streams/" + state.device + "/") }) == true
        fileErrors = (state.ledger?.streamErrors ?? [:]).merging(state.ledger?.attachmentErrors ?? [:]) { _, b in b }
        missingImages = state.ledger?.missingImages ?? []
        blockingFiles = Array((state.ledger?.pendingCloud ?? []).union(state.ledger?.waitingFiles ?? []).union(fileErrors.keys)).sorted()
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

    deinit { timer?.invalidate(); retryTask?.cancel(); folderAccess?.stop() }

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
    public func startAutomaticSync(delay: TimeInterval = 0.5, interval: TimeInterval = 30) {
        if folderAccess == nil {
            let access = SyncFolderAccess(folder: folder) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.automatic != nil else { return }
                    self.retry(after: 0.5)
                }
            }
            access.start()
            folderAccess = access
        }
        automatic = store.objectWillChange
            .debounce(for: .seconds(delay), scheduler: RunLoop.main)
            .sink { [weak self] in self?.syncSoon() }
        contentObservation = store.objectWillChange.sink { [weak self] in
            guard let self, !self.applyingRemoteContent, !self.contentCheckScheduled else { return }
            self.contentCheckScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.contentCheckScheduled = false
                self.checkLocalChanges()
            }
        }
        checkLocalChanges()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSoon() }
        }
        syncSoon()
    }

    public func stopAutomaticSync() {
        automatic = nil
        contentObservation = nil
        folderAccess?.stop()
        folderAccess = nil
        retryTask?.cancel()
        retryTask = nil
        timer?.invalidate()
        timer = nil
    }

    private func checkLocalChanges() {
        let content = store.syncContent
        guard content != observedContent else { return }
        observedContent = content
        if !hasLocalChanges { hasLocalChanges = true }
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
            if let prepareForSync { await waitAtMost(prepareDeadline, prepareForSync) }
            checkLocalChanges()
            let changed = try await runOnce()
            for name in deferredImageRequests { enqueueImage(name) }
            lastCheck = now()
            if !rerun && !waitingForDownload && !waitingForUpload && fileErrors.isEmpty { lastSync = now() }
            // 这一轮成功了就清掉之前的错误；只有「手动同步超时」在还没传完时留着。
            if (!waitingForUpload && !waitingForDownload) || lastErrorCode != "Timeline.SyncTimeout" {
                lastError = nil
                lastErrorCode = nil
                if failureStreak != 0 { failureStreak = 0 }
                failingSince = nil
                if failurePersisted { failurePersisted = false }
            }
            await recordProgress(!fileErrors.isEmpty ? "failed" : (waitingForUpload ? "waitingForUpload" : (waitingForDownload ? "waitingForDownload" : "finished")))
            return changed
        } catch {
            let underlying = error as NSError
            lastErrorCode = "\(underlying.domain) (\(underlying.code))"
            await recordProgress("failed", error: error.localizedDescription)
            lastError = error.localizedDescription
            failureStreak += 1
            noteFailure()
            throw error
        }
    }

    /// 到期时再试一轮，这一轮还失败才提醒：不会在下一轮马上要成功的时候闪一下，用户停下不打字时也能按时提醒。
    private func noteFailure() {
        let uptime = ProcessInfo.processInfo.systemUptime
        let started = failingSince ?? uptime
        failingSince = started
        let remaining = started + persistentErrorDelay - uptime
        if remaining <= 0 {
            if !failurePersisted { failurePersisted = true }
        } else if automatic != nil {
            retry(after: remaining)
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
                if failed || !fileErrors.isEmpty { return }
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
        let next: SyncPhase
        switch stage {
        case "preparing": next = .preparing
        case "readingRemote": next = .reading
        case "exporting": next = .saving
        case "waitingForUpload": next = .waitingForUpload
        case "waitingForDownload": next = .waitingForDownload
        case "finished": next = .completed
        case "failed", "timedOut": next = .failed
        default: next = phase
        }
        if stage == "preparing" { stageDurations = [:]; stageStarted = ProcessInfo.processInfo.systemUptime; timedPhase = .preparing }
        setPhase(next)
        let url = stateURL.deletingLastPathComponent().appendingPathComponent("status.json")
        let formatter = ISO8601DateFormatter()
        var report = ["stage": stage, "time": formatter.string(from: Date()), "error": error ?? lastError ?? "", "device": state.device]
        report["blockingFiles"] = blockingFiles.joined(separator: "\n")
        report["stageDurationsMS"] = stageDurations.sorted { $0.key < $1.key }.map { "\($0.key)=\(Int($0.value * 1000))" }.joined(separator: ",")
        report["waitingForUpload"] = String(waitingForUpload)
        report["waitingForDownload"] = String(waitingForDownload)
        report["pendingUploadFiles"] = String(pendingUploadFiles)
        report["pendingUploadBytes"] = String(pendingUploadBytes)
        report["uploadWaitingSince"] = uploadWaitingSince.map(formatter.string)
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

    private func setPhase(_ next: SyncPhase) {
        guard phase != next else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if timedPhase.isRunning { stageDurations[timedPhase.rawValue, default: 0] += now - stageStarted }
        stageStarted = now; timedPhase = next
        phase = next
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
        if let retryable = try store.retryableSyncState(), retryable.folderPath == state.folderPath {
            state = retryable
        }
        let content = store.syncContent
        let previous = state
        let baseline = syncedContent
        let localChanged = content != syncedContent
        let folder = self.folder, deviceName = self.deviceName, time = now(), retiring = retiringDevice
        await recordProgress("readingRemote")
        let outcome = try await Task.detached(priority: .utility) {
            try Self.merge(content: content, state: previous, localChanged: localChanged, baseline: baseline, folder: folder, deviceName: deviceName, now: time, retiring: retiring)
        }.value
        setPhase(.merging)
        // 合并期间本机又改了：作废这次结果，稍后重来。
        guard store.syncContent == content else { rerun = true; return false }
        if outcome.firstMerge {
            let backup = store.backupsDirectory.appendingPathComponent("before-first-sync-\(JournalDates.key(time))-\(UUID().uuidString).json")
            let document = store.documentSnapshot
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JournalWriter.encode(document).write(to: backup, options: .atomic)
            }.value
            guard store.syncContent == content else { rerun = true; return false }
        }
        let applied = outcome.content != content
        if waitingForDownload != outcome.pendingDownload { waitingForDownload = outcome.pendingDownload }
        if !outcome.pendingDownload && !waitingForUpload { downloadWaits = 0 }
        if outcome.stateChanged { needsExport = true }
        let images = store.imagesDirectory
        var snapshotState = outcome.state
        if time.timeIntervalSince(snapshotState.ledger?.lastImageInventory ?? .distantPast) >= 86400 {
            let inventory = await store.retainedImagesForSync()
            if let inventory { snapshotState.ledger?.protectedImages = inventory }
            snapshotState.ledger?.imageInventoryComplete = inventory != nil
            snapshotState.ledger?.lastImageInventory = time
        }
        let imageInventoryDue = time.timeIntervalSince(previous.ledger?.lastImageInventory ?? .distantPast) >= 86400
        let inspectImages = localChanged || applied || previous.ledger == nil || imageInventoryDue
        let currentNames = inspectImages ? outcome.content.imageNames : []
        let names = (previous.ledger == nil || imageInventoryDue) ? currentNames : currentNames.subtracting(inspectImages ? (syncedContent?.imageNames ?? []) : [])
        snapshotState.ledger?.protectedImages?.formUnion(names)
        let queuedImages = (snapshotState.ledger?.queuedImages ?? []).union(names)
        snapshotState.ledger?.queuedImages = queuedImages
        if snapshotState.ledger != outcome.state.ledger { snapshotState.ledger?.revision += 1 }
        let uploadPending = self.uploadPending
        let recordsChanged = previous.records != snapshotState.records || previous.ledger == nil || previous.commitID == nil
        if recordsChanged { snapshotState.commitID = UUID().uuidString }
        snapshotState.ledger?.deviceID = snapshotState.device
        snapshotState.ledger?.folderPath = snapshotState.folderPath
        snapshotState.ledger?.commitID = snapshotState.commitID
        await recordProgress("exporting")
        guard store.syncContent == content else { rerun = true; return false }
        if applied {
            applyingRemoteContent = true
            store.applySyncContent(outcome.content, persistImmediately: false)
            applyingRemoteContent = false
            observedContent = store.syncContent
        }
        let durableState = snapshotState
        if !previous.records.isEmpty, (durableState.ledger?.sequence ?? 0) > (previous.ledger?.sequence ?? 0), !hasLocalChanges { hasLocalChanges = true }
        if recordsChanged || applied || store.hasPendingSave || durableState.ledger != previous.ledger {
            try await store.saveForSync(state: durableState)
        }
        localSavedAt = store.lastSaved
        state = durableState
        syncedContent = outcome.content
        devices = outcome.devices.map { device in
            var device = device
            device.isRetired = durableState.ledger?.retiredDevices?.contains(device.id) == true
            if let ledger = durableState.ledger, let peer = ledger.peers[device.id] {
                device.supportsRetirement = peer.capabilities?.contains("device-retirement-v1") == true
                device.hasReceivedLocalChanges = (peer.seen[durableState.device] ?? 0) >= ledger.sequence && ledger.sequence > 0
            }
            return device
        }
        setPhase(.publishing)
        let transfer = try await Task.detached(priority: .utility) {
            let persisted = snapshotState
            return try Self.accessing(folder) { () throws -> (Int, Int, URL, IncrementalState, Int, Int) in
                var ledger = persisted.ledger ?? IncrementalState()
                // 正文与附件各自持久化。先发布正文，附件失败不会撤回已发布增量。
                let publication = try IncrementalSync.publish(folder: folder, device: persisted.device, name: deviceName, now: time, state: &ledger)
                var imageBytes = 0
                ledger.attachmentErrors = [:]
                Self.publishRetirements(folder: folder, ledger: &ledger)
                var leaseBytes = 0
                do { leaseBytes = try SyncImageMaintenance.publish(protected: ledger.protectedImages ?? names, folder: folder, device: persisted.device, now: time, state: &ledger) }
                catch { ledger.attachmentErrors?["image-leases/" + persisted.device] = error.localizedDescription }
                let imageQueue = (ledger.queuedImages ?? []).union(ledger.missingImages ?? [])
                var remaining = Set<String>(), missing = Set<String>()
                for name in imageQueue.sorted() {
                    do { imageBytes += try Self.syncImages([name], local: images, folder: folder, ledger: &ledger) }
                    catch ImageExportError.unavailable { missing.insert(name) }
                    catch { remaining.insert(name); ledger.attachmentErrors?["images/" + name] = error.localizedDescription }
                }
                ledger.queuedImages = remaining
                ledger.missingImages = missing
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

                return (pendingCount + (ledger.queuedImages?.count ?? 0) + (ledger.pendingRetirements?.count ?? 0), pendingBytes, publication.url, ledger, publication.bytes + imageBytes + leaseBytes, publication.batches)
            }
        }.value
        var transferredState = snapshotState
        transferredState.ledger = transfer.3
        if transfer.3 != snapshotState.ledger { try await store.saveSyncTransport(transferredState) }
        let revisionChanged = exportedRevision != transfer.2
        exportedRevision = transfer.2
        state.ledger = transfer.3
        let problems = (transfer.3.streamErrors ?? [:]).merging(transfer.3.attachmentErrors ?? [:]) { _, new in new }
        if fileErrors != problems { fileErrors = problems }
        if missingImages != (transfer.3.missingImages ?? []) { missingImages = transfer.3.missingImages ?? [] }
        let blocked = Array(transfer.3.pendingCloud.union(Set(problems.keys)).union(transfer.3.waitingFiles ?? [])).sorted()
        if blockingFiles != blocked { blockingFiles = blocked }
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
        if transfer.0 == 0, !needsExport, store.syncContent == syncedContent, hasLocalChanges { hasLocalChanges = false }
        if store.syncContent != syncedContent { rerun = true }
        return applied
    }

    // MARK: - 后台部分

    nonisolated private static func merge(content: SyncContent, state previous: SyncState, localChanged: Bool, baseline: SyncContent?,
                                          folder: URL, deviceName: String, now: Date, retiring: String? = nil) throws -> Outcome {
        var state = previous
        let retirement = try accessing(folder) { try retiredDevices(in: folder) }
        let retired = retirement.devices
        if retired.contains(state.device) {
            // 被停用设备重新上线：保留正文和墓碑，以新身份及完整检查点重新接入。
            state = SyncState(device: makeDeviceID(), folderPath: previous.folderPath, records: previous.records)
            state.names = previous.names
        }
        var merge = SyncMerge(device: state.device, now: now)
        if localChanged || state.records.isEmpty {
            if let baseline, !state.records.isEmpty {
                let changes = try content.recordChanges(since: baseline)
                merge.stampLocalChanges(changes.values, into: &state.records, scope: changes.scope)
            } else { merge.stampLocalChanges(try content.records(), into: &state.records) }
        }
        let hadRemote = !previous.remote.isEmpty || (previous.ledger?.received.keys.contains { $0 != state.device } ?? false)
        var devices: [Device] = []
        var mergedRemote = false
        var pendingDownload = false
        var ledger = state.ledger ?? IncrementalState()
        ledger.retiredDevices = retired
        var readBytes = 0
        try accessing(folder) {
            // 已停用的设备还读（迟到的内容照样合并），但它的损坏和等待不再影响其他设备的同步状态。
            let quiet = retired.union((ledger.pendingRetirements ?? [:]).keys).union(retiring.map { [$0] } ?? [])
            let incoming = try IncrementalSync.read(folder: folder, device: state.device, state: &ledger, merge: &merge, records: &state.records, quiet: quiet)
            readBytes = incoming.bytes
            mergedRemote = incoming.changed
            pendingDownload = incoming.waiting || !retirement.waiting.isEmpty || !retirement.errors.isEmpty
            ledger.streamErrors = (ledger.streamErrors ?? [:]).merging(retirement.errors) { _, b in b }
            ledger.waitingFiles?.formUnion(retirement.waiting)
            try coordinatedCreateDirectory(folder.appendingPathComponent(devicesFolder))
            let (files, placeholders) = try remoteFiles(in: folder, excluding: state.device, ignoring: ledger.migrated)
            pendingDownload = pendingDownload || placeholders
            let present = Set(files.map { $0.deletingPathExtension().lastPathComponent })
            // 云端占位文件尚未下载时保留原缓存；其余已被清理的旧版本不再占本地状态。
            if !placeholders { state.remote = state.remote.filter { present.contains($0.key) } }
            for file in files {
                do {
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
                } catch {
                    ledger.streamErrors?[file.deletingLastPathComponent().lastPathComponent + "/" + file.lastPathComponent] = error.localizedDescription
                    pendingDownload = true
                }
            }
        }
        for peer in ledger.peers.values {
            state.names[peer.device] = peer.name
            devices.append(Device(id: peer.device, name: peer.name, exportedAt: peer.date,
                                  hasReceivedLocalChanges: (peer.seen[state.device] ?? 0) >= ledger.sequence && ledger.sequence > 0))
        }
        let ownBatchMissing = try accessing(folder) {
            guard let file = ledger.lastBatch, ledger.pending.isEmpty else { return false }
            let url = folder.appendingPathComponent(IncrementalSync.directory).appendingPathComponent(state.device).appendingPathComponent(file)
            let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + file + ".icloud")
            return !FileManager.default.fileExists(atPath: url.path) && !FileManager.default.fileExists(atPath: placeholder.path)
        }
        if ownBatchMissing {
            let batch = SyncBatch(device: state.device, name: deviceName, sequence: ledger.sequence + 1,
                                  base: ledger.sequence, checkpoint: true, exportedAt: now, records: state.records, seen: ledger.received)
            ledger.sequence = batch.sequence
            ledger.checkpointSequence = batch.sequence
            ledger.deltaCount = 0
            ledger.deltaBytes = 0
            ledger.pending.append(batch)
            ledger.received[state.device] = batch.sequence
            ledger.markerPublished = false
            ledger.publishedReceipt = nil
            ledger.queuedImages = content.imageNames
        }
        let shouldApply = localChanged || mergedRemote || state.records != previous.records
        var merged = shouldApply ? (mergedRemote ? content.applying(state.records) : content.normalizing(using: state.records)) : content
        if shouldApply {
            let changes = try merged.recordChanges(since: content)
            merge.stampLocalChanges(changes.values, into: &state.records, scope: changes.scope)
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
            for name in try coordinatedDirectoryContents(directory).map(\.lastPathComponent) {
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

    /// 原图仅上传一次；未查看的远端原图保持在云端。
    nonisolated private static func syncImages(_ names: Set<String>, local: URL, folder: URL, ledger: inout IncrementalState) throws -> Int {
        let manager = FileManager.default
        var written = 0
        let remote = folder.appendingPathComponent(imagesFolder)
        try coordinatedCreateDirectory(remote)
        for name in names.sorted() where !name.contains("/") && !name.contains("\\") && !name.hasPrefix(".") {
            let mine = local.appendingPathComponent(name), theirs = remote.appendingPathComponent(name)
            if manager.fileExists(atPath: mine.path) {
                let placeholder = remote.appendingPathComponent("." + name + ".icloud")
                if !manager.fileExists(atPath: theirs.path) && !manager.fileExists(atPath: placeholder.path) {
                    let data = try Data(contentsOf: mine)
                    try coordinatedWrite(data, to: theirs)
                    written += data.count
                }
                ledger.pendingCloud.insert(imagesFolder + "/" + name)
                ledger.uploadedImages.insert(name)
            } else if manager.fileExists(atPath: theirs.path) || manager.fileExists(atPath: remote.appendingPathComponent("." + name + ".icloud").path) {
                ledger.uploadedImages.insert(name)
            } else { throw ImageExportError.unavailable }
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
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) || (try? coordinatedCreateDirectory(folder)) != nil
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
        try coordinatedCreateDirectory(url.deletingLastPathComponent())
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        // 更新内容（包括 atomic rename）用普通写意图；forReplacing 表示替换文档身份。
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { actual in
            result = Result { try data.write(to: actual, options: .atomic) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        try result.get()
    }

    nonisolated static func coordinatedCreateDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw CocoaError(.fileWriteFileExists) }
            return
        }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { throw SyncError.folderUnavailable(url.path) }
        try coordinatedCreateDirectory(parent)
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { actual in
            result = Result { try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        try result.get()
    }

    nonisolated static func coordinatedDirectoryContents(_ url: URL) throws -> [URL] {
        var coordinationError: NSError?
        var result: Result<[URL], Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { actual in
            result = Result { try FileManager.default.contentsOfDirectory(at: actual, includingPropertiesForKeys: nil) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
}

/// 等 `operation` 完成，最多等 `seconds` 秒；到时间就继续往下走，`operation` 留在后台自己结束。
@MainActor
public func waitAtMost(_ seconds: TimeInterval, _ operation: @escaping () async -> Void) async {
    final class Latch {
        var continuation: CheckedContinuation<Void, Never>?
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
        func finish() {
            continuation?.resume()
            continuation = nil
            work = nil
            timer?.cancel()
            timer = nil
        }
    }
    let latch = Latch()
    await withCheckedContinuation { continuation in
        latch.continuation = continuation
        latch.work = Task { @MainActor in
            await operation()
            latch.finish()
        }
        latch.timer = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) } catch { return }
            latch.finish()
        }
    }
}

extension FolderSync {
    nonisolated private static func path(_ path: String, belongsTo device: String) -> Bool {
        path == "streams/" + device || path.hasPrefix("streams/" + device + "/")
            || path == "receipts/" + device || path.hasPrefix("receipts/" + device + "-")
    }

    /// 显式退役；先持久化完整检查点，保留旧流，离线旧设备仍可安全重新接入。
    public func retireDevice(_ id: String) async throws {
        guard !store.isReadOnly else { throw SyncError.readOnly }
        guard !isSyncing, IncrementalSync.safe(id), id != deviceID,
              devices.contains(where: { $0.id == id && !$0.isRetired }) else { throw SyncError.retirementUnavailable }
        guard devices.first(where: { $0.id == id })?.supportsRetirement == true else { throw SyncError.upgradeRequired }
        try await sync()
        // 这台设备自己的数据坏了正是要停用它的原因：能读的已经合并，只看其他内容是否同步完。
        // 它只是还没下载完不算损坏，要继续等，免得漏掉它的内容。
        defer { retiringDevice = nil }
        if fileErrors.keys.contains(where: { Self.path($0, belongsTo: id) }) {
            retiringDevice = id
            try await sync()
        }
        guard !isSyncing, !waitingForDownload, fileErrors.isEmpty else { throw SyncError.retirementBlocked }
        isSyncing = true
        defer { isSyncing = false; syncSoon() }
        let own = deviceID
        var next = state
        var ledger = next.ledger ?? IncrementalState()
        let batch = SyncBatch(device: own, name: deviceName, sequence: ledger.sequence + 1,
                              base: ledger.sequence, checkpoint: true, exportedAt: now(), records: next.records, seen: ledger.received)
        ledger.sequence = batch.sequence; ledger.checkpointSequence = batch.sequence
        ledger.deltaCount = 0; ledger.deltaBytes = 0
        ledger.received[own] = batch.sequence
        ledger.pending.append(batch)
        let marker = SyncRetirement(device: id, retiredBy: own, date: now())
        ledger.pendingRetirements = (ledger.pendingRetirements ?? [:]).merging([id: marker]) { _, new in new }
        ledger.revision += 1
        next.ledger = ledger
        try await store.saveForSync(state: next)
        state = next
        // 统一发布先写检查点，再写标记；写入失败的完整操作仍在 SQLite 中。
        isSyncing = false
        try await sync()
        if let message = fileErrors["retired-devices/" + id + ".json"] {
            throw NSError(domain: "Timeline.Retirement", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
