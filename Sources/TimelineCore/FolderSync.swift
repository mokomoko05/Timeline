import Combine
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
    }
}

/// 通过一个普通的共享文件夹（通常是 iCloud Drive 里的「Timeline」）和其他设备同步，不需要 iCloud 权限。
///
/// - `devices/<设备>.json`：每台设备只写自己的文件，内容是它知道的全部记录（含删除标记），读别人的文件逐条合并。
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

        public var errorDescription: String? {
            switch self {
            case .readOnly: return "当前数据只读，已暂停同步。"
            case .folderUnavailable(let path): return "无法访问同步文件夹：\(path)"
            case .newerFormat(let name): return "「\(name)」上的 Timeline 版本更新，请先更新本机的应用。"
            }
        }
    }

    public let store: JournalStore
    public let folder: URL
    public let deviceName: String
    @Published public private(set) var isSyncing = false
    @Published public private(set) var lastSync: Date?
    @Published public private(set) var lastError: String?
    @Published public private(set) var devices: [Device] = []
    /// 其他设备的文件在 iCloud 上有更新、本机还没下载到：已经请系统下载，几秒后再看。
    @Published public private(set) var waitingForDownload = false
    /// 测试里可以替换「现在」。
    var now: () -> Date = Date.init

    private var state: SyncState
    private var syncedContent: SyncContent?
    private var rerun = false
    /// 本机状态变了还没成功导出：导出失败时下一轮接着导。
    private var needsExport = true
    /// 连续等下载的轮数：iCloud 一直没下载下来时别无限地每几秒查一次。
    private var downloadWaits = 0
    private var automatic: AnyCancellable?
    private var timer: Timer?

    public var deviceID: String { state.device }
    var stateURL: URL { Self.stateURL(in: store.directory) }
    nonisolated static func stateURL(in directory: URL) -> URL { directory.appendingPathComponent("Sync/state.json") }
    public nonisolated static let devicesFolder = "devices"
    public nonisolated static let imagesFolder = "images"

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
    }

    deinit { timer?.invalidate() }

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

    /// 同步一轮：合并其他设备的修改、导出本机状态、补齐图片。返回本机数据有没有被改动。
    @discardableResult
    public func sync() async throws -> Bool {
        guard !isSyncing else { rerun = true; return false }
        isSyncing = true
        defer {
            isSyncing = false
            if rerun { rerun = false; syncSoon(after: 2) }
            else if waitingForDownload, downloadWaits < 40 { downloadWaits += 1; syncSoon(after: 3) }
        }
        do {
            let changed = try await runOnce()
            lastSync = now()
            lastError = nil
            return changed
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// 进后台前用：`sync()` 遇上正在进行的一轮会直接返回、等之后补一轮，可应用挂起后那一轮就不会来了。
    /// 这里等手上那一轮结束，再同步到本机的最新内容确实导出为止（最多等 `timeout` 秒）。
    public func syncUntilExported(timeout: TimeInterval = 20) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isSyncing {
                do { _ = try await sync() } catch { return }
                if !needsExport, syncedContent == store.syncContent { return }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
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
        if !outcome.pendingDownload { downloadWaits = 0 }
        if applied { store.save() }
        if outcome.stateChanged { needsExport = true }
        let images = store.imagesDirectory, stateURL = self.stateURL, snapshotState = outcome.state, names = outcome.content.imageNames
        let exporting = needsExport
        let downloaded = try await Task.detached(priority: .utility) { () throws -> Int in
            try Self.write(state: snapshotState, to: stateURL)
            return try Self.accessing(folder) {
                if exporting || !FileManager.default.fileExists(atPath: Self.snapshotURL(folder, snapshotState.device).path) {
                    try Self.export(SyncSnapshot(device: snapshotState.device, name: deviceName, exportedAt: time, records: snapshotState.records), to: folder)
                }
                return try Self.syncImages(names, local: images, folder: folder)
            }
        }.value
        if exporting, state.records == snapshotState.records { needsExport = false }
        // 新下载的图片：让界面重新读取。
        if downloaded > 0 { store.objectWillChange.send() }
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
            for file in files {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                let mark = SyncState.RemoteMark(modified: values?.contentModificationDate ?? .distantPast, size: values?.fileSize ?? 0)
                let id = file.deletingPathExtension().lastPathComponent
                // iCloud 云盘不会主动把别的设备更新过的文件拉到本机（iOS 上尤其如此）：本机这份不是最新的，
                // 就请系统下载，这一轮先用手上的，下载完修改时间变了再合并。
                if values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus, status != .current {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: file)
                    pendingDownload = true
                }
                if state.remote[id] == mark, let name = state.names[id] {
                    devices.append(Device(id: id, name: name, exportedAt: mark.modified))
                    continue
                }
                guard let data = try coordinatedRead(file) else { continue }
                let snapshot = try JSONDecoder().decode(SyncSnapshot.self, from: data)
                guard snapshot.format <= SyncSnapshot.currentFormat else { throw SyncError.newerFormat(snapshot.name) }
                state.names[snapshot.device] = snapshot.name
                merge.describeDevice = { [names = state.names] in names[$0] ?? $0 }
                merge.merge(snapshot.records, into: &state.records)
                state.remote[id] = mark
                mergedRemote = true
                devices.append(Device(id: id, name: snapshot.name, exportedAt: snapshot.exportedAt))
            }
        }
        guard localChanged || mergedRemote || state.records != previous.records else {
            return Outcome(state: state, content: content, stateChanged: false, devices: devices.sorted { $0.name < $1.name }, firstMerge: false,
                           pendingDownload: pendingDownload)
        }
        // 合并结果还原成内容；改编号之类的整理算本机的新修改。
        var merged = content.applying(state.records)
        merge.stampLocalChanges(try merged.records(), into: &state.records)
        merged.nextTaskNumber = max(merged.nextTaskNumber, content.nextTaskNumber)
        let changed = state.records != previous.records
        return Outcome(state: state, content: merged, stateChanged: changed, devices: devices.sorted { $0.name < $1.name },
                       firstMerge: mergedRemote && !hadRemote && !content.days.isEmpty && merged != content, pendingDownload: pendingDownload)
    }

    nonisolated static func snapshotURL(_ folder: URL, _ device: String) -> URL {
        folder.appendingPathComponent(devicesFolder).appendingPathComponent(device + ".json")
    }

    /// 其他设备的快照文件。iCloud 还没下载的文件在旧系统上显示为 `.名字.icloud`：先触发下载，这一轮跳过（第二个返回值为 true）。
    nonisolated private static func remoteFiles(in folder: URL, excluding device: String) throws -> ([URL], Bool) {
        let directory = folder.appendingPathComponent(devicesFolder)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var files: [URL] = []
        var placeholders = false
        for name in names {
            if let real = placeholderTarget(name) {
                if real.hasSuffix(".json"), real != device + ".json" {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: directory.appendingPathComponent(real))
                    placeholders = true
                }
                continue
            }
            guard name.hasSuffix(".json"), !name.hasPrefix("."), name != device + ".json" else { continue }
            files.append(directory.appendingPathComponent(name))
        }
        return (files.sorted { $0.lastPathComponent < $1.lastPathComponent }, placeholders)
    }

    nonisolated private static func placeholderTarget(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    nonisolated private static func export(_ snapshot: SyncSnapshot, to folder: URL) throws {
        let data = try JSONEncoder().encode(snapshot)
        try coordinatedWrite(data, to: snapshotURL(folder, snapshot.device))
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
