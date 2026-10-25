import AppKit
import Combine
import UserNotifications
import TimelineCore

@MainActor
final class ReminderScheduler: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var status = ""
    var isEnabled = true
    var onComplete: ((String) -> Void)?
    private let store: JournalStore
    /// 用到时才取：不在应用包里运行（测试）时没有通知中心，取了会崩溃，所以那时 `isEnabled` 要关掉。
    private lazy var center = UNUserNotificationCenter.current()
    private var changes: AnyCancellable?
    private var pending: Task<Void, Never>?

    init(store: JournalStore) {
        self.store = store
        super.init()
        guard Bundle.main.bundleURL.pathExtension == "app" else { isEnabled = false; return }
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [
                UNNotificationAction(identifier: Self.completeAction, title: "完成", options: []),
                UNNotificationAction(identifier: Self.snooze10Action, title: "推迟 10 分钟", options: []),
                UNNotificationAction(identifier: Self.snooze60Action, title: "推迟 1 小时", options: []),
            ], intentIdentifiers: [], options: [])
        ])
        changes = Self.planChanges(in: store).sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// 日志、草稿和 OCR 不改变提醒。先合并输入，再比较计划，避免每次打字访问系统通知服务。
    static func planChanges(in store: JournalStore) -> AnyPublisher<[ReminderPlan], Never> {
        store.$days
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .map { ReminderPlan.pending(days: $0) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func requestPermission() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            status = granted ? "" : "通知未开启，可在系统设置中允许 Timeline 通知。"
            return granted
        } catch {
            status = AppLocalizedFormat("无法启用通知：%@", error.localizedDescription)
            return false
        }
    }

    static let category = "timeline.reminder"
    static let completeAction = "timeline.complete"
    static let snooze10Action = "timeline.snooze10"
    static let snooze60Action = "timeline.snooze60"

    func refresh() {
        guard isEnabled else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            guard let self else { return }
            let settings = await center.notificationSettings()
            guard !Task.isCancelled else { return }
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                if store.days.values.contains(where: { $0.todos.contains { $0.reminderMinutes != nil && !$0.completed } }) {
                    status = "通知未开启，可在系统设置中允许 Timeline 通知。"
                }
                return
            }
            let plans = ReminderPlan.pending(days: store.days)
            let existing = await center.pendingNotificationRequests()
            guard !Task.isCancelled else { return }
            let desired = Set(plans.map(\.id))
            center.removePendingNotificationRequests(withIdentifiers: existing.map(\.identifier).filter { $0.hasPrefix("timeline.") && !desired.contains($0) })
            do {
                for plan in plans {
                    guard !Task.isCancelled else { return }
                    if let request = existing.first(where: { $0.identifier == plan.id }),
                       Self.matches(request, plan: plan) { continue }
                    let content = UNMutableNotificationContent()
                    content.title = AppLocalized("事项提醒")
                    content.body = plan.title
                    content.sound = .default
                    content.categoryIdentifier = Self.category
                    content.userInfo = ["day": plan.dayKey, "task": plan.taskID.uuidString]
                    let components = JournalDates.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: plan.fireDate)
                    let request = UNNotificationRequest(identifier: plan.id, content: content,
                                                        trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
                    try await center.add(request)
                }
                status = ""
            } catch { status = AppLocalizedFormat("提醒未能保存：%@", error.localizedDescription) }
        }
    }

    static func matches(_ request: UNNotificationRequest, plan: ReminderPlan) -> Bool {
        guard let trigger = request.trigger as? UNCalendarNotificationTrigger, !trigger.repeats else { return false }
        let components = JournalDates.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: plan.fireDate)
        return trigger.dateComponents == components && request.content.body == plan.title
            && request.content.categoryIdentifier == category
            && request.content.userInfo["day"] as? String == plan.dayKey
            && request.content.userInfo["task"] as? String == plan.taskID.uuidString
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let key = info["day"] as? String
        let taskID = (info["task"] as? String).flatMap(UUID.init(uuidString:))
        let action = response.actionIdentifier
        let content = response.notification.request.content
        Task { @MainActor in
            switch action {
            case Self.completeAction:
                if let taskID, let located = store.locate(taskID) {
                    if !located.task.completed { store.toggleTodo(taskID, on: located.date) }
                    onComplete?(String(TaskText.rendered(located.task.title).characters))
                }
            case Self.snooze10Action, Self.snooze60Action:
                let delay: TimeInterval = action == Self.snooze10Action ? 600 : 3600
                let snoozed = UNMutableNotificationContent()
                snoozed.title = content.title
                snoozed.body = content.body
                snoozed.sound = .default
                snoozed.categoryIdentifier = Self.category
                snoozed.userInfo = content.userInfo
                let id = "timeline-snooze.\(taskID?.uuidString ?? UUID().uuidString)"
                try? await center.add(UNNotificationRequest(identifier: id, content: snoozed,
                                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)))
            default:
                if let key, let date = JournalDates.date(for: key) {
                    NotificationCenter.default.post(name: .timelineNavigate, object: date)
                    if let taskID { NotificationCenter.default.post(name: .timelineReveal, object: taskID) }
                    NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
                    Headless.activateApp()
                }
            }
        }
        completionHandler()
    }
}

extension Notification.Name {
    static let timelineNavigate = Notification.Name("TimelineNavigate")
    static let timelineReveal = Notification.Name("TimelineReveal")
    /// 点了待办上的标签：object 是标签名，笔记窗口定位到这个标签。
    static let timelineOpenTag = Notification.Name("TimelineOpenTag")
}
