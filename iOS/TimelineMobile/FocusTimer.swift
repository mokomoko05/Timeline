import ActivityKit
import Combine
import SwiftUI
import TimelineCore
import UserNotifications

/// iPhone 上的专注计时：和 Mac 一样在日志里写「开始专注」「结束专注」两条记录（会同步到 Mac），
/// 时长累加到任务上；计时进行中在锁屏和灵动岛上显示倒计时。
///
/// 计时按真实时间计算，不靠每秒的定时器：应用被挂起、被系统关掉都不影响，重新打开时从保存的状态接着算。
/// 倒计时结束时停在终点（多出来的时间不算），发一条通知，回到应用里选择结束或者再加几分钟。
@MainActor
final class FocusTimer: ObservableObject {
    struct Session: Codable, Equatable {
        var taskID: UUID
        var title: String
        var number: Int?
        var started: Date
        var plannedSeconds: TimeInterval
        var goal: String
        var startLogID: UUID?
        /// 已经结束的暂停加起来多长。
        var pausedSeconds: TimeInterval = 0
        /// 正在暂停：从什么时候开始。
        var pausedAt: Date?
        /// 倒计时走完了，在等用户决定。
        var finished = false
    }

    static let durations = [15, 25, 45, 60, 90]
    static let minutesKey = "focusMinutes"
    private static let sessionKey = "focusSession"
    private static let notificationID = "focus-end"
    /// 和 Mac 默认一致：不到 5 分钟、又没写目标的专注不留日志（时长照常累加）。
    static let minimumLoggedSeconds: TimeInterval = 5 * 60

    @Published private(set) var session: Session?
    let store: JournalStore
    private let defaults: UserDefaults
    private var endTimer: Timer?
    private var storeSink: AnyCancellable?

    init(store: JournalStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.sessionKey), let saved = try? JSONDecoder().decode(Session.self, from: data) {
            session = saved
            store.setFocusTask(saved.taskID)
            store.setFocusPaused(saved.pausedAt != nil)
            watch()
            refresh()
        } else {
            // 上次没收尾的实时活动（比如应用被删掉重装）。
            Task { for activity in Activity<FocusActivityAttributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) } }
        }
    }

    var isActive: Bool { session != nil }
    var isPaused: Bool { session?.pausedAt != nil }

    // MARK: 读数

    func elapsed(at now: Date = Date()) -> TimeInterval {
        guard let session else { return 0 }
        let pausedNow = session.pausedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return min(session.plannedSeconds, max(0, now.timeIntervalSince(session.started) - session.pausedSeconds - pausedNow))
    }

    func remaining(at now: Date = Date()) -> TimeInterval {
        max(0, (session?.plannedSeconds ?? 0) - elapsed(at: now))
    }

    /// 计时中：倒计时在这一刻走完。
    private func endDate(at now: Date = Date()) -> Date { now.addingTimeInterval(remaining(at: now)) }

    // MARK: 操作

    func start(task: ScheduledTask, minutes: Int, goal: String, now: Date = Date()) {
        guard !store.isReadOnly else { return }
        if session != nil { stop(reason: "切换到了另一个任务", now: now) }
        defaults.set(minutes, forKey: Self.minutesKey)
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        var new = Session(taskID: task.id, title: String(TaskText.rendered(task.task.title).characters), number: task.task.number,
                          started: now, plannedSeconds: TimeInterval(max(1, minutes) * 60), goal: goal)
        new.startLogID = store.addFocusLog("▶ 开始专注", taskID: task.id, now: now, event: .start,
                                           goal: goal.isEmpty ? nil : goal, plannedSeconds: new.plannedSeconds)
        store.setFocusTask(task.id)
        store.setFocusPaused(false)
        store.save()
        session = new
        persist()
        watch()
        requestNotificationPermission()
        startActivity()
        refresh()
    }

    func pause(now: Date = Date()) {
        guard var current = session, current.pausedAt == nil, !current.finished else { return }
        current.pausedAt = now
        session = current
        store.setFocusPaused(true)
        persist()
        refresh()
    }

    func resume(now: Date = Date()) {
        guard var current = session, let pausedAt = current.pausedAt, !current.finished else { return }
        current.pausedSeconds += max(0, now.timeIntervalSince(pausedAt))
        current.pausedAt = nil
        session = current
        store.setFocusPaused(false)
        persist()
        refresh()
    }

    func togglePause() { isPaused ? resume() : pause() }

    /// 再加几分钟：时间到了的话接着计时。
    func extend(minutes: Int, now: Date = Date()) {
        guard var current = session else { return }
        if current.finished, let pausedAt = current.pausedAt {
            current.pausedSeconds += max(0, now.timeIntervalSince(pausedAt))
            current.pausedAt = nil
            current.finished = false
            store.setFocusPaused(false)
        }
        current.plannedSeconds += TimeInterval(minutes * 60)
        session = current
        persist()
        refresh()
    }

    /// 结束：写结束记录、累加时长。太短又没有目标的一轮不留日志（同 Mac）。
    func stop(reason: String, now: Date = Date()) {
        guard let current = session else { return }
        let seconds = elapsed(at: now)
        session = nil
        persist()
        storeSink = nil
        if seconds < Self.minimumLoggedSeconds, current.goal.isEmpty {
            store.discardShortFocus(startLogID: current.startLogID, taskID: current.taskID, seconds: seconds, now: now)
        } else {
            let total = (store.locate(current.taskID)?.task.focusSeconds ?? 0) + seconds
            store.addFocusLog("■ 结束专注 · 用时 \(Self.duration(seconds)) · 累计 \(Self.duration(total)) · \(reason)",
                              taskID: current.taskID, now: now, seconds: seconds, fallback: (current.title, current.number),
                              event: .end, endReason: reason, minimumSeconds: Self.minimumLoggedSeconds)
        }
        store.setFocusTask(nil)
        store.save()
        refresh()
    }

    /// 回到前台时调用：时间可能已经在后台走完了。
    func refresh(now: Date = Date()) {
        endTimer?.invalidate()
        endTimer = nil
        guard var current = session else {
            cancelNotification()
            endActivity()
            return
        }
        if !current.finished, current.pausedAt == nil, remaining(at: now) <= 0 {
            // 停在终点：暂停时刻取倒计时结束的那一刻，多出来的时间不算专注。
            let overshoot = now.timeIntervalSince(current.started) - current.pausedSeconds - current.plannedSeconds
            current.pausedAt = now.addingTimeInterval(-max(0, overshoot))
            current.finished = true
            session = current
            store.setFocusPaused(true)
            persist()
        }
        if current.pausedAt == nil {
            scheduleNotification(at: endDate(at: now))
            let timer = Timer(fire: endDate(at: now), interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            endTimer = timer
        } else {
            cancelNotification()
        }
        updateActivity(now: now)
    }

    /// 专注的任务完成、放弃或删除了（包括从别的设备同步过来的）：自动结束。
    private func watch() {
        storeSink = store.$days.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let current = self.session else { return }
                    guard let task = self.store.locate(current.taskID)?.task else { return self.stop(reason: "任务已删除") }
                    if task.isDone { self.stop(reason: "任务已完成") } else if task.isDropped { self.stop(reason: "任务已放弃") }
                }
            }
        }
    }

    private func persist() {
        if let session, let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: Self.sessionKey)
        } else {
            defaults.removeObject(forKey: Self.sessionKey)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        if h > 0 { return "\(h) 小时 \(m) 分 \(s) 秒" }
        if m > 0 { return "\(m) 分 \(s) 秒" }
        return "\(s) 秒"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: 通知

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func scheduleNotification(at date: Date) {
        guard let session, date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = L("专注时间到")
        content.body = (session.number.map { "#\($0) " } ?? "") + session.title
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: trigger))
    }

    private func cancelNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }

    // MARK: 实时活动

    private var activity: Activity<FocusActivityAttributes>? { Activity<FocusActivityAttributes>.activities.first }

    private func state(at now: Date) -> FocusActivityAttributes.ContentState {
        let finished = session?.finished == true
        return FocusActivityAttributes.ContentState(
            endsAt: endDate(at: now),
            frozenRemaining: isPaused ? remaining(at: now) : nil,
            status: L(finished ? "时间到" : (isPaused ? "已暂停" : "专注中")),
            finished: finished)
    }

    private func startActivity(now: Date = Date()) {
        guard let session, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endActivity()
        let attributes = FocusActivityAttributes(title: session.title, number: session.number, plannedSeconds: session.plannedSeconds)
        _ = try? Activity.request(attributes: attributes, content: ActivityContent(state: state(at: now), staleDate: nil))
    }

    private func updateActivity(now: Date) {
        guard session != nil else { return }
        guard let activity else { return startActivity(now: now) }
        // 计划时长改了（加时）：进度条的总长在属性里，只能重新开一个。
        if activity.attributes.plannedSeconds != session?.plannedSeconds { return startActivity(now: now) }
        let content = ActivityContent(state: state(at: now), staleDate: nil)
        Task { await activity.update(content) }
    }

    private func endActivity() {
        for activity in Activity<FocusActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
