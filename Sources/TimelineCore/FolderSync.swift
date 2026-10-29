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
struct SyncState: Codable {
    var device: String
    var records: [String: SyncRecord] = [:]
    var remote: [String: RemoteMark] = [:]
    var names: [String: String] = [:]

    struct RemoteMark: Codable, Equatable {
        var modified: Date
        var size: Int
        var digest: String?
        var exportedAt: Date?
    }
}

/// 通过一个普通的共享文件夹（通常是 iCloud Drive 里的「Timeline」）和其他设备同步，不需要 iCloud 权限。
///
/// - `devices/<设备>.json`：每台设备只写自己的文件，内容是它知道的全部记录（含删除标记），读别人的文件逐条合并。
/// - `updates/<设备>-<内容摘要>.json`：不可变更新快照，避免覆盖文件长期等待上传。
/// - `images/`：图片以 UUID 命名、写入后不再修改，缺哪张补哪张。
///
/// 读写文件夹（可能要等 iCloud 下载）都在后台进行；只有合并结果写回 `JournalStore` 时回到主线程。
/// 后台合并期间本机又有修改的话，这次结果作废，下一轮重来，不会把本机刚做的修改当成旧数据覆盖掉。
@MainActor
public final class FolderSync: ObservableObject {
    public struct Device: Equatable, Identifiable {
        public var id: String
        public var name: String
        public var exportedAt: Date
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
    /// 本机快照已写入，但 iCloud 还未确认上传完成。
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
        let statusURL = url.deletingLastPathComponent().appendingPathComponent("status.json")
        if let data = try? Data(contentsOf: statusURL), let report = try? JSONDecoder().decode([String: String].self, from: data) {
            let formatter = ISO8601DateFormatter()
            lastCheck = report["lastCheck"].flatMap { formatter.date(from: $0) }
            lastExport = report["lastExport"].flatMap { formatter.date(from: $0) }
            lastUpload = report["lastUpload"].flatMap { formatter.date(from: $0) }
        }
    }

    deinit { timer?.invalidate(); retryTask?.cancel() }

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

    /// 同步一轮：合并其他设备的修改、导出本机状态、补齐图片。返回本机数据有没有被改动。
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
        syncedContent = store.syncContent
        state = outcome.state
        devices = outcome.devices
        if waitingForDownload != outcome.pendingDownload { waitingForDownload = outcome.pendingDownload }
        if !outcome.pendingDownload && !waitingForUpload { downloadWaits = 0 }
        if applied { store.save() }
        if outcome.stateChanged { needsExport = true }
        let images = store.imagesDirectory, stateURL = self.stateURL, snapshotState = outcome.state, names = outcome.content.imageNames
        let exporting = needsExport, uploadPending = self.uploadPending, previousRevision = exportedRevision
        await recordProgress("exporting")
        let transfer = try await Task.detached(priority: .utility) { () throws -> (Int, Bool, URL) in
            try Self.write(state: snapshotState, to: stateURL)
            return try Self.accessing(folder) {
                let own = Self.snapshotURL(folder, snapshotState.device)
                let revision: URL
                if exporting || previousRevision == nil || !FileManager.default.fileExists(atPath: own.path) {
                    revision = try Self.export(SyncSnapshot(device: snapshotState.device, name: deviceName, exportedAt: time, records: snapshotState.records), to: folder)
                } else {
                    revision = previousRevision!
                }
                // 更新快照只创建一次，不覆盖；旧设备仍可读取 devices 下的兼容快照。
                let waiting = try uploadPending(revision)
                // 保存最后一次实际导出的内容，便于与云端收到的版本核对。
                if exporting, let data = try Self.coordinatedRead(own) {
                    try data.write(to: stateURL.deletingLastPathComponent().appendingPathComponent("export.json"), options: .atomic)
                }
                return (try Self.syncImages(names, local: images, folder: folder), waiting, revision)
            }
        }.value
        let revisionChanged = exportedRevision != transfer.2
        exportedRevision = transfer.2
        if exporting { lastExport = now() }
        if transfer.1 {
            if uploadWaitingSince == nil || revisionChanged { uploadWaitingSince = now() }
        } else {
            uploadWaitingSince = nil
            if revisionChanged || waitingForUpload || lastUpload == nil { lastUpload = now() }
        }
        if waitingForUpload != transfer.1 { waitingForUpload = transfer.1 }
        if exporting, state.records == snapshotState.records { needsExport = false }
        if store.syncContent != syncedContent { rerun = true }
        // 新下载的图片：让界面重新读取。
        if transfer.0 > 0 { store.objectWillChange.send() }
        return applied
    }

    // MARK: - 后台部分

    nonisolated private static func merge(content: SyncContent, state previous: SyncState, localChanged: Bool,
                                          folder: URL, deviceName: String, now: Date) throws -> Outcome {
        var state = previous
        var merge = SyncMerge(device: state.device, now: now)
        if localChanged || state.records.isEmpty { merge.stampLocalChanges(try content.records(), into: &state.records) }
        let hadRemote = !previous.remote.isEmpty
        var devices: [Device] = []
        var mergedRemote = false
        var pendingDownload = false
        try accessing(folder) {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(devicesFolder), withIntermediateDirectories: true)
            let (files, placeholders) = try remoteFiles(in: folder, excluding: state.device)
            pendingDownload = placeholders
            let present = Set(files.map { $0.deletingPathExtension().lastPathComponent })
            // 云端占位文件尚未下载时保留原缓存；其余已被清理的旧版本不再占本地状态。
            if !placeholders { state.remote = state.remote.filter { present.contains($0.key) } }
            for file in files {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                let id = file.deletingPathExtension().lastPathComponent
                let ownerID = file.deletingLastPathComponent().lastPathComponent == updatesFolder ? String(id.split(separator: "-", maxSplits: 1).first ?? Substring(id)) : id
                // iCloud 云盘不会主动把别的设备更新过的文件拉到本机（iOS 上尤其如此）：本机这份不是最新的，
                // 就请系统下载，这一轮先用手上的，下载完修改时间变了再合并。
                if values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus, status != .current {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: file)
                    pendingDownload = true
                }
                // iCloud 替换文件时可能保留修改时间和字节数。必须按实际内容判断，
                // 否则等长的 Board 编辑会一直被当成“已经同步过”。读取、摘要均在后台。
                guard let data = try coordinatedRead(file) else { continue }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                var mark = SyncState.RemoteMark(modified: values?.contentModificationDate ?? .distantPast, size: data.count, digest: digest)
                if state.remote[id]?.digest == digest, let name = state.names[id], let exportedAt = state.remote[id]?.exportedAt {
                    devices.append(Device(id: ownerID, name: name, exportedAt: exportedAt))
                    continue
                }
                let snapshot = try JSONDecoder().decode(SyncSnapshot.self, from: data)
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
        guard localChanged || mergedRemote || state.records != previous.records else {
            return Outcome(state: state, content: content, stateChanged: false, devices: uniqueDevices(devices), firstMerge: false,
                           pendingDownload: pendingDownload)
        }
        // 合并结果还原成内容；改编号之类的整理算本机的新修改。
        var merged = content.applying(state.records)
        merge.stampLocalChanges(try merged.records(), into: &state.records)
        merged.nextTaskNumber = max(merged.nextTaskNumber, content.nextTaskNumber)
        let changed = state.records != previous.records
        return Outcome(state: state, content: merged, stateChanged: changed, devices: uniqueDevices(devices),
                       firstMerge: mergedRemote && !hadRemote && !content.days.isEmpty && merged != content, pendingDownload: pendingDownload)
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
    nonisolated private static func remoteFiles(in folder: URL, excluding device: String) throws -> ([URL], Bool) {
        var files: [URL] = []
        var placeholders = false
        for subfolder in [devicesFolder, updatesFolder] {
            let directory = folder.appendingPathComponent(subfolder)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                let real = placeholderTarget(name) ?? name
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

    /// File Provider 对覆盖已有文件可能长时间等待上传；不可变快照独立入队，避免后续编辑覆盖待上传版本。
    @discardableResult
    nonisolated private static func export(_ snapshot: SyncSnapshot, to folder: URL) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let fingerprint = SHA256.hash(data: try encoder.encode(snapshot.records)).map { String(format: "%02x", $0) }.joined()
        let directory = folder.appendingPathComponent(updatesFolder)
        let revision = directory.appendingPathComponent(snapshot.device + "-" + fingerprint + ".json")
        let data = try encoder.encode(snapshot)
        if !FileManager.default.fileExists(atPath: revision.path) { try coordinatedWrite(data, to: revision) }
        let legacy = snapshotURL(folder, snapshot.device)
        let existing = FileManager.default.fileExists(atPath: legacy.path) ? try coordinatedRead(legacy) : nil
        let existingRecords = existing.flatMap { try? JSONDecoder().decode(SyncSnapshot.self, from: $0).records }
        if existingRecords != snapshot.records { try coordinatedWrite(data, to: legacy) }
        // 每份都是完整状态（含删除标记），保留最近三份即可。离线时也要合并掉旧版本队列，
        // 否则连续编辑会产生大量永远未上传的历史文件；最新状态另有本地 state/export 备份。
        let older = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.lastPathComponent.hasPrefix(snapshot.device + "-") && $0.pathExtension == "json" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for file in older.dropFirst(3) where file != revision {
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: file, options: .forDeleting, error: &error) { try? FileManager.default.removeItem(at: $0) }
        }
        return revision
    }

    nonisolated private static func write(state: SyncState, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    /// 补齐两边缺的图片，返回下载到本机的张数。
    nonisolated private static func syncImages(_ names: Set<String>, local: URL, folder: URL) throws -> Int {
        let manager = FileManager.default
        let remote = folder.appendingPathComponent(imagesFolder)
        try manager.createDirectory(at: remote, withIntermediateDirectories: true)
        try manager.createDirectory(at: local, withIntermediateDirectories: true)
        var remoteNames = Set<String>()
        for name in try manager.contentsOfDirectory(atPath: remote.path) {
            if let real = placeholderTarget(name) {
                remoteNames.insert(real)
                if names.contains(real), !manager.fileExists(atPath: local.appendingPathComponent(real).path) {
                    try? manager.startDownloadingUbiquitousItem(at: remote.appendingPathComponent(real))
                }
            } else {
                remoteNames.insert(name)
            }
        }
        var downloaded = 0
        for name in names.sorted() where !name.contains("/") && !name.hasPrefix(".") {
            let mine = local.appendingPathComponent(name), theirs = remote.appendingPathComponent(name)
            let haveLocal = manager.fileExists(atPath: mine.path)
            if haveLocal, !remoteNames.contains(name) {
                try coordinatedWrite(try Data(contentsOf: mine), to: theirs)
            } else if !haveLocal, manager.fileExists(atPath: theirs.path), let data = try coordinatedRead(theirs) {
                try data.write(to: mine, options: .atomic)
                downloaded += 1
            }
        }
        return downloaded
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
