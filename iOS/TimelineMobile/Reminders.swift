import BackgroundTasks
import Combine
import SwiftUI
import TimelineCore
import UserNotifications

/// 待办提醒：和 Mac 版用同一份提醒计划（`ReminderPlan`），在 iPhone 上也排进系统通知。
/// 通知上可以直接「完成」或「推迟」；点通知打开待办页。系统最多替一个应用排 64 条，取最早的 60 条，给专注计时留位置。
@MainActor
final class ReminderScheduler: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let enabledKey = "remindersEnabled"
    static let category = "timeline.reminder"
    static let completeAction = "timeline.complete"
    static let snooze10Action = "timeline.snooze10"
    static let snooze60Action = "timeline.snooze60"
    static let limit = 60

    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private let store: JournalStore
    private let center = UNUserNotificationCenter.current()
    private var changes: AnyCancellable?
    private var pending: Task<Void, Never>?

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            refresh(requesting: newValue)
        }
    }

    init(store: JournalStore) {
        self.store = store
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [
                UNNotificationAction(identifier: Self.completeAction, title: L("完成"), options: []),
                UNNotificationAction(identifier: Self.snooze10Action, title: L("推迟 10 分钟"), options: []),
                UNNotificationAction(identifier: Self.snooze60Action, title: L("推迟 1 小时"), options: []),
            ], intentIdentifiers: [], options: [])
        ])
        // 日志、草稿不改变提醒：先合并输入，计划真的变了才去碰系统通知。
        changes = store.$days
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .map { ReminderPlan.pending(days: $0) }
            .removeDuplicates()
            .sink { [weak self] _ in self?.refresh() }
    }

    /// 按当前数据重排通知。第一次遇到带提醒的待办时请求通知权限。
    func refresh(requesting: Bool = true) {
        pending?.cancel()
        pending = Task { [weak self] in await self?.reschedule(requesting: requesting) }
    }

    /// 等这一轮排完（后台刷新用）。
    func refreshNow() async {
        pending?.cancel()
        await reschedule(requesting: false)
    }

    private func reschedule(requesting: Bool) async {
        let plans = isEnabled ? Array(ReminderPlan.pending(days: store.days).prefix(Self.limit)) : []
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined, requesting, !plans.isEmpty {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
        }
        authorization = status
        guard !Task.isCancelled else { return }
        let existing = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix("timeline.") }
        let desired = Set(plans.map(\.id))
        center.removePendingNotificationRequests(withIdentifiers: existing.map(\.identifier).filter { !desired.contains($0) })
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }
        for plan in plans {
            guard !Task.isCancelled else { return }
            if let request = existing.first(where: { $0.identifier == plan.id }), Self.matches(request, plan: plan) { continue }
            try? await center.add(Self.request(for: plan))
        }
    }

    static func request(for plan: ReminderPlan) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = L("事项提醒")
        content.body = plan.title
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = ["day": plan.dayKey, "task": plan.taskID.uuidString]
        let components = JournalDates.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: plan.fireDate)
        return UNNotificationRequest(identifier: plan.id, content: content,
                                     trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }

    static func matches(_ request: UNNotificationRequest, plan: ReminderPlan) -> Bool {
        guard let trigger = request.trigger as? UNCalendarNotificationTrigger, !trigger.repeats else { return false }
        let components = JournalDates.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: plan.fireDate)
        return trigger.dateComponents == components && request.content.body == plan.title
            && request.content.categoryIdentifier == category
            && request.content.userInfo["task"] as? String == plan.taskID.uuidString
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let taskID = (content.userInfo["task"] as? String).flatMap(UUID.init(uuidString:))
        let action = response.actionIdentifier
        let title = content.title, body = content.body, info = content.userInfo
        Task { @MainActor in
            switch action {
            case Self.completeAction:
                if let taskID, let located = store.locate(taskID), !located.task.completed {
                    store.toggleTodo(taskID, on: located.date)
                    store.save()
                }
            case Self.snooze10Action, Self.snooze60Action:
                let snoozed = UNMutableNotificationContent()
                snoozed.title = title
                snoozed.body = body
                snoozed.sound = .default
                snoozed.categoryIdentifier = Self.category
                snoozed.userInfo = info
                let delay: TimeInterval = action == Self.snooze10Action ? 600 : 3600
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(
                    identifier: "timeline-snooze.\(taskID?.uuidString ?? UUID().uuidString)", content: snoozed,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)))
            case UNNotificationDefaultActionIdentifier:
                if let taskID { Navigator.shared.open(.task(taskID)) }
            default: break
            }
        }
        completionHandler()
    }
}

/// 后台刷新：系统不定时唤醒一下，同步一轮再重排提醒，这样在 Mac 上新设的提醒不打开 iPhone 应用也能响。
enum BackgroundRefresh {
    static let identifier = "local.timeline.refresh"

    /// 进后台时预约下一次（系统决定具体时间，通常不早于这里给的间隔）。
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    static func run(sync: SyncModel, reminders: ReminderScheduler) async {
        schedule()
        await sync.syncNow()
        await reminders.refreshNow()
    }
}

/// 截止日期页里的提醒选项（和 Mac 版一样）。
struct ReminderPicker: View {
    @Binding var minutes: Int
    let timed: Bool
    var isInterval = false

    var body: some View {
        Picker("提醒", selection: $minutes) {
            Text("不提醒").tag(-1)
            Text(isInterval ? "开始时" : (timed ? "截止时" : "当天 09:00")).tag(0)
            Text("提前 15 分钟").tag(15)
            Text("提前 30 分钟").tag(30)
            Text("提前 1 小时").tag(60)
            Text("提前 1 天").tag(1440)
        }
    }
}
