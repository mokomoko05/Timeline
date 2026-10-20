import AppKit
import Combine
import SwiftUI
import TimelineCore

private struct FocusSessionKey: EnvironmentKey {
    static let defaultValue: FocusSession? = nil
}

extension EnvironmentValues {
    var focusSession: FocusSession? {
        get { self[FocusSessionKey.self] }
        set { self[FocusSessionKey.self] = newValue }
    }
}

/// 专注计时允许自由切换页面；到点暂停，等待阶段反馈或延长。
@MainActor
final class FocusSession: ObservableObject {
    struct Active: Equatable {
        let taskID: UUID
        let number: Int?
        let title: String
        /// 任务里的链接；没有链接的任务为 nil：只计时，不打开页面、也不检测是否离开。
        let url: URL?
        let started: Date
        /// 本轮计划时长；到点暂停并提示阶段反馈。
        let plannedSeconds: TimeInterval
        /// 本轮专注目标（可为空）。
        let goal: String
        /// 「开始专注」那条日志；专注太短时要把它撤掉。
        var startLogID: UUID?
    }

    @Published private(set) var active: Active?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var isPaused = false
    @Published private(set) var needsReflection = false
    var onCountdownEnd: (() -> Void)?
    var remainingSeconds: TimeInterval {
        max(0, (active?.plannedSeconds ?? 0) - elapsed)
    }
    var remainingFraction: Double {
        guard let planned = active?.plannedSeconds, planned > 0 else { return 0 }
        return min(1, remainingSeconds / planned)
    }
    var store: JournalStore?
    var onActiveChange: ((Bool) -> Void)?
    /// 未写目标或反馈的专注不足这么长（秒）就不留计时记录；默认读设置，测试里可替换。
    var minLoggedSeconds: () -> TimeInterval = { Prefs.focusMinLogSeconds }
    /// 没有授权控制 Safari、只能检测是否离开 Safari 时调用一次（每次专注一次），由界面用提示条告知。
    var onDegraded: (() -> Void)?
    /// 打开链接的动作；测试里替换掉，避免真的启动 Safari。
    var openLink: (URL) -> Void = { SafariLinks.launch($0) }
    /// 页面已在 Safari 里开着时，直接切换到那个标签页（保留滚动位置，不重新加载）。成功返回 true；测试里替换掉。
    var activateExistingTab: (URL) async -> Bool = { await FocusProbe.activateExistingTab(for: $0) }

    private var timer: Timer?
    private var storeSink: AnyCancellable?
    private var awayStreak = 0
    private var baseline: Baseline?
    private var checking = false
    private var learnedBundle: String?
    private var automationDenied = false
    private var pausedAt: Date?
    private var pausedSeconds: TimeInterval = 0

    /// 刚打开页面时留出加载和重定向的时间，期间不判定离开。
    static let grace: TimeInterval = 6
    /// 连续几次（每次 1 秒）不在目标页面才算离开，避免通知、Spotlight 一闪而过造成误判。
    static let awayThreshold = 2

    struct Baseline: Equatable, Sendable { var host: String; var path: String }

    // MARK: - 链接

    /// 任务标题里的第一个网页或本地文件链接。
    static func link(in title: String) -> URL? {
        TaskText.rendered(title).runs.compactMap(\.link).first { $0.isFileURL || ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }

    nonisolated static func baseline(for url: URL) -> Baseline {
        if url.isFileURL { return Baseline(host: "", path: url.standardizedFileURL.path) }
        var host = (url.host ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = url.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return Baseline(host: host, path: path)
    }

    nonisolated static func matches(_ current: URL, _ baseline: Baseline) -> Bool {
        self.baseline(for: current) == baseline
    }

    // MARK: - 开始与结束

    func start(task: ScheduledTask, url: URL?, plannedSeconds: TimeInterval? = nil,
               goal: String = "", now: Date = Date()) {
        guard let store, !store.isReadOnly else { return }
        if active != nil { stop(reason: "切换到了另一个任务", now: now) }
        let number = task.task.number
        active = Active(taskID: task.id, number: number, title: String(TaskText.rendered(task.task.title).characters), url: url,
                        started: now, plannedSeconds: max(60, plannedSeconds ?? TimeInterval(Prefs.focusDurationMinutes()) * 60), goal: goal.trimmingCharacters(in: .whitespacesAndNewlines))
        elapsed = 0
        isPaused = false
        needsReflection = false
        pausedAt = nil
        pausedSeconds = 0
        store.setFocusPaused(false)
        awayStreak = 0
        learnedBundle = nil
        automationDenied = false
        baseline = url.map(Self.baseline(for:))
        active?.startLogID = store.addFocusLog("▶ 开始专注", taskID: task.id, now: now,
                                              event: .start, goal: active?.goal.isEmpty == false ? active?.goal : nil,
                                              plannedSeconds: active?.plannedSeconds)
        store.setFocusTask(task.id)
        // 任务一完成、放弃或删除就立刻结束（不等下一秒的计时）。
        storeSink = store.$days.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = self?.stopIfTaskClosed() } }
        }
        // 已经开着就切过去，不要再打开一次，否则会回到页面开头。没有链接就没有页面可开。
        if let url {
            Task { @MainActor in
                if await activateExistingTab(url) { return }
                openLink(url)
            }
        }
        onActiveChange?(true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop(reason: String, now: Date = Date()) {
        guard let session = active else { return }
        timer?.invalidate()
        timer = nil
        storeSink = nil
        let seconds = effectiveElapsed(at: now)
        let hasReflection = store?.allLogs().contains {
            $0.log.taskID == session.taskID && $0.log.focusEvent == .review && $0.log.createdAt >= session.started
        } == true
        let minimumSeconds = max(0, minLoggedSeconds())
        if seconds < minimumSeconds, session.goal.isEmpty, !hasReflection {
            // 太短且没有目标或反馈：撤掉开始记录、不写结束记录，时间照常累加。
            store?.discardShortFocus(startLogID: session.startLogID, taskID: session.taskID, seconds: seconds, now: now)
        } else {
            let total = (store?.locate(session.taskID)?.task.focusSeconds ?? 0) + seconds
            store?.addFocusLog("■ 结束专注 · 用时 \(Self.duration(seconds)) · 累计 \(Self.duration(total)) · \(reason)",
                               taskID: session.taskID, now: now, seconds: seconds, fallback: (session.title, session.number), event: .end, endReason: reason, minimumSeconds: minimumSeconds)
        }
        store?.setFocusTask(nil)
        active = nil
        elapsed = 0
        isPaused = false
        needsReflection = false
        pausedAt = nil
        pausedSeconds = 0
        baseline = nil
        onActiveChange?(false)
    }

    /// 暂停本轮专注。暂停期间不累加有效专注时间，但任务仍保持专注关联。
    func pause(now: Date = Date()) {
        guard active != nil, !isPaused else { return }
        elapsed = effectiveElapsed(at: now)
        pausedAt = now
        isPaused = true
        store?.setFocusPaused(true)
    }

    /// 继续本轮专注，并扣除暂停期间的时间。
    func resume(now: Date = Date()) {
        guard active != nil, isPaused, !needsReflection else { return }
        if let pausedAt {
            pausedSeconds += max(0, now.timeIntervalSince(pausedAt))
        }
        self.pausedAt = nil
        isPaused = false
        elapsed = effectiveElapsed(at: now)
        store?.setFocusPaused(false)
    }

    func togglePause(now: Date = Date()) {
        if isPaused { resume(now: now) } else { pause(now: now) }
    }

    private func effectiveElapsed(at now: Date) -> TimeInterval {
        guard let session = active else { return 0 }
        let currentlyPaused = pausedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return max(0, now.timeIntervalSince(session.started) - pausedSeconds - currentlyPaused)
    }

    /// 延长当前专注轮次；不改变已经累计的时间。
    func extend(by seconds: TimeInterval, now: Date = Date()) {
        guard let current = active, seconds > 0 else { return }
        active = Active(taskID: current.taskID, number: current.number, title: current.title, url: current.url,
                        started: current.started, plannedSeconds: current.plannedSeconds + seconds, goal: current.goal,
                        startLogID: current.startLogID)
        if needsReflection {
            needsReflection = false
            resume(now: now)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        if h > 0 { return AppLocalizedFormat("%lld 小时 %lld 分 %lld 秒", h, m, s) }
        if m > 0 { return AppLocalizedFormat("%lld 分 %lld 秒", m, s) }
        return AppLocalizedFormat("%lld 秒", s)
    }

    /// 任务行上的累计时长：「1 小时 20 分」「25 分钟」「40 秒」。
    static func brief(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (h, m) = (total / 3600, (total % 3600) / 60)
        if h > 0 { return m > 0 ? AppLocalizedFormat("%lld 小时 %lld 分", h, m) : AppLocalizedFormat("%lld 小时", h) }
        if m > 0 { return AppLocalizedFormat("%lld 分钟", m) }
        return AppLocalizedFormat("%lld 秒", total)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: - 检测

    /// 专注的任务被完成、放弃或删除了：计时没有意义了，自动结束并写明原因。返回是否结束了。
    @discardableResult
    func stopIfTaskClosed(now: Date = Date()) -> Bool {
        guard let session = active, let store else { return false }
        guard let task = store.locate(session.taskID)?.task else { stop(reason: "任务已删除", now: now); return true }
        if task.isDropped { stop(reason: "任务已放弃", now: now); return true }
        if task.isDone { stop(reason: "任务已完成", now: now); return true }
        return false
    }

    func tick(now: Date = Date()) {
        guard let current = active else { return }
        if stopIfTaskClosed(now: now) { return }
        if !isPaused {
            let seconds = effectiveElapsed(at: now)
            if seconds >= current.plannedSeconds {
                // 睡眠唤醒、主线程延迟也只累计到计划终点。
                pause(now: now.addingTimeInterval(-(seconds - current.plannedSeconds)))
                needsReflection = true
                onCountdownEnd?()
            } else {
                elapsed = seconds
            }
        }
        // 专注期间允许自由查资料、切换网页、终端和笔记窗口；链接只负责开始时打开，不再检测前台页面。
    }

    func apply(_ result: FocusProbe.Result, inGrace: Bool) {
        if result.automationDenied, !automationDenied { onDegraded?() }
        automationDenied = result.automationDenied
        // Timeline 自己在前台（在这里记阅读笔记）不算离开：计时照常累计，离开计数清零。
        if result.ownApp {
            awayStreak = 0
            return
        }
        if inGrace {
            // 宽限期内：记住实际打开的页面（可能经过重定向）和应用，之后以它们为准。
            if let page = result.pageURL { baseline = Self.baseline(for: page) }
            if let bundle = result.frontBundle, bundle != Bundle.main.bundleIdentifier { learnedBundle = bundle }
            awayStreak = 0
            return
        }
        if result.onTarget {
            awayStreak = 0
            return
        }
        awayStreak += 1
        if awayStreak >= Self.awayThreshold { stop(reason: result.awayReason) }
    }
}

/// 读取前台应用和 Safari 当前标签页的地址。
@MainActor
enum FocusProbe {
    struct Result {
        var onTarget: Bool
        var awayReason: String
        var frontBundle: String?
        var pageURL: URL?
        var automationDenied: Bool
        /// Timeline 自己在前台。
        var ownApp = false
    }

    static func check(target: URL, baseline: FocusSession.Baseline?, learnedBundle: String?) async -> Result {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let front, front == Bundle.main.bundleIdentifier {
            return Result(onTarget: true, awayReason: "", frontBundle: front, pageURL: nil, automationDenied: false, ownApp: true)
        }
        let usesSafari = SafariLinks.usesSafari(target)
        let expectedBundle = usesSafari ? "com.apple.Safari" : learnedBundle
        // 先看前台应用是不是目标应用。
        if let expectedBundle, front != expectedBundle {
            let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? "其他应用"
            return Result(onTarget: false, awayReason: "切换到了\(name)", frontBundle: front, pageURL: nil, automationDenied: false)
        }
        guard usesSafari else {
            return Result(onTarget: true, awayReason: "", frontBundle: front, pageURL: nil, automationDenied: false)
        }
        // 再看 Safari 当前标签页是不是目标页面。
        switch await safariFrontURL() {
        case .denied:
            return Result(onTarget: true, awayReason: "", frontBundle: front, pageURL: nil, automationDenied: true)
        case .none:
            return Result(onTarget: false, awayReason: "Safari 没有打开的页面", frontBundle: front, pageURL: nil, automationDenied: false)
        case .url(let url):
            let match = baseline.map { FocusSession.matches(url, $0) } ?? true
            return Result(onTarget: match, awayReason: "离开了目标页面", frontBundle: front, pageURL: url, automationDenied: false)
        }
    }

    /// 在所有 Safari 窗口的所有标签页里找到目标页面，切换过去并置前。找不到、Safari 没运行或没有授权时返回 false，由调用方照常打开链接。
    static func activateExistingTab(for target: URL) async -> Bool {
        guard SafariLinks.usesSafari(target),
              !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty else { return false }
        let list = """
        set output to ""
        tell application "Safari"
            repeat with w in windows
                try
                    set wid to id of w
                    repeat with i from 1 to (count of tabs of w)
                        try
                            set u to URL of tab i of w
                            if u is not missing value then set output to output & wid & (ASCII character 9) & i & (ASCII character 9) & u & linefeed
                        end try
                    end repeat
                end try
            end repeat
        end tell
        return output
        """
        let (status, output, _) = await run("/usr/bin/osascript", ["-e", list], timeout: 3)
        guard status == 0, let found = bestTab(in: output, for: target) else { return false }
        let select = """
        tell application "Safari"
            set w to window id \(found.window)
            set current tab of w to tab \(found.tab) of w
            set index of w to 1
            activate
        end tell
        """
        return await run("/usr/bin/osascript", ["-e", select], timeout: 3).0 == 0
    }

    /// 解析「窗口id⇥标签序号⇥网址」逐行输出，返回第一个与目标页面匹配的标签（忽略参数、锚点、www 和末尾斜杠）。
    nonisolated static func bestTab(in output: String, for target: URL) -> (window: Int, tab: Int)? {
        let baseline = FocusSession.baseline(for: target)
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let window = Int(fields[0]), let tab = Int(fields[1]),
                  let url = URL(string: String(fields[2]).trimmingCharacters(in: .whitespaces)),
                  FocusSession.matches(url, baseline) else { continue }
            return (window, tab)
        }
        return nil
    }

    enum SafariURL { case url(URL), none, denied }

    static func safariFrontURL() async -> SafariURL {
        let script = """
        tell application "Safari"
            if (count of windows) is 0 then return ""
            return URL of current tab of front window
        end tell
        """
        let (status, output, error) = await run("/usr/bin/osascript", ["-e", script], timeout: 2)
        if status != 0 {
            // -1743：用户没有授权 Timeline 控制 Safari。
            return error.contains("-1743") || error.contains("not allowed") || error.contains("不允许") ? .denied : .none
        }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = URL(string: text) else { return .none }
        return .url(url)
    }

    private nonisolated static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) async -> (Int32, String, String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do { try process.run() } catch { continuation.resume(returning: (-1, "", error.localizedDescription)); return }
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                let output = out.fileHandleForReading.readDataToEndOfFile()
                let errors = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                continuation.resume(returning: (process.terminationStatus, String(decoding: output, as: UTF8.self), String(decoding: errors, as: UTF8.self)))
            }
        }
    }
}

// MARK: - 专注计时的显示：多种样式，可以隐藏

/// 计时窗口的样式。别人看到屏幕时，越低调越好：从完整的卡片到只有一个小点，或者只放在菜单栏里。
enum FocusPanelStyle: String, CaseIterable, Identifiable {
    case card, pill, digits, dot, menuBar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .card: return "卡片"
        case .pill: return "胶囊"
        case .digits: return "数字"
        case .dot: return "小点"
        case .menuBar: return "菜单栏"
        }
    }

    var detail: String {
        switch self {
        case .card: return "时间、任务名和结束键，最完整"
        case .pill: return "只有时间和结束键，不显示任务名"
        case .digits: return "只有一行淡淡的数字，没有底板"
        case .dot: return "平时只是一个小圆点，鼠标移上去才显示时间"
        case .menuBar: return "不开浮窗，时间显示在菜单栏里"
        }
    }

    /// 浮动窗口的大小；菜单栏样式没有浮动窗口。
    var panelSize: NSSize? {
        switch self {
        case .card, .pill, .digits, .dot: return NSSize(width: 340, height: 158)
        case .menuBar: return nil
        }
    }

    static var current: FocusPanelStyle {
        UserDefaults.standard.string(forKey: Prefs.focusPanelStyle).flatMap(FocusPanelStyle.init(rawValue:)) ?? .card
    }

    static var hidden: Bool { UserDefaults.standard.bool(forKey: Prefs.focusPanelHidden) }

    /// 隐藏 / 显示计时（专注照常进行，日志和累计时间不受影响）。
    static func toggleHidden() { UserDefaults.standard.set(!hidden, forKey: Prefs.focusPanelHidden) }

    /// 浮动窗口要不要显示：专注中、没被隐藏、而且样式有浮窗。
    static func floatingVisible(active: Bool, hidden: Bool, style: FocusPanelStyle) -> Bool {
        active && !hidden && style.panelSize != nil
    }

    /// 专注期间始终显示菜单栏计时，不受浮窗样式或隐藏状态影响。
    static func menuBarVisible(active: Bool, hidden: Bool, style: FocusPanelStyle) -> Bool {
        active
    }
}

private final class FocusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class FocusPanelController: NSObject, NSWindowDelegate {
    private var panel: FocusPanel?
    private var statusItem: NSStatusItem?
    private var workspaceMenuItem: NSMenuItem?
    private var pauseMenuItem: NSMenuItem?
    private let session: FocusSession
    private var observers: [NSObjectProtocol] = []
    private var statusSink: AnyCancellable?
    private let defaults: UserDefaults
    private var workspaceShown = false
    private var refreshing = false

    init(session: FocusSession, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
        super.init()
        session.onActiveChange = { [weak self] active in
            if active { self?.workspaceShown = true }
            self?.refresh()
        }
        session.onCountdownEnd = { [weak self] in
            guard let self else { return }
            refresh()
            if !Headless.active { NSSound(named: "Glass")?.play() }
        }
        // 设置里改了隐藏偏好，立刻生效。
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .appLanguageDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.removeStatusItem()
                self?.refresh()
            }
        })
        // @Published 在赋值前发出新值，直接使用发布的快照，避免计时落后一秒。
        statusSink = Publishers.CombineLatest4(session.$active, session.$elapsed, session.$isPaused, session.$needsReflection)
            .sink { [weak self] active, elapsed, paused, needsReflection in
                self?.updateStatusTitle(active: active, elapsed: elapsed, paused: paused, needsReflection: needsReflection)
            }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// 专注工作台：未专注时显示任务选择器，专注中显示目标与输入栏。
    func refresh() {
        // 字体和系统偏好首次加载会同步发通知，避免创建窗口时重入 SwiftUI 排版。
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let hidden = defaults.bool(forKey: Prefs.focusPanelHidden)
        if workspaceShown && !hidden {
            showPanel(size: panel?.frame.size ?? Self.workspaceSize)
        } else {
            panel?.orderOut(nil)
        }
        if session.active != nil { showStatusItem() } else { removeStatusItem() }
    }

    // 空白输入保持原尺寸，正文输入区最多向下扩展至六行。
    private static let workspaceSize = NSSize(width: 340, height: 158)

    /// 全局快捷键入口：打开 / 收起工作台。专注中再次按下只收起面板，不结束专注。
    @objc func toggleWorkspace() {
        workspaceShown = !(workspaceShown && !defaults.bool(forKey: Prefs.focusPanelHidden))
        if workspaceShown { defaults.set(false, forKey: Prefs.focusPanelHidden) }
        refresh()
    }

    /// 当前显示着什么（测试用）。
    var isPanelVisible: Bool { panel?.isVisible == true }
    /// 菜单栏里该不该有计时（测试环境不真的创建菜单栏项目，免得在用户的菜单栏上闪一下）。
    private(set) var showsMenuBarTimer = false
    private(set) var menuBarTimerTitle = ""

    private func showPanel(size: NSSize) {
        let created = panel == nil
        if panel == nil {
            let host = NSHostingView(rootView: LocalizedRoot {
                FocusPanelView(session: self.session, close: { [weak self] in
                    self?.workspaceShown = false
                    self?.refresh()
                }, resize: { [weak self] height in self?.resize(height: height) })
            })
            host.setFrameSize(size)
            // 不激活的浮动窗口：点它不会抢走前台，否则会被判定为离开目标页面。
            let panel = FocusPanel(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.contentView = host
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.delegate = self
            self.panel = panel
        }
        guard let panel else { return }
        // 第一次显示默认放在当前屏幕右下角；用户拖动后位置会被记住。
        let topLeft: NSPoint
        if created || !panel.isVisible {
            topLeft = savedTopLeft(for: size) ?? defaultTopLeft(for: size)
        } else {
            topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        }
        panel.setFrame(NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height), display: true)
        if Headless.active { panel.alphaValue = 0; panel.ignoresMouseEvents = true }
        panel.orderFrontRegardless()
    }

    private func defaultTopLeft(for size: NSSize) -> NSPoint {
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        return NSPoint(x: frame.maxX - size.width - 18, y: frame.minY + size.height + 18)
    }

    private func resize(height: CGFloat) {
        guard let panel, height >= Self.workspaceSize.height, abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    private func savedTopLeft(for size: NSSize) -> NSPoint? {
        guard let text = defaults.string(forKey: Prefs.focusPanelTopLeft) else { return nil }
        let point = NSPointFromString(text)
        let rect = NSRect(x: point.x, y: point.y - size.height, width: size.width, height: size.height)
        // 保存的位置所在的屏幕还在才用。
        return NSScreen.screens.contains { $0.visibleFrame.intersects(rect) } ? point : nil
    }

    func windowDidMove(_ notification: Notification) {
        guard let frame = panel?.frame, panel?.isVisible == true else { return }
        defaults.set(NSStringFromPoint(NSPoint(x: frame.minX, y: frame.maxY)), forKey: Prefs.focusPanelTopLeft)
    }

    // MARK: 菜单栏

    private func showStatusItem() {
        showsMenuBarTimer = true
        if statusItem == nil, !Headless.active {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.autoenablesItems = false
            let workspace = menu.addItem(withTitle: "", action: #selector(toggleWorkspace), keyEquivalent: "")
            workspace.target = self
            workspaceMenuItem = workspace
            let pause = menu.addItem(withTitle: "", action: #selector(togglePause), keyEquivalent: "")
            pause.target = self
            pauseMenuItem = pause
            menu.addItem(.separator())
            let stop = menu.addItem(withTitle: AppLocalized("结束专注"), action: #selector(stopFocus), keyEquivalent: "")
            stop.target = self
            item.menu = menu
            item.button?.imagePosition = .imageLeading
            statusItem = item
        }
        workspaceMenuItem?.title = AppLocalized(workspaceShown && !defaults.bool(forKey: Prefs.focusPanelHidden) ? "隐藏专注工作台" : "显示专注工作台")
        updateStatusTitle(active: session.active, elapsed: session.elapsed, paused: session.isPaused, needsReflection: session.needsReflection)
    }

    private func removeStatusItem() {
        showsMenuBarTimer = false
        menuBarTimerTitle = ""
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        workspaceMenuItem = nil
        pauseMenuItem = nil
    }

    private func updateStatusTitle(active: FocusSession.Active?, elapsed: TimeInterval, paused: Bool, needsReflection: Bool) {
        guard let active else { menuBarTimerTitle = ""; return }
        menuBarTimerTitle = FocusSession.clock(max(0, active.plannedSeconds - elapsed))
        pauseMenuItem?.title = AppLocalized(paused ? "继续" : "暂停")
        pauseMenuItem?.isEnabled = !needsReflection
        guard let button = statusItem?.button else { return }
        let symbol = needsReflection ? "checkmark.bubble" : (paused ? "pause.circle" : "timer")
        let state = AppLocalized(needsReflection ? "阶段反馈" : (paused ? "Paused" : "专注中"))
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: state)
        button.attributedTitle = NSAttributedString(string: " " + menuBarTimerTitle,
                                                    attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)])
        button.toolTip = state + " · " + (active.number.map { "#\($0) " } ?? "") + active.title
        button.setAccessibilityLabel(state + " · " + menuBarTimerTitle)
    }

    @objc private func stopFocus() { session.stop(reason: "手动结束") }
    @objc private func togglePause() { session.togglePause() }
}

@MainActor
final class FocusNoteDraft: ObservableObject {
    @Published var text = ""
    @Published var images: [String] = []
    @Published var link: UUID?
    @Published var tags: [String] = []
    @Published private(set) var error: String?
    @Published private(set) var pendingEntryID: UUID?

    @discardableResult
    func save(session: FocusSession, reflection: Bool = false) -> Bool {
        guard let store = session.store else { return false }
        if let pendingEntryID, store.allLogs().contains(where: { $0.log.id == pendingEntryID }) {
            store.save()
            if store.hasPendingSave {
                error = AppLocalized("未能写入磁盘，输入已保留。请检查磁盘空间或权限后再次发送以重试。")
            } else {
                clear()
                ImageIndexer.run(store: store)
            }
            return !store.hasPendingSave
        }
        pendingEntryID = nil
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!body.isEmpty || !images.isEmpty), let active = session.active else { return false }
        do {
            let text = reflection ? "/note " + body : body
            let result = try store.quickLogEntry(text, images: images,
                                                taskID: reflection ? active.taskID : (session.isPaused ? nil : (link ?? active.taskID)),
                                                linkDefault: false, tags: session.isPaused ? [] : tags,
                                                allowInlineTaskReference: !reflection && !session.isPaused, on: Date(),
                                                focusEvent: reflection ? .review : nil,
                                                focusGoal: reflection ? active.goal : nil,
                                                focusPlannedSeconds: reflection ? active.plannedSeconds : nil)
            guard let entry = result.entry else {
                error = AppLocalized("这里只能写笔记，请使用普通文字或 /note /done /block /plan。")
                return false
            }
            if store.hasPendingSave {
                pendingEntryID = entry.id
                error = AppLocalized("未能写入磁盘，输入已保留。请检查磁盘空间或权限后再次发送以重试。")
                return false
            }
            clear()
            ImageIndexer.run(store: store)
            return true
        } catch {
            self.error = AppErrorDescription(error)
            return false
        }
    }

    private func clear() {
        text = ""
        images = []
        link = nil
        tags = []
        error = nil
        pendingEntryID = nil
    }
}

/// 与数字倒计时共享进度，不单独启动计时器；表盘从十二点开始顺时针消退。
private struct FocusCountdownDial: View {
    let fraction: Double
    let paused: Bool

    private var color: Color { paused ? Palette.muted : Palette.accent }

    var body: some View {
        ZStack {
            Circle().stroke(Palette.muted.opacity(0.18), lineWidth: 1)
            Circle().trim(from: 1 - fraction, to: 1)
                .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Capsule().fill(color).frame(width: 1.2, height: 7)
                .offset(y: -3.5)
                .rotationEffect(.degrees((1 - fraction) * 360))
            Circle().fill(color).frame(width: 2.5, height: 2.5)
        }
        .padding(1)
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct FocusPanelView: View {
    @ObservedObject private var languages = LanguageStore.shared
    @ObservedObject var session: FocusSession
    let close: () -> Void
    let resize: (CGFloat) -> Void
    @State private var selectedTaskID: UUID?
    @AppStorage(Prefs.focusDefaultMinutes) private var defaultMinutes = Prefs.defaultFocusMinutes
    @AppStorage(Prefs.taskSortMode) private var taskSort = TaskSortMode.deadline.rawValue
    @State private var minutes: String
    @State private var goal = ""
    @State private var query = ""
    @State private var showingTaskPicker = false
    @State private var focused = true
    @State private var showingSaveError = false
    @StateObject private var draft = FocusNoteDraft()
    @StateObject private var reflectionDraft = FocusNoteDraft()
    @StateObject private var mention = MentionState()

    init(session: FocusSession, close: @escaping () -> Void = {}, resize: @escaping (CGFloat) -> Void = { _ in }) {
        self.session = session
        self.close = close
        self.resize = resize
        _minutes = State(initialValue: String(Prefs.focusDurationMinutes()))
    }

    private var store: JournalStore? { session.store }
    private var tasks: [ScheduledTask] {
        let all = (TaskSortMode(rawValue: taskSort) ?? .deadline).sorted(store?.tasks() ?? []).filter { !$0.task.completed }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        return all.filter { item in
            let title = String(TaskText.rendered(item.task.title).characters)
            return title.localizedCaseInsensitiveContains(q) || "#\(item.task.number ?? 0)".contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule().fill(Palette.line).frame(width: 36, height: 4).frame(maxWidth: .infinity)
                .padding(.bottom, 12)
            if let active = session.active {
                if session.needsReflection { reflectionView(active) } else { activeView(active) }
            } else { pickerView }
        }
        .padding(11)
        .frame(width: 340, alignment: .leading)
        .frame(minHeight: 158, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line))
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .background(GeometryReader { proxy in Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height) })
        .onPreferenceChange(PanelHeightKey.self, perform: resize)
        .onAppear {
            configureMention()
            if selectedTaskID == nil { selectedTaskID = tasks.first?.id }
        }
        .onChange(of: defaultMinutes) { _ in
            if session.active == nil { minutes = String(Prefs.focusDurationMinutes()) }
        }
        .onChange(of: session.active?.taskID) { id in
            if id == nil { minutes = String(Prefs.focusDurationMinutes()) }
        }
        .onChange(of: session.needsReflection) { needsReflection in
            if needsReflection { focused = true }
        }
    }

    private var clock: String { FocusSession.clock(session.elapsed) }

    private var pickerView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "timer.circle.fill").font(.system(size: 17)).foregroundStyle(Palette.success)
                Text("开始专注").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(HitAreaButtonStyle(compact: true))
                    .foregroundStyle(Palette.muted)
            }
            Button { showingTaskPicker = true } label: {
                HStack(spacing: 7) {
                    if let selected = selectedTask {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success)
                        Text("#\(selected.task.number ?? 0)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                        PriorityMark(priority: selected.task.priority)
                        Text(String(TaskText.rendered(selected.task.title).characters)).lineLimit(1)
                        Spacer(minLength: 0)
                        dueText(for: selected)
                    } else {
                        Image(systemName: "circle").foregroundStyle(Palette.muted)
                        Text("选择一个任务").foregroundStyle(Palette.muted)
                        Spacer()
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Palette.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
            }
            .buttonStyle(.plain)
            .raisedOnHover(radius: 8)
            .popover(isPresented: $showingTaskPicker, arrowEdge: .bottom) {
                taskPicker
            }
            HStack(spacing: 7) {
                Label("时长", systemImage: "clock").font(.system(size: 11)).foregroundStyle(Palette.muted)
                TextField(String(Prefs.focusDurationMinutes()), text: $minutes).textFieldStyle(.roundedBorder).frame(width: 52)
                Text("分钟").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
            }
            HStack(spacing: 7) {
                Image(systemName: "flag.fill").font(.system(size: 11)).foregroundStyle(Palette.accent)
                TextField("本轮目标（可选）", text: $goal).textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                Button("开始专注") { startFocus() }
                    .buttonStyle(HitAreaButtonStyle())
                    .foregroundStyle(Palette.accent)
                    .keyboardShortcut(.return)
                    .disabled(selectedTaskID == nil || positiveMinutes == nil)
            }
        }
    }

    private var selectedTask: ScheduledTask? {
        guard let selectedTaskID else { return nil }
        return store?.locate(selectedTaskID)
    }

    private var taskPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checklist").foregroundStyle(Palette.accent)
                Text("选择专注任务").font(.headline)
                Spacer()
            }
            TextField("搜索标题或编号…", text: $query)
                .textFieldStyle(.roundedBorder)
            if tasks.isEmpty {
                Text(query.isEmpty ? "没有未完成的待办" : "没有匹配的任务")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(tasks) { item in taskButton(item) }
                    }
                }
                .frame(height: min(CGFloat(tasks.count) * 34 + 4, 260))
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private func taskButton(_ item: ScheduledTask) -> some View {
        Button {
            selectedTaskID = selectedTaskID == item.id ? nil : item.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selectedTaskID == item.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedTaskID == item.id ? Palette.success : Palette.muted)
                Text("#\(item.task.number ?? 0)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                PriorityMark(priority: item.task.priority)
                Text(String(TaskText.rendered(item.task.title).characters)).lineLimit(1)
                Spacer(minLength: 0)
                dueText(for: item)
                if item.id == store?.pinnedTask?.id { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Palette.accent) }
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(selectedTaskID == item.id ? Palette.soft : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .raisedOnHover(radius: 8)
    }

    @ViewBuilder
    private func dueText(for item: ScheduledTask) -> some View {
        if let due = item.task.dueDate {
            Text(dueLabel(for: item.task, due: due))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isOverdue(item.task) ? Palette.deadline : (JournalDates.calendar.isDateInToday(due) ? Palette.accent : Palette.muted))
                .lineLimit(1).fixedSize()
        }
    }

    private func activeView(_ active: FocusSession.Active) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "timer.circle.fill").font(.system(size: 17)).foregroundStyle(Palette.success)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.isPaused ? "Paused" : "专注中")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(session.isPaused ? Palette.deadline : Palette.success)
                    Text(active.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 7) {
                    FocusCountdownDial(fraction: session.remainingFraction, paused: session.isPaused)
                    Text(FocusSession.clock(session.remainingSeconds))
                        .font(.system(size: 18, weight: .semibold, design: .monospaced)).monospacedDigit()
                }
                .fixedSize()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(HitAreaButtonStyle(compact: true))
                    .foregroundStyle(Palette.muted)
            }
            .frame(height: 28)
            HStack(spacing: 6) {
                if !active.goal.isEmpty {
                    Label(active.goal.replacingOccurrences(of: "\n", with: " "), systemImage: "flag.fill")
                        .lineLimit(1).truncationMode(.tail).help(active.goal)
                }
                if draft.link != nil || !draft.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            if let link = draft.link, let linked = store?.locate(link) {
                                Text(FocusHint.label(linked)).lineLimit(1)
                                Button { draft.link = nil } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain)
                            }
                            ForEach(draft.tags, id: \.self) { tag in Text("#" + tag) }
                        }
                    }
                    .disabled(draft.pendingEntryID != nil)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10)).foregroundStyle(Palette.accent)
            .frame(height: 14)
            HStack(spacing: 8) {
                Image(systemName: "chevron.right.2").foregroundStyle(Palette.accent)
                HStack(spacing: 5) {
                    if !draft.images.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(draft.images, id: \.self) { name in
                                    PastedImageToken { draft.images.removeAll { $0 == name } }
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                        .frame(width: 124, height: 28)
                    }
                    TaskInput(text: $draft.text, focused: $focused,
                              placeholder: "记下想法…",
                              fontSize: 12, submit: saveNote, cancel: close,
                              onPasteImages: addNoteImages, minHeight: 24, maxLines: 6,
                              mention: mention, returnSubmits: true)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minWidth: 0, maxWidth: .infinity)
                }
                .disabled(draft.pendingEntryID != nil)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .frame(minHeight: 32)
                .background(Palette.background, in: RoundedRectangle(cornerRadius: 9))
                .popover(isPresented: Binding(get: { mention.isActive }, set: { if !$0 { mention.dismiss() } }), arrowEdge: .bottom) {
                    if let store { MentionList(state: mention, store: store, contextTags: draft.tags).frame(width: 320) }
                }
                if let store {
                    VStack(spacing: 0) {
                        TagSelectionButton(store: store, tags: $draft.tags)
                        LinkPickerButton(store: store, current: draft.link ?? session.active?.taskID,
                                         allowsNone: false, pick: { draft.link = $0 }) { MetadataSymbol(symbol: "@", active: draft.link != nil) }
                            .raisedOnHover(radius: 5)
                            .help("选择关联的待办").accessibilityLabel("选择关联的待办")
                    }
                    .frame(height: 42)
                    .disabled(session.isPaused || draft.pendingEntryID != nil)
                }
                Button(action: saveNote) {
                    Image(systemName: draft.pendingEntryID == nil ? "arrow.up.circle.fill" : "arrow.clockwise.circle.fill")
                        .font(.system(size: 18))
                }
                .buttonStyle(HitAreaButtonStyle(compact: true))
                .foregroundStyle(Palette.accent)
                .help(draft.pendingEntryID == nil ? "保存" : "重试保存")
                .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.images.isEmpty)
            }
            .frame(minHeight: 42)
            HStack(spacing: 4) {
                if let error = draft.error {
                    Button { showingSaveError.toggle() } label: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .buttonStyle(HitAreaButtonStyle(compact: true))
                    .foregroundStyle(Palette.deadline)
                    .help(error).accessibilityLabel("保存失败")
                    .popover(isPresented: $showingSaveError) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("保存失败").font(.headline)
                            Text(error).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14).frame(width: 280)
                    }
                } else {
                    Text("已用 \(FocusSession.clock(session.elapsed))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.muted).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                Button { session.togglePause() } label: {
                    Label(session.isPaused ? "继续" : "暂停", systemImage: session.isPaused ? "play.fill" : "pause.fill")
                        .frame(minWidth: 48, minHeight: 22)
                }
                .buttonStyle(HitAreaButtonStyle(pressedScale: 0.98))
                .foregroundStyle(Palette.accent)
                Button { session.extend(by: 5 * 60) } label: {
                    Text("+5min").frame(minWidth: 48, minHeight: 22)
                }
                .buttonStyle(HitAreaButtonStyle(pressedScale: 0.98))
                .foregroundStyle(Palette.accent)
                Button(role: .destructive) { session.stop(reason: "手动结束") } label: {
                    Text("结束").frame(minWidth: 48, minHeight: 22)
                }
                .buttonStyle(HitAreaButtonStyle(pressedScale: 0.98))
                .foregroundStyle(.red)
            }
            .font(.system(size: 11, weight: .medium))
            .frame(height: 30)
        }
        .frame(minHeight: 120, alignment: .top)
    }

    private func reflectionView(_ active: FocusSession.Active) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle").foregroundStyle(Palette.success)
                Text("阶段反馈").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(FocusSession.brief(session.elapsed)).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }.frame(height: 22)
            Text(active.goal.isEmpty ? active.title : active.goal)
                .font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                .frame(height: 14)
            TaskInput(text: $reflectionDraft.text, focused: $focused,
                      placeholder: "完成了什么？下一步是什么？", fontSize: 12,
                      submit: saveReflection, cancel: close, minHeight: 24, maxLines: 6, returnSubmits: true)
                .fixedSize(horizontal: false, vertical: true)
                .disabled(reflectionDraft.pendingEntryID != nil)
                .padding(.horizontal, 9).padding(.vertical, 4).frame(minHeight: 32)
                .background(Palette.background, in: RoundedRectangle(cornerRadius: 9))
            HStack(spacing: 3) {
                if let error = reflectionDraft.error {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.deadline)
                        .help(error).accessibilityLabel(error)
                }
                Button("跳过") { session.stop(reason: "计时结束") }
                    .disabled(reflectionDraft.pendingEntryID != nil)
                Spacer(minLength: 0)
                Button("+5min") { session.extend(by: 300) }
                Button("保存并结束", action: saveReflection)
                    .foregroundStyle(Palette.accent)
                    .disabled(reflectionDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .buttonStyle(HitAreaButtonStyle(compact: true, pressedScale: 0.98))
            .font(.system(size: 11, weight: .medium)).frame(height: 26)
        }.frame(minHeight: 120, alignment: .top)
    }

    private func saveReflection() {
        if reflectionDraft.save(session: session, reflection: true) {
            session.stop(reason: "计时结束")
        }
    }

    private var positiveMinutes: Double? { Double(minutes.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isFinite && $0 > 0 && $0 <= Double(Int.max / 60) ? $0 : nil } }

    private func isOverdue(_ task: Todo) -> Bool {
        !task.completed && task.effectiveDeadline.map { $0 < Date() } == true
    }

    private func dueLabel(for task: Todo, due: Date) -> String {
        var label = due.relativeLabel
        if task.dueHasTime {
            let parts = JournalDates.calendar.dateComponents([.hour, .minute], from: due)
            label += String(format: " %02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        }
        return label
    }

    private func startFocus() {
        guard let id = selectedTaskID, let task = store?.locate(id), let value = positiveMinutes else { return }
        session.start(task: task, url: FocusSession.link(in: task.task.title), plannedSeconds: value * 60, goal: goal)
        focused = true
    }

    private func configureMention() {
        mention.triggers = [.task, .tag]
        guard let store else { return }
        mention.provider = MentionProviders.make(store: store)
        mention.onPick = { item in
            switch item {
            case .task(let task): draft.link = task.id
            case .tag(let tag): draft.tags = TagText.merge(draft.tags, [tag.name])
            }
        }
    }

    private func addNoteImages(_ datas: [Data]) {
        guard let store else { return }
        guard draft.pendingEntryID == nil else { return }
        draft.images += ImageTools.save(datas, in: store)
        focused = true
    }

    private func saveNote() {
        draft.save(session: session)
    }
}

/// 专注输入框里的紧凑图片占位符：图片仍保存在草稿中，但不渲染缩略图，避免撑高固定面板。
private struct PastedImageToken: View {
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "photo.fill").font(.system(size: 10, weight: .semibold))
            Text("[Pasted Image]").font(.system(size: 10, weight: .semibold, design: .monospaced))
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help("移除已粘贴的图片")
        }
        .foregroundStyle(Palette.accent)
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(Palette.soft, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.25), lineWidth: 0.7))
    }
}

/// 截止日期下方的专注入口：播放 / 结束状态和累计时间共用一个按钮。
struct TaskFocusButton: View {
    @Environment(\.typography) private var typography
    @ObservedObject var session: FocusSession
    let task: ScheduledTask
    private var running: Bool { session.active?.taskID == task.id }
    private var total: TimeInterval { task.task.focusSeconds + (running ? session.elapsed : 0) }

    var body: some View {
        Button {
            if running { session.stop(reason: "手动结束") }
            else { session.start(task: task, url: FocusSession.link(in: task.task.title)) }
        } label: {
            ZStack {
                Text(running ? FocusSession.clock(total) : FocusSession.brief(total))
                    .font(.system(size: typography.pt(11), design: .monospaced)).monospacedDigit()
                    .padding(.horizontal, 22)
                HStack {
                    Image(systemName: running ? "stop.fill" : "play.fill")
                        .font(.system(size: typography.pt(10)))
                    Spacer(minLength: 0)
                }.padding(.leading, 6)
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: typography.pt(68), minHeight: typography.pt(28))
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain).raisedOnHover(radius: 4)
        .foregroundStyle(running ? Color.red : Palette.muted)
        .help(running ? "结束专注计时" : "开始专注")
        .accessibilityLabel(running ? "结束专注计时" : "开始专注")
        .accessibilityValue(FocusSession.duration(total))
        .accessibilityIdentifier("task-focus-" + task.id.uuidString)
        .disabled(task.task.completed && !running)
    }
}
