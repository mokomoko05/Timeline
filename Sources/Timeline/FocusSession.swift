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

    deinit { timer?.invalidate() }

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
        // 计时按实际时间计算，晚一点触发不影响读数；允许系统合并唤醒以省电。
        timer?.tolerance = 0.15
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

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

final class FocusPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// 系统的背景拖动由窗口服务器执行，拖动中改不了位置；自己跟着鼠标移动，才能让窗口始终留在屏幕里。
    private var drag: (mouse: NSPoint, origin: NSPoint, moving: Bool)?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            drag = nil
            if let content = contentView,
               let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)),
               hit.mouseDownCanMoveWindow {
                drag = (NSEvent.mouseLocation, frame.origin, false)
            }
        case .leftMouseDragged:
            if var current = drag {
                let mouse = NSEvent.mouseLocation
                let dx = mouse.x - current.mouse.x, dy = mouse.y - current.mouse.y
                if !current.moving && hypot(dx, dy) < 3 { break }
                current.moving = true
                drag = current
                var target = frame
                target.origin = NSPoint(x: current.origin.x + dx, y: current.origin.y + dy)
                let visible = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }?.visibleFrame
                    ?? screen?.visibleFrame
                if let visible { target = Self.clamp(target, to: visible) }
                if target.origin != frame.origin { setFrameOrigin(target.origin) }
                return
            }
        case .leftMouseUp:
            if let current = drag {
                drag = nil
                // 拖动过就不让按下处的按钮被当成点击：把松手位置挪到窗口外。
                if current.moving,
                   let cancel = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -10_000, y: -10_000),
                                                   modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                                   windowNumber: event.windowNumber, context: nil,
                                                   eventNumber: event.eventNumber, clickCount: event.clickCount,
                                                   pressure: event.pressure) {
                    super.sendEvent(cancel)
                    return
                }
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    /// 按记下的位置摆一个新尺寸的面板：在屏幕右半边就保持右边不动，否则保持左边；底边始终不动。
    static func restored(_ saved: NSRect, size: NSSize, in visible: NSRect) -> NSRect {
        let x = saved.midX >= visible.midX ? saved.maxX - size.width : saved.minX
        return NSRect(x: x, y: saved.minY, width: size.width, height: size.height)
    }

    /// 把窗口整个放进屏幕可见区域；窗口比屏幕还大时贴住左上角。
    static func clamp(_ frame: NSRect, to visible: NSRect) -> NSRect {
        var frame = frame
        frame.origin.x = max(min(frame.origin.x, visible.maxX - frame.width), visible.minX)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        return frame
    }
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
    private var panelHidden: Bool

    init(session: FocusSession, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
        panelHidden = defaults.bool(forKey: Prefs.focusPanelHidden)
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
            // 笔记导航、窗口位置等也会发偏好通知，不能在它们的布局过程中重排窗口。
            MainActor.assumeIsolated {
                guard let self else { return }
                let hidden = self.defaults.bool(forKey: Prefs.focusPanelHidden)
                guard hidden != self.panelHidden else { return }
                self.panelHidden = hidden
                Task { @MainActor [weak self] in self?.refresh() }
            }
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
        panelHidden = hidden
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
            let content = FocusPanelView(session: session, close: { [weak self] in
                    self?.workspaceShown = false
                    self?.refresh()
                }, resize: { [weak self] size in self?.resize(to: size) })
            let host = NSHostingView(rootView: LocalizedRoot { content })
            // 窗口大小和位置只由 resize(to:) 决定（收起时要贴边）；宿主视图自己改窗口大小会保留原来的左边，
            // 小胶囊就停在面板原来的位置上。
            host.sizingOptions = []
            host.setFrameSize(size)
            // 不激活的浮动窗口：点它不会抢走前台，否则会被判定为离开目标页面。
            let panel = FocusPanel(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.contentView = host
            panel.isOpaque = false
            panel.backgroundColor = .clear
            // 面板近乎全透明：窗口阴影会透出一圈暗影，只用细边勾出轮廓。
            panel.hasShadow = false
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            // 拖动由 FocusPanel 自己处理，好把窗口限制在屏幕内。
            panel.isMovableByWindowBackground = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.delegate = self
            self.panel = panel
        }
        guard let panel else { return }
        // 第一次显示默认放在当前屏幕右下角；用户拖动后位置会被记住。
        var frame: NSRect
        if created || !panel.isVisible {
            frame = savedFrame(for: size) ?? defaultFrame(for: size)
        } else {
            frame = NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
        }
        // 保存的位置可能只有一部分还在屏幕上（换了显示器、分辨率变了），整个挪回屏幕里。
        let screen = NSScreen.screens.max { $0.visibleFrame.intersection(frame).area < $1.visibleFrame.intersection(frame).area }
        if let visible = (screen ?? NSScreen.main)?.visibleFrame { frame = FocusPanel.clamp(frame, to: visible) }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if Headless.active { panel.alphaValue = 0; panel.ignoresMouseEvents = true }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// 默认贴在屏幕右下角：靠右边、靠底边。
    private func defaultFrame(for size: NSSize) -> NSRect {
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        return NSRect(x: frame.maxX - size.width - Self.edgeInset, y: frame.minY + Self.edgeInset, width: size.width, height: size.height)
    }

    /// 收起时贴着屏幕边缘的距离。
    private static let edgeInset: CGFloat = 6

    private var shrinkTask: Task<Void, Never>?

    /// 内容大小变了。变大时窗口先一步变大，内容在里面从角上展开；变小时等收起动画放完再缩窗口，
    /// 这样窗口的突变永远发生在看不见的透明区域，衔接是连续的。
    private func resize(to size: CGSize) {
        shrinkTask?.cancel()
        guard let panel else { return }
        let smaller = size.width < panel.frame.width - 0.5 || size.height < panel.frame.height - 40
        if smaller && !Headless.active {
            shrinkTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(420))
                guard !Task.isCancelled else { return }
                self?.applyFrame(size)
            }
        } else {
            applyFrame(size)
        }
    }

    /// 收起时贴到离得近的那条屏幕左 / 右边缘；展开时从那条边向内展开，底边不动。
    private func applyFrame(_ size: CGSize) {
        guard let panel, size.width > 40, size.height > 30 else { return }
        let screen = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let compact = size.width < Self.workspaceSize.width - 20
        let dockedRight = panel.frame.midX >= screen.midX
        var frame = panel.frame
        frame.size = size
        if compact {
            // 小伙伴靠边：左半边就贴左边，右半边就贴右边。
            frame.origin.x = dockedRight ? screen.maxX - size.width - Self.edgeInset : screen.minX + Self.edgeInset
        } else {
            // 完整面板从所贴的那条边向内展开，保持在屏幕里。
            frame.origin.x = dockedRight ? panel.frame.maxX - size.width : panel.frame.minX
            frame.origin.x = min(max(frame.origin.x, screen.minX + Self.edgeInset), screen.maxX - size.width - Self.edgeInset)
        }
        frame.origin.y = min(max(panel.frame.minY, screen.minY + Self.edgeInset), screen.maxY - size.height)
        frame = FocusPanel.clamp(frame, to: screen)
        if FocusDock.shared.right != dockedRight { FocusDock.shared.right = dockedRight }
        guard frame.integral != panel.frame.integral else { return }
        // 窗口变大后、内容重新排版前，画面里的内容会先贴着窗口顶部闪一帧。
        // 不立即重画，并让屏幕等到这一轮排版完成再刷新，看到的直接是排好的样子。
        panel.disableScreenUpdatesUntilFlush()
        panel.setFrame(frame, display: false)
        panel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
    }

    private func savedFrame(for size: NSSize) -> NSRect? {
        guard let text = defaults.string(forKey: Prefs.focusPanelFrame) else { return nil }
        let saved = NSRectFromString(text)
        // 保存的位置所在的屏幕还在才用。
        guard saved.width > 0, let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(saved) }) else { return nil }
        return FocusPanel.restored(saved, size: size, in: screen.visibleFrame)
    }

    func windowDidMove(_ notification: Notification) {
        guard let frame = panel?.frame, panel?.isVisible == true else { return }
        let position = NSStringFromRect(frame)
        if defaults.string(forKey: Prefs.focusPanelFrame) != position {
            defaults.set(position, forKey: Prefs.focusPanelFrame)
        }
        // 小伙伴被拖到中间松手后，滑回离得近的那条边（上下位置保留）。
        guard !snapping else { return }
        snapTask?.cancel()
        snapTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            self?.snapToEdge()
        }
    }

    private var snapTask: Task<Void, Never>?
    private var snapping = false

    private func snapToEdge() {
        guard let panel, panel.isVisible, panel.frame.width < Self.workspaceSize.width - 20,
              NSEvent.pressedMouseButtons == 0 else { return }
        let screen = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        var frame = panel.frame
        let right = frame.midX >= screen.midX
        frame.origin.x = right ? screen.maxX - frame.width - Self.edgeInset : screen.minX + Self.edgeInset
        if FocusDock.shared.right != right { FocusDock.shared.right = right }
        frame.origin.y = min(max(frame.minY, screen.minY + Self.edgeInset), screen.maxY - frame.height)
        guard abs(frame.minX - panel.frame.minX) > 0.5 || abs(frame.minY - panel.frame.minY) > 0.5 else { return }
        snapping = true
        if Motion.reduced || Headless.active {
            panel.setFrame(frame, display: true)
            snapping = false
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.snapping = false }
            })
        }
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
            // 专注笔记要确认已落盘才清空输入：同步写入（排在后台写入之后）。
            store.save()
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
    let resize: (CGSize) -> Void
    @State private var selectedTaskID: UUID?
    /// 专注进行中默认收成一个半透明的小伙伴，悬停、点击或正在输入时展开成完整面板。
    @AppStorage(Prefs.focusCompanion) private var companionEnabled = true
    @State private var expanded = false
    @State private var collapseTask: Task<Void, Never>?
    /// 设计预览用：测试环境里也显示收起的样子。
    var previewCompanion = false
    /// 离屏探测用：测试环境里让真实的控制器也走收起流程。
    static var allowCompanionInTests = false
    @AppStorage(Prefs.focusDefaultMinutes) private var defaultMinutes = Prefs.defaultFocusMinutes
    @AppStorage(Prefs.taskSortMode) private var taskSort = TaskSortMode.deadline.rawValue
    @State private var minutes: String
    @State private var goal = ""
    @State private var query = ""
    @State private var focused = true
    @State private var showingSaveError = false
    @StateObject private var draft = FocusNoteDraft()
    @StateObject private var reflectionDraft = FocusNoteDraft()
    @StateObject private var mention = MentionState()

    init(session: FocusSession, close: @escaping () -> Void = {}, resize: @escaping (CGSize) -> Void = { _ in }) {
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

    /// 只有专注进行中、没在写反馈、没在输入时才收起；测试环境始终展开，便于检查面板内容。
    private var showsCompanion: Bool {
        guard companionEnabled, !expanded, !Headless.active || previewCompanion || Self.allowCompanionInTests,
              let _ = session.active, !session.needsReflection else { return false }
        // 有没发出去的笔记就保持展开，免得输入到一半被收起。
        return draft.text.isEmpty && draft.images.isEmpty
    }

    /// 面板贴在屏幕哪一边：变形时以那一边的下角为锚点，胶囊和完整面板都从同一个角长出来 / 收回去。
    @ObservedObject private var dock = FocusDock.shared
    /// 小伙伴是固定的形状；完整面板宽度固定，只量高度（输入变高时会变）。
    static let companionSize = CGSize(width: 214, height: 46)
    @State private var panelHeight: CGFloat = 158
    /// 手动展开后不因鼠标离开而收起；手动收起后，鼠标离开再回来之前不因悬停而展开。
    @State private var pinnedOpen = false
    @State private var hoverSuppressed = false
    /// 选任务时，时间轴在玻璃面板上方展开；选好后收起，任务放进面板里的槽。
    @State private var picking = true
    /// 设计预览用：一开始就是选好、时间轴收起的样子。
    var previewPicked = false
    /// 离屏探测用：从外部切换时间轴的展开 / 收起。
    static let probeTogglePicking = PassthroughSubject<Void, Never>()

    private var anchor: Alignment { dock.right ? .bottomTrailing : .bottomLeading }
    /// 选任务阶段（还没开始专注、有未完成的待办）：时间轴的位置一直留着。
    private var reservesRail: Bool { session.active == nil && !openTasks.isEmpty }
    /// 时间轴浮层展开着。
    private var showsRail: Bool { reservesRail && picking }
    /// 全部未完成的待办（不受搜索影响）：浮层的高度按它算，搜索时高度不变、窗口不跟着缩放。
    private var openTasks: [ScheduledTask] { store?.tasks().filter { !$0.task.completed } ?? [] }
    /// 浮层高度：内容有多少给多少，最多一屏的一半左右；超过就在里面滚动。
    private var railHeight: CGFloat {
        let all = openTasks
        let groups = Set(all.map { $0.task.dueDate.map { JournalDates.key($0) } ?? "undated" }).count
        let content = CGFloat(all.count * 26 + groups * 20) + 40
        return min(max(content, 110), 360)
    }
    /// 窗口要容纳的总大小。选任务时（还没开始专注）始终给浮层留好位置：展开、收起时间轴都不改窗口大小，
    /// 面板就不会跳；留出的地方是全透明的，不挡桌面。
    private var windowSize: CGSize {
        let glass = targetSize
        guard reservesRail else { return glass }
        return CGSize(width: max(glass.width, 340), height: glass.height + railHeight + 8)
    }

    private func pickTask(_ id: UUID) {
        selectedTaskID = id
        // 先让选中的底色出现一下，再收起时间轴，选择有被看到的反馈。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            withAnimation(Motion.reduced ? nil : .spring(response: 0.34, dampingFraction: 0.88)) { picking = false }
        }
    }
    private var unitAnchor: UnitPoint { dock.right ? .bottomTrailing : .bottomLeading }
    private var targetSize: CGSize { showsCompanion ? Self.companionSize : CGSize(width: 340, height: panelHeight) }

    var body: some View {
        let size = targetSize
        let radius: CGFloat = showsCompanion ? 23 : Metrics.radiusPanel
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let rail = showsRail
        let reserved = reservesRail
        VStack(alignment: dock.right ? .trailing : .leading, spacing: reserved ? 8 : 0) {
            if reserved {
                // 时间轴不在玻璃里：浮在面板上方，可以上下滚动整条线。
                // 它的位置一直留着；展开时从面板的上边框向上「抽」出来（遮罩自下而上打开），收起时缩回上边框。
                FocusTimelineRail(tasks: timelineTasks, selected: selectedTaskID, pinned: store?.pinnedTask?.id,
                                  query: $query, height: railHeight, select: pickTask)
                    .frame(width: 340, height: railHeight)
                    .opacity(rail ? 1 : 0)
                    .offset(y: rail ? 0 : 14)
                    .mask(alignment: .bottom) {
                        Rectangle().frame(height: rail ? railHeight + 20 : 0)
                    }
                    .allowsHitTesting(rail)
                    .accessibilityHidden(!rail)
            }
        ZStack(alignment: anchor) {
            if showsCompanion, let active = session.active {
                FocusCompanion(session: session, title: active.title, expand: manualExpand)
                    .modifier(LegibilityShadow())
                    .frame(width: Self.companionSize.width, height: Self.companionSize.height)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: unitAnchor)))
            } else {
                fullPanel
                    .modifier(LegibilityShadow())
                    .fixedSize()
                    .background(GeometryReader { Color.clear.preference(key: FocusPanelSizeKey.self, value: $0.size) })
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: unitAnchor)))
            }
        }
        // 同一块玻璃在两种大小之间连续变形；内容按它裁切，看起来是从贴边的那个角展开、收回。
        .frame(width: size.width, height: size.height, alignment: anchor)
        .background(FocusClearGlass(radius: radius))
        .clipShape(shape)
        .overlay(FocusGlassEdge(radius: radius))
        .contentShape(shape)
        }
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .onPreferenceChange(FocusPanelSizeKey.self) { if $0.height > 30 { panelHeight = $0.height } }
        .onChange(of: windowSize) { resize($0) }
        .onAppear { resize(windowSize) }
        .animation(Motion.reduced ? nil : .spring(response: 0.34, dampingFraction: 0.88), value: rail)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor)
        .onHover { inside in
            if inside {
                if !hoverSuppressed { expand() }
            } else {
                hoverSuppressed = false
                if !pinnedOpen { scheduleCollapse() }
            }
        }
        .animation(Motion.reduced ? nil : .spring(response: 0.36, dampingFraction: 0.86), value: showsCompanion)
        .onChange(of: session.active?.taskID) { id in
            // 刚开始专注时先完整显示一会儿，再收成小伙伴。
            if id != nil { pinnedOpen = false; expand(); scheduleCollapse(after: 2.5) }
            else { picking = true }
        }
        .onAppear {
            configureMention()
            if selectedTaskID == nil { selectedTaskID = tasks.first?.id }
            if previewPicked { picking = false }
        }
        .onReceive(Self.probeTogglePicking) {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { picking.toggle() }
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

    private var fullPanel: some View {
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
    }

    /// 手动收起：立刻收成小伙伴，鼠标还在上面也不弹回来。
    private func manualCollapse() {
        collapseTask?.cancel()
        pinnedOpen = false
        hoverSuppressed = true
        expanded = false
    }

    /// 手动展开：展开并保持，直到再手动收起。
    private func manualExpand() {
        pinnedOpen = true
        hoverSuppressed = false
        expand()
    }

    private func expand() {
        collapseTask?.cancel()
        collapseTask = nil
        if !expanded { expanded = true }
    }

    /// 鼠标离开后稍等再收起：窗口在两种大小之间切换时，指针短暂落在外面不至于来回闪。
    private func scheduleCollapse(after delay: Double = 0.6) {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            expanded = false
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
            taskSlot
            HStack(spacing: 6) {
                Image(systemName: "flag").font(.system(size: 11)).foregroundStyle(Palette.accent)
                TextField("本轮目标（可选）", text: $goal).textFieldStyle(.plain).font(.system(size: 12))
                    .frame(maxWidth: .infinity)
                Divider().frame(height: 14)
                TextField(String(Prefs.focusDurationMinutes()), text: $minutes).textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium)).monospacedDigit().multilineTextAlignment(.trailing).frame(width: 30)
                Text("分钟").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 9).frame(height: 28)
            .inputFieldSurface(focused: false, fill: Palette.background.opacity(0.14))
            Button { startFocus() } label: {
                Label(selectedTask.map { AppLocalizedFormat("开始专注 · #%lld", $0.task.number ?? 0) } ?? AppLocalized("先在时间轴上选一项"),
                      systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(selectedTaskID == nil ? Palette.line.opacity(0.4) : Palette.accent,
                                in: RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
                    .foregroundStyle(selectedTaskID == nil ? Palette.muted : Palette.onAccent)
                    .contentShape(RoundedRectangle(cornerRadius: Metrics.radiusSmall))
            }
            .buttonStyle(HitAreaButtonStyle(pressedScale: 0.98))
            .keyboardShortcut(.return)
            .disabled(selectedTaskID == nil || positiveMinutes == nil)
        }
    }

    /// 面板里的任务槽：显示选好的任务；点它在上方展开时间轴重新选。
    private var taskSlot: some View {
        Button {
            withAnimation(Motion.reduced ? nil : .spring(response: 0.34, dampingFraction: 0.88)) { picking.toggle() }
        } label: {
            HStack(spacing: 9) {
                if let task = selectedTask {
                    let color = PriorityMark(priority: task.task.priority).color
                    ZStack {
                        Circle().fill(color.opacity(0.22)).frame(width: 12, height: 12)
                        Circle().strokeBorder(color.opacity(0.85), lineWidth: 1.1).frame(width: 12, height: 12)
                        Circle().fill(color).frame(width: 5, height: 5)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(TaskText.rendered(task.task.title).characters)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        HStack(spacing: 6) {
                            if let number = task.task.number { Text("#\(number)") }
                            Text(task.task.dueDate.map { $0.relativeLabel } ?? AppLocalized("未设日期"))
                            if task.task.focusSeconds >= 60 { Text(AppLocalizedFormat("已专注 %@", FocusSession.brief(task.task.focusSeconds))) }
                        }
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(Palette.muted)
                    }
                } else {
                    Image(systemName: "circle.dashed").foregroundStyle(Palette.muted)
                    Text(timelineTasks.isEmpty && query.isEmpty ? "没有未完成的待办" : "在时间轴上选一个任务")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
                    .rotationEffect(.degrees(picking ? 180 : 0))
            }
            .padding(.horizontal, 10).frame(height: 40)
            .inputFieldSurface(focused: picking, fill: Palette.background.opacity(0.14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(picking ? "收起时间轴" : "在上方的时间轴里选任务")
        .accessibilityLabel(selectedTask.map { AppLocalized("专注任务：") + String(TaskText.rendered($0.task.title).characters) } ?? AppLocalized("选择专注任务"))
    }

    /// 小时间轴的顺序和主界面一致：按日期，同一天按手动顺序；未完成的才列出。
    private var timelineTasks: [ScheduledTask] {
        tasks.sorted(by: TaskTimelineSection.precedes)
    }

    private var selectedTask: ScheduledTask? {
        guard let selectedTaskID else { return nil }
        return store?.locate(selectedTaskID)
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
                if companionEnabled {
                    Button(action: manualCollapse) { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                        .buttonStyle(HitAreaButtonStyle(compact: true))
                        .foregroundStyle(Palette.muted)
                        .help("收成小伙伴").accessibilityLabel("收成小伙伴")
                }
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
                        .disabled(draft.pendingEntryID != nil)
                    // 标签、关联和发送放在输入框里，和其他输入框同一种布局。
                    if let store {
                        HStack(spacing: 0) {
                            TagSelectionButton(store: store, tags: $draft.tags)
                            LinkPickerButton(store: store, current: draft.link ?? session.active?.taskID,
                                             allowsNone: false, pick: { draft.link = $0 }) { MetadataSymbol(symbol: "@", active: draft.link != nil) }
                                .raisedOnHover(radius: 5)
                                .help("选择关联的待办").accessibilityLabel("选择关联的待办")
                        }
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
                .padding(.leading, 9).padding(.trailing, 4).padding(.vertical, 3)
                .frame(minHeight: 34)
                .inputFieldSurface(focused: focused, fill: Palette.background.opacity(0.18))
                .popover(isPresented: Binding(get: { mention.isActive }, set: { if !$0 { mention.dismiss() } }), arrowEdge: .bottom) {
                    if let store { MentionList(state: mention, store: store, contextTags: draft.tags).frame(width: 320) }
                }
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
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(Palette.muted).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                // 主操作（暂停 / 继续）用实心强调色，延长是次要操作，结束放在最后、只用文字色提示。
                Button { session.togglePause() } label: {
                    Label(session.isPaused ? "继续" : "暂停", systemImage: session.isPaused ? "play.fill" : "pause.fill")
                        .padding(.horizontal, 10).frame(minWidth: 64, minHeight: 24)
                        .background(Palette.accent, in: RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
                        .foregroundStyle(Palette.onAccent)
                        .contentShape(RoundedRectangle(cornerRadius: Metrics.radiusSmall))
                }
                .buttonStyle(HitAreaButtonStyle(pressedScale: 0.97))
                Button { session.extend(by: 5 * 60) } label: {
                    Text("+5 分钟").monospacedDigit()
                        .padding(.horizontal, 8).frame(minHeight: 24)
                        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)
                            .strokeBorder(Palette.line, lineWidth: Metrics.hairline))
                        .contentShape(RoundedRectangle(cornerRadius: Metrics.radiusSmall))
                }
                .buttonStyle(HitAreaButtonStyle(pressedScale: 0.97))
                .foregroundStyle(Palette.ink)
                .help("延长 5 分钟")
                Button(role: .destructive) { session.stop(reason: "手动结束") } label: {
                    Text("结束").padding(.horizontal, 6).frame(minHeight: 24)
                }
                .buttonStyle(HitAreaButtonStyle(pressedScale: 0.97))
                .foregroundStyle(Palette.danger)
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
            // 紧凑的小胶囊：没有累计时间时只显示图标，计时中显示走动的时间。
            HStack(spacing: 4) {
                Image(systemName: running ? "stop.fill" : "play.fill")
                    .font(.system(size: typography.pt(8), weight: .bold))
                if running || total >= 1 {
                    Text(running ? FocusSession.clock(total) : FocusSession.brief(total))
                        .font(.system(size: typography.pt(10), weight: .medium)).monospacedDigit()
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 7)
            .frame(minWidth: typography.pt(24), minHeight: typography.pt(20))
            .background(running ? Palette.danger.opacity(0.12) : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(running ? Palette.danger.opacity(0.4) : Palette.line.opacity(0.8), lineWidth: Metrics.hairline))
            .fixedSize()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).raisedOnHover(radius: 10)
        .foregroundStyle(running ? Palette.danger : Palette.muted)
        .help(running ? "结束专注计时" : "开始专注")
        .accessibilityLabel(running ? "结束专注计时" : "开始专注")
        .accessibilityValue(FocusSession.duration(total))
        .accessibilityIdentifier("task-focus-" + task.id.uuidString)
        .disabled(task.task.completed && !running)
    }
}

struct FocusPanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    /// 没量尺寸的兄弟视图也会送来默认值 .zero，不能让它盖掉真正量到的大小（否则面板永远不随输入变高）。
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// 专注中的桌面小伙伴：一颗会呼吸的进度环、剩余时间和任务名，浮在半透明的玻璃胶囊里。
struct FocusCompanion: View {
    @ObservedObject var session: FocusSession
    let title: String
    var expand: () -> Void = {}
    @State private var breathing = false

    private var tint: Color { session.isPaused ? Palette.muted : Palette.accent }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(tint.opacity(breathing ? 0.22 : 0.08)).frame(width: 30, height: 30)
                    .scaleEffect(breathing ? 1.08 : 0.92)
                Circle().stroke(Palette.muted.opacity(0.2), lineWidth: 2).frame(width: 22, height: 22)
                Circle().trim(from: 1 - session.remainingFraction, to: 1)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 22, height: 22)
                Circle().fill(tint).frame(width: 5, height: 5)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text(FocusSession.clock(session.remainingSeconds))
                    .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(session.isPaused ? Palette.muted : Palette.ink)
                Text(session.isPaused ? AppLocalized("已暂停") : title)
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: expand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(HitAreaButtonStyle(compact: true))
            .foregroundStyle(Palette.muted)
            .help("展开专注面板").accessibilityLabel("展开专注面板")
        }
        .padding(.leading, 8).padding(.trailing, 8).padding(.vertical, 7)
        .contentShape(Capsule())
        .onTapGesture(perform: expand)
        .onAppear {
            guard !Motion.reduced, !session.isPaused else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathing = true }
        }
        .onChange(of: session.isPaused) { paused in
            if paused { withAnimation(.easeOut(duration: 0.3)) { breathing = false } }
            else if !Motion.reduced { withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathing = true } }
        }
        .help(AppLocalized("悬停展开专注面板"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppLocalizedFormat("专注中，剩余 %@", FocusSession.clock(session.remainingSeconds)))
        .accessibilityAddTraits(.isButton)
    }
}

/// 专注面板上方的时间轴浮层：没有玻璃底，一根线串起所有未完成的待办，可以一直往上滚到更早的日期；
/// 最下面是搜索框，紧挨着面板里的任务槽。单击选中并收起。
struct FocusTimelineRail: View {
    let tasks: [ScheduledTask]
    let selected: UUID?
    let pinned: UUID?
    @Binding var query: String
    let height: CGFloat
    let select: (UUID) -> Void
    @State private var hovered: UUID?
    @Namespace private var highlight
    @FocusState private var searchFocused: Bool

    private struct Group: Identifiable {
        let day: Date?
        let tasks: [ScheduledTask]
        var id: String { day.map(JournalDates.key) ?? "undated" }
    }

    private var groups: [Group] {
        let calendar = JournalDates.calendar
        var result: [Group] = []
        for item in tasks {
            let day = item.task.dueDate.map { calendar.startOfDay(for: $0) }
            if let last = result.last, last.day == day {
                result[result.count - 1] = Group(day: day, tasks: last.tasks + [item])
            } else {
                result.append(Group(day: day, tasks: [item]))
            }
        }
        return result
    }

    /// 打开时停在选中的那一项；没选就停在今天（或最近的日期）。
    private var initialTarget: AnyHashable? {
        if let selected { return selected }
        let today = JournalDates.calendar.startOfDay(for: Date())
        return groups.first { ($0.day ?? .distantFuture) >= today }?.id ?? groups.last?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if tasks.isEmpty {
                Spacer(minLength: 0)
                Text("没有匹配的任务").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(groups) { group in
                                knot(group.day).id(group.id)
                                ForEach(group.tasks) { item in row(item) }
                            }
                        }
                        .padding(.vertical, 6)
                        .background(alignment: .leading) {
                            Rectangle().fill(Palette.line.opacity(0.8)).frame(width: 1.2).padding(.leading, 9.4).padding(.vertical, 12)
                        }
                    }
                    // 上下两端淡出：线像是从屏幕上延伸过来的，不是被框截断。
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                                                 .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .onAppear { if let target = initialTarget { proxy.scrollTo(target, anchor: .center) } }
                    .onChange(of: query) { _ in if let first = tasks.first { proxy.scrollTo(first.id, anchor: .top) } }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Palette.muted)
                TextField("搜索标题或编号…", text: $query).textFieldStyle(.plain).font(.system(size: 11))
                    .focused($searchFocused)
                    .onSubmit { if let first = tasks.first { select(first.id) } }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 10).frame(height: 24)
            .background(Palette.background.opacity(0.28), in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.line.opacity(0.5), lineWidth: Metrics.hairline))
        }
        .padding(.horizontal, 8)
        .modifier(RailLegibility())
        // 透明区域也要接住点击和滚动。
        .background(Color.black.opacity(0.001))
        .contentShape(Rectangle())
    }

    private func knot(_ day: Date?) -> some View {
        let today = day.map { JournalDates.calendar.isDateInToday($0) } == true
        let overdue = day.map { $0 < JournalDates.calendar.startOfDay(for: Date()) } == true
        return HStack(spacing: 8) {
            ZStack {
                if today { Circle().fill(Palette.accent.opacity(0.2)).frame(width: 13, height: 13) }
                Circle().fill(today ? Palette.accent : Palette.background).frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(today ? Palette.background : Palette.muted.opacity(0.8), lineWidth: today ? 1.2 : 1))
            }
            .frame(width: 20)
            Text(day.map { overdue ? AppLocalizedFormat("%@ · 已逾期", $0.relativeLabel) : $0.relativeLabel } ?? AppLocalized("未设日期"))
                .font(.system(size: 10, weight: today ? .semibold : .medium))
                .foregroundStyle(today ? Palette.accent : (overdue ? Palette.deadline : Palette.muted))
            Spacer(minLength: 0)
        }
        .frame(height: 20)
    }

    private func row(_ item: ScheduledTask) -> some View {
        let isSelected = item.id == selected
        let color = PriorityMark(priority: item.task.priority).color
        return HStack(spacing: 8) {
            ZStack {
                Circle().fill(Palette.background).frame(width: 11, height: 11)
                Circle().fill(color.opacity(0.22)).frame(width: 11, height: 11)
                Circle().strokeBorder(color.opacity(0.85), lineWidth: 1.1).frame(width: 11, height: 11)
                Circle().fill(color).frame(width: isSelected ? 6 : 4, height: isSelected ? 6 : 4)
            }
            .frame(width: 20)
            Text(String(TaskText.rendered(item.task.title).characters)).font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
            if item.id == pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Palette.accent) }
            Spacer(minLength: 4)
            if item.task.dueHasTime, let due = item.task.dueDate {
                Text(NoteThread.shortTime(due)).font(.system(size: 10)).monospacedDigit().foregroundStyle(Palette.muted)
            }
            if item.task.focusSeconds >= 60 {
                Text(FocusSession.brief(item.task.focusSeconds)).font(.system(size: 10)).monospacedDigit().foregroundStyle(Palette.muted)
            }
            Image(systemName: "play.fill").font(.system(size: 8))
                .foregroundStyle(Palette.accent).opacity(hovered == item.id ? 1 : 0)
        }
        .padding(.trailing, 6).frame(height: 26)
        .background {
            ZStack {
                if hovered == item.id && !isSelected {
                    RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous).fill(Palette.soft.opacity(0.35))
                }
                // 选中的底色是同一块，在行之间滑过去。
                if isSelected {
                    RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous).fill(Palette.accent.opacity(0.16))
                        .matchedGeometryEffect(id: "selection", in: highlight)
                }
            }
            .padding(.leading, 16)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Motion.reduced ? nil : .spring(response: 0.2, dampingFraction: 0.9)) { select(item.id) }
        }
        .onHover { inside in if inside { hovered = item.id } else if hovered == item.id { hovered = nil } }
        .help("选这个任务")
        .id(item.id)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { select(item.id) }
    }
}

/// 专注面板贴在屏幕哪一边（控制器在每次定位后更新）。
@MainActor
final class FocusDock: ObservableObject {
    static let shared = FocusDock()
    @Published var right = true
}

struct FocusCompanionSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct SizeReader<Key: PreferenceKey>: View where Key.Value == CGSize {
    let key: Key.Type
    var body: some View { GeometryReader { Color.clear.preference(key: Key.self, value: $0.size) } }
}

/// 近乎透明的玻璃底：一层极淡的色调和顶部的微光。圆角可以动画，跟着变形。
private struct FocusClearGlass: View {
    var radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(Palette.background.opacity(scheme == .dark ? 0.08 : 0.1))
            .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.05 : 0.18), .clear],
                                               startPoint: .top, endPoint: .center)))
    }
}

/// 玻璃的细边。
private struct FocusGlassEdge: View {
    var radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.28 : 0.85), Palette.line.opacity(0.35)],
                                         startPoint: .top, endPoint: .bottom), lineWidth: Metrics.hairline)
            .allowsHitTesting(false)
    }
}

/// 近乎透明的面板上，文字加一层很淡的描影，放在任何壁纸上都看得清。
private struct LegibilityShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.shadow(color: (scheme == .dark ? Color.black : Color.white).opacity(scheme == .dark ? 0.75 : 0.6), radius: 1.6, y: 0.5)
    }
}

/// 浮在桌面上的时间轴没有底板：文字加一层较明显的描影，深浅壁纸上都看得清。
private struct RailLegibility: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let halo = scheme == .dark ? Color.black : Color.white
        content.shadow(color: halo.opacity(0.85), radius: 2, y: 0).shadow(color: halo.opacity(0.5), radius: 5, y: 0)
    }
}

