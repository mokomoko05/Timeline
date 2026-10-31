import Combine
import Foundation

public enum SyncPhase: String, Equatable, Sendable {
    case idle, preparing, reading, merging, saving, publishing, waitingForUpload, waitingForDownload, completed, failed

    public var title: String {
        switch self {
        case .idle: return "同步"
        case .preparing: return "准备同步…"
        case .reading: return "检查更新…"
        case .merging: return "合并更新…"
        case .saving: return "保存更新…"
        case .publishing: return "写入同步文件夹…"
        case .waitingForUpload: return "等待上传"
        case .waitingForDownload: return "等待下载"
        case .completed: return "本机同步完成"
        case .failed: return "同步未完成"
        }
    }

    public var symbol: String {
        switch self {
        case .idle, .preparing: return "arrow.triangle.2.circlepath.icloud"
        case .reading, .waitingForDownload: return "icloud.and.arrow.down"
        case .merging: return "arrow.triangle.merge"
        case .saving: return "externaldrive"
        case .publishing, .waitingForUpload: return "icloud.and.arrow.up"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.icloud"
        }
    }

    public var isRunning: Bool { [.preparing, .reading, .merging, .saving, .publishing].contains(self) }
}

/// 本机内容变更及手动重试才显示；自动轮询和单纯接收远端内容保持安静。
@MainActor
public final class SyncButtonFeedback: ObservableObject {
    @Published public private(set) var phase: SyncPhase = .idle
    @Published public private(set) var isWorking = false
    @Published public private(set) var shouldShow = false
    private let sync: FolderSync
    private let completionDuration: TimeInterval
    private var awaitingCompletion = false
    private var completed = false
    /// 用户自己点的同步失败了要马上说；自动同步的失败和底部提示条一样，持续一阵才算（见 `FolderSync.persistentError`）。
    private var manualFailure = false
    private var refreshScheduled = false
    private var observation: AnyCancellable?
    private var hideTask: Task<Void, Never>?

    public init(sync: FolderSync, completionDuration: TimeInterval = 2) {
        self.sync = sync
        self.completionDuration = completionDuration
        observation = Publishers.Merge(sync.objectWillChange.map { _ in () }, sync.store.$errorMessage.dropFirst().map { _ in () }).sink { [weak self] in
            guard let self, !self.refreshScheduled else { return }
            self.refreshScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshScheduled = false
                self.refresh()
            }
        }
        refresh()
    }

    deinit { hideTask?.cancel() }

    public func run(_ operation: () async -> Void) async {
        guard !isWorking else { return }
        hideTask?.cancel()
        completed = false
        awaitingCompletion = true
        isWorking = true
        setVisible(true)
        setPhase(.preparing)
        await operation()
        isWorking = false
        if Task.isCancelled { awaitingCompletion = false; refresh(); return }
        manualFailure = sync.lastError != nil
        if sync.lastError != nil, sync.lastErrorCode != "Timeline.SyncTimeout" { awaitingCompletion = false }
        refresh()
    }

    private func refresh() {
        if sync.lastError == nil { manualFailure = false }
        let failed = manualFailure || sync.persistentError != nil
        if sync.hasLocalChanges {
            awaitingCompletion = true
            completed = false
            hideTask?.cancel()
        }
        if sync.store.errorMessage != nil {
            awaitingCompletion = false; completed = false
            hideTask?.cancel()
            setVisible(true); setPhase(.failed)
            return
        }
        // 接收远端内容所需的回执也可能等待上传，但不是本机编辑反馈。
        if !isWorking, !awaitingCompletion, !completed, !sync.hasLocalChanges, !failed, sync.fileErrors.isEmpty {
            setVisible(false)
            setPhase(.idle)
            return
        }
        if isWorking {
            setVisible(true)
            setPhase(sync.phase.isRunning ? sync.phase : (sync.waitingForUpload ? .waitingForUpload : (sync.waitingForDownload ? .waitingForDownload : .preparing)))
            return
        }
        if !sync.fileErrors.isEmpty { completed = false; setVisible(true); setPhase(.failed); return }
        if sync.waitingForUpload { completed = false; setVisible(true); setPhase(.waitingForUpload); return }
        if sync.waitingForDownload { completed = false; setVisible(true); setPhase(.waitingForDownload); return }
        if failed { completed = false; setVisible(true); setPhase(.failed); return }
        if sync.hasLocalChanges {
            setVisible(true)
            setPhase(sync.isSyncing && sync.phase.isRunning ? sync.phase : .idle)
            return
        }
        if awaitingCompletion, sync.isSyncing {
            setVisible(true)
            setPhase(sync.phase.isRunning ? sync.phase : .publishing)
            return
        }
        if awaitingCompletion, !sync.isSyncing, sync.lastSync != nil, sync.lastError == nil {
            awaitingCompletion = false
            completed = true
            hideTask?.cancel()
            hideTask = Task { @MainActor [weak self, duration = completionDuration] in
                do { try await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000)) } catch { return }
                self?.completed = false
                self?.refresh()
            }
        }
        setVisible(completed)
        setPhase(completed ? .completed : .idle)
    }

    private func setPhase(_ value: SyncPhase) { if phase != value { phase = value } }
    private func setVisible(_ value: Bool) { if shouldShow != value { shouldShow = value } }
}
