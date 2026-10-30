import Combine
import Foundation

/// 手机顶栏的同步小图标。只区分用户需要知道的几件事，不展示同步的内部阶段。
public enum SyncIndicatorState: String, Equatable, Sendable {
    /// 没什么要说的：已经传出去、刚改完还在正常的上传时间内，或正在输入。
    case hidden
    /// 修改已存在本机，过了正常的上传时间，iCloud 还没确认收到。
    case pending
    /// 用户刚点了同步，正在进行。
    case working
    /// 用户点的这次同步确实完成了。
    case confirmed
    /// 有具体的文件同步不了（其他设备的数据损坏、原图读不了之类）。
    case attention

    public var symbol: String {
        switch self {
        case .hidden, .pending, .working: return "icloud.and.arrow.up"
        case .confirmed: return "checkmark.icloud"
        case .attention: return "exclamationmark.icloud"
        }
    }

    public var title: String {
        switch self {
        case .hidden: return "同步"
        case .pending: return "修改已存在本机，等待上传到 iCloud"
        case .working: return "正在同步"
        case .confirmed: return "已同步到 iCloud"
        case .attention: return "有文件同步不了"
        }
    }

    /// 输入时什么都不显示（用户自己点的同步除外）；手动确认只留一小会儿；本机修改安静一段时间后才提示。
    /// 本机保存失败、同步连续失败由 `IssueBanner` 那颗胶囊说，这里不重复，也不把保存失败说成同步失败。
    static func resolve(working: Bool, editing: Bool, confirming: Bool, hasFileErrors: Bool, unconfirmedLocalChanges: Bool, quietElapsed: Bool) -> SyncIndicatorState {
        if working { return .working }
        if editing { return .hidden }
        if confirming { return .confirmed }
        if hasFileErrors { return .attention }
        return unconfirmedLocalChanges && quietElapsed ? .pending : .hidden
    }
}

/// 用户点同步之后的结果：决定要不要解释一句。
public enum SyncIndicatorOutcome: Equatable, Sendable {
    case confirmed
    /// 本机这边都做完了，还在等系统上传或下载（不是错误）。
    case waiting
    case failed(String)
}

/// 自动同步全程不打扰，状态只在真的变化时发布：顶栏不随同步阶段闪动，也不让页面跟着重算。
@MainActor
public final class SyncIndicator: ObservableObject {
    @Published public private(set) var state: SyncIndicatorState = .hidden
    private let sync: FolderSync
    private let quietPeriod: TimeInterval
    private let confirmDuration: TimeInterval
    private var working = false
    private var editing = false
    private var confirming = false
    private var lastChange = ProcessInfo.processInfo.systemUptime
    private var refreshScheduled = false
    private var observations: [AnyCancellable] = []
    private var quietTask: Task<Void, Never>?
    private var confirmTask: Task<Void, Never>?

    /// `quietPeriod` 盖过一轮自动检查（15 秒）加上 iCloud 通常的上传时间：正常往返时图标根本不出现。
    public init(sync: FolderSync, quietPeriod: TimeInterval = 30, confirmDuration: TimeInterval = 1.5) {
        self.sync = sync
        self.quietPeriod = quietPeriod
        self.confirmDuration = confirmDuration
        observations.append(sync.objectWillChange.sink { [weak self] in self?.scheduleRefresh() })
        // 只记时间，不比较内容：打字时这里也要足够便宜。
        observations.append(sync.store.objectWillChange.sink { [weak self] in
            guard let self else { return }
            self.lastChange = ProcessInfo.processInfo.systemUptime
            if self.state == .pending { self.scheduleRefresh() }
        })
        refresh()
    }

    deinit {
        quietTask?.cancel()
        confirmTask?.cancel()
    }

    public func setEditing(_ value: Bool) {
        guard editing != value else { return }
        editing = value
        refresh()
    }

    /// 具体的问题（同步设置页也列着），给用户点开时看。
    public var problem: String? {
        sync.fileErrors.keys.min().map { "\($0)\n\(sync.fileErrors[$0] ?? "")" }
    }

    public func run(_ operation: () async -> Void) async -> SyncIndicatorOutcome {
        guard !working else { return .waiting }
        confirmTask?.cancel()
        confirming = false
        working = true
        refresh()
        await operation()
        working = false
        defer { refresh() }
        if let problem { return .failed(problem) }
        if let message = sync.store.errorMessage { return .failed(message) }
        if let message = sync.lastError, sync.lastErrorCode != "Timeline.SyncTimeout" { return .failed(message) }
        if Task.isCancelled || sync.hasLocalChanges || sync.waitingForUpload || sync.waitingForDownload { return .waiting }
        confirming = true
        confirmTask = Task { @MainActor [weak self, duration = confirmDuration] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000)) } catch { return }
            self?.confirming = false
            self?.refresh()
        }
        return .confirmed
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        let remaining = lastChange + quietPeriod - ProcessInfo.processInfo.systemUptime
        let next = SyncIndicatorState.resolve(working: working, editing: editing, confirming: confirming, hasFileErrors: !sync.fileErrors.isEmpty,
                                              unconfirmedLocalChanges: sync.hasLocalChanges, quietElapsed: remaining <= 0)
        if state != next { state = next }
        if sync.hasLocalChanges, remaining > 0, quietTask == nil {
            quietTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) } catch { return }
                self?.quietTask = nil
                self?.refresh()
            }
        }
    }
}
