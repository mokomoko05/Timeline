import AppKit
import Combine
import UserNotifications

/// 首次授权必须由应用发起；系统通知设置不能替尚未申请的应用开启权限。
@MainActor
final class NotificationAccess: ObservableObject {
    @Published private(set) var authorization: UNAuthorizationStatus?
    @Published private(set) var isRequesting = false
    @Published private(set) var error = ""
    private let readStatus: () async -> UNAuthorizationStatus
    private let request: () async throws -> Bool
    private let openSettings: () -> Void

    init(readStatus: @escaping () async -> UNAuthorizationStatus = {
        guard !Headless.active, Bundle.main.bundleURL.pathExtension == "app" else { return .notDetermined }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }, request: @escaping () async throws -> Bool = {
        guard !Headless.active, Bundle.main.bundleURL.pathExtension == "app" else { return false }
        return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }, openSettings: @escaping () -> Void = {
        guard !Headless.active,
              let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=local.timeline.app") else { return }
        NSWorkspace.shared.open(url)
    }) {
        self.readStatus = readStatus
        self.request = request
        self.openSettings = openSettings
    }

    var isAllowed: Bool { authorization == .authorized || authorization == .provisional }

    var message: String {
        switch authorization {
        case .none: return "正在检查通知权限…"
        case .notDetermined: return "尚未申请通知权限，请点击“启用通知”完成授权。"
        case .denied: return "通知未开启，可在系统设置中允许 Timeline 通知。"
        default: return "通知已开启；请在任务详情中选择提醒时间。"
        }
    }

    var actionTitle: String { authorization == nil || authorization == .notDetermined ? "启用通知" : "通知设置" }

    func reload() async { authorization = await readStatus() }

    func requestPermission() async -> Bool {
        guard !isRequesting else { return isAllowed }
        isRequesting = true
        defer { isRequesting = false }
        error = ""
        await reload()
        if isAllowed { return true }
        guard authorization == .notDetermined else { return false }
        do {
            _ = try await request()
            await reload()
            return isAllowed
        } catch {
            self.error = AppLocalizedFormat("无法启用通知：%@", error.localizedDescription)
            return false
        }
    }

    func configure() async {
        guard !isRequesting else { return }
        await reload()
        if authorization == .notDetermined {
            _ = await requestPermission()
        } else {
            openSettings()
        }
    }
}
