import AppIntents
import SwiftUI
import TimelineCore
import UIKit

/// 从应用外面直接进到「写日志」「加待办」：小组件、控制中心按钮、主屏长按菜单和快捷指令都走这里。
/// 链接是 `timeline://new/log`、`timeline://new/task`；应用冷启动时页面还没建好，所以请求先存着，页面出现时再取。
@MainActor
final class QuickEntry: ObservableObject {
    enum Kind: String { case log, task }

    static let shared = QuickEntry()
    @Published var request: Kind?

    static func url(_ kind: Kind) -> URL { URL(string: "timeline://new/\(kind.rawValue)")! }

    /// 认得的链接返回 true。
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard url.scheme == "timeline", url.host == "new", let kind = Kind(rawValue: url.lastPathComponent) else { return false }
        request = kind
        return true
    }

    /// 页面取走请求：是这一种就清掉并返回 true。
    func take(_ kind: Kind) -> Bool {
        guard request == kind else { return false }
        request = nil
        return true
    }

    /// 主屏长按图标的快捷菜单。
    static func installHomeScreenActions() {
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(type: Kind.log.rawValue, localizedTitle: L("写日志"), localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "square.and.pencil")),
            UIApplicationShortcutItem(type: Kind.task.rawValue, localizedTitle: L("新待办"), localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "checklist")),
        ]
    }
}

/// 主屏快捷菜单要走 UIKit 的场景回调。
final class QuickEntryAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem, let kind = QuickEntry.Kind(rawValue: item.type) {
            MainActor.assumeIsolated { QuickEntry.shared.request = kind }
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = QuickEntrySceneDelegate.self
        return configuration
    }
}

final class QuickEntrySceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        let kind = QuickEntry.Kind(rawValue: shortcutItem.type)
        MainActor.assumeIsolated { QuickEntry.shared.request = kind }
        completionHandler(kind != nil)
    }
}

// MARK: - 快捷指令

/// 不打开应用，直接记一条日志。可以在快捷指令里接「共享表单」的文字、链接和图片。
struct AddLogIntent: AppIntent {
    static var title: LocalizedStringResource = "写日志"
    static var description = IntentDescription("在 Timeline 的今天记一条日志，可以带图片。")

    @Parameter(title: "内容", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String?

    @Parameter(title: "图片", supportedTypeIdentifiers: ["public.image"])
    var images: [IntentFile]?

    static var parameterSummary: some ParameterSummary { Summary("在 Timeline 记下 \(\.$text)") { \.$images } }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AppServices.shared.store
        var names: [String] = []
        for file in images ?? [] {
            guard let image = UIImage(data: file.data), let jpeg = image.scaledForLog().jpegData(compressionQuality: 0.85),
                  let name = try? store.storeImage(jpeg, fileExtension: "jpg") else { continue }
            names.append(name)
        }
        let body = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !names.isEmpty else { throw $text.needsValueError(IntentDialog(stringLiteral: L("要记什么？"))) }
        let parsed = TagText.extract(from: body)
        try store.quickLog(parsed.title, images: names, tags: parsed.tags, on: Date())
        store.save()
        await AppServices.shared.sync.syncNow()
        return .result(dialog: IntentDialog(stringLiteral: L("已记下")))
    }
}

/// 不打开应用，直接加一条待办；和应用里一样识别「明天 下午3点」「提前30分钟」「#标签」。
struct AddTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "添加待办"
    static var description = IntentDescription("在 Timeline 里添加一条待办，识别日期、时间、提醒和标签。")

    @Parameter(title: "待办", requestValueDialog: "要做什么？")
    var text: String

    static var parameterSummary: some ParameterSummary { Summary("在 Timeline 添加待办 \(\.$text)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AppServices.shared.store
        guard let created = store.addParsedTodo(text, on: Date()) else { throw $text.needsValueError(IntentDialog(stringLiteral: L("要做什么？"))) }
        store.save()
        await AppServices.shared.sync.syncNow()
        let title = String(TaskText.rendered(created.task.title).characters)
        let due = created.task.dueDate.map { " · " + $0.formatted(date: .abbreviated, time: created.task.dueHasTime ? .shortened : .omitted) } ?? ""
        return .result(dialog: IntentDialog(stringLiteral: LF("已添加：%@", title + due)))
    }
}

/// 打开应用并弹出写日志的输入框。
struct OpenLogComposerIntent: AppIntent {
    static var title: LocalizedStringResource = "打开写日志"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickEntry.shared.request = .log
        return .result()
    }
}

struct TimelineShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddLogIntent(), phrases: ["用 \(.applicationName) 写日志", "在 \(.applicationName) 记一笔", "Log in \(.applicationName)"],
                    shortTitle: "写日志", systemImageName: "square.and.pencil")
        AppShortcut(intent: AddTaskIntent(), phrases: ["用 \(.applicationName) 添加待办", "在 \(.applicationName) 加待办", "Add a task in \(.applicationName)"],
                    shortTitle: "添加待办", systemImageName: "checklist")
        AppShortcut(intent: OpenLogComposerIntent(), phrases: ["打开 \(.applicationName) 写日志", "Open \(.applicationName) journal entry"],
                    shortTitle: "打开写日志", systemImageName: "book")
    }
}
