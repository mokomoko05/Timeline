import AppKit
import Combine
import SwiftUI
import TimelineCore

/// AppKit 菜单和窗口标题使用的本地化入口；SwiftUI 的 Text/Button 字面量会自动使用同一份 strings。
func AppLocalized(_ key: String, bundle: Bundle = .main) -> String {
    let identifier = AppLanguage.current.locale.identifier
    let localized = bundle.path(forResource: identifier, ofType: "lproj").flatMap(Bundle.init(path:)) ?? bundle
    return NSLocalizedString(key, bundle: localized, comment: "")
}

func AppLocalizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: AppLocalized(key), locale: AppLanguage.current.locale, arguments: arguments)
}

func AppErrorDescription(_ error: Error) -> String {
    guard let error = error as? LogInputError else { return AppLocalized(error.localizedDescription) }
    switch error {
    case .empty: return AppLocalized("请输入记录内容，或先关联一条任务。")
    case .unknownCommand(let command): return AppLocalizedFormat("未知命令 %@，输入 /help 查看用法。", command)
    case .missingTask: return AppLocalized("关联任务已删除，请重新选择任务或取消关联。")
    case .readOnly: return AppLocalized("当前数据只读，无法保存日志。")
    case .badTaskReference(let text): return AppLocalizedFormat("无法识别任务编号「%@」，请写成 #1。", text)
    case .unknownTask(let number): return AppLocalizedFormat("没有 #%lld 号任务。编号显示在任务行左边，创建后不会变。", number)
    }
}

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("TimelineLanguageDidChange")
}

/// 偏好设置的存储键；设置窗口、菜单栏和主界面共用。
enum Prefs {
    static let language = "appLanguage"
    static let hideCompleted = "hideCompleted"
    static let clickExpands = "clickExpandsTasks"
    static let weekStartsSunday = "weekStartsSunday"
    static let uiScale = "uiScale"
    /// 全局文本额外行距（点），用于任务、笔记、日志和搜索结果。
    static let lineSpacing = "lineSpacing"
    static let globalHotKey = "globalHotKeyEnabled"
    /// 新建终端的布局：threePanes（左上下两格、右一栏）或 single。
    static let terminalLayout = "terminalLayout"
    /// 最低专注分钟数；未达标且无目标或反馈时不留日志，有内容则以红叉保留（0 表示都记）。
    static let focusMinLogMinutes = "focusMinLogMinutes"
    static let defaultFocusMinLogMinutes = 5
    static let focusDefaultMinutes = "focusDefaultMinutes"
    static let taskSortMode = "taskSortMode"
    static let defaultFocusMinutes = 25
    static func focusDurationMinutes(defaults: UserDefaults = .standard) -> Int {
        let value = defaults.object(forKey: focusDefaultMinutes) as? Int ?? defaultFocusMinutes
        return value > 0 && value <= Int.max / 60 ? value : defaultFocusMinutes
    }
    /// 专注计时窗口的样式（`FocusPanelStyle.rawValue`）和是否隐藏（专注照常进行，只是不显示）。
    static let focusPanelStyle = "focusPanelStyle"
    static let focusPanelHidden = "focusPanelHidden"
    /// 专注中把面板收成半透明的小伙伴（悬停展开）。
    static let focusCompanion = "focusCompanion"
    /// 浮动计时窗口被拖到哪里：窗口左上角。
    static let focusPanelTopLeft = "focusPanelTopLeft"
    static var focusMinLogSeconds: TimeInterval {
        let defaults = UserDefaults.standard
        let minutes = defaults.object(forKey: focusMinLogMinutes) == nil ? defaultFocusMinLogMinutes : defaults.integer(forKey: focusMinLogMinutes)
        return TimeInterval(max(0, minutes)) * 60
    }
}

/// 界面语言：系统会跟随 macOS 首选语言，中文和 English 可在设置中强制指定。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, chinese, english
    var id: String { rawValue }
    static var current: AppLanguage {
        UserDefaults.standard.string(forKey: Prefs.language).flatMap(Self.init(rawValue:)) ?? .system
    }
    var title: String {
        switch self { case .system: return "跟随系统 / System"; case .chinese: return "中文"; case .english: return "English" }
    }
    var locale: Locale {
        switch self {
        case .system:
            return Locale(identifier: Bundle.preferredLocalizations(from: ["zh-Hans", "en"], forPreferences: Locale.preferredLanguages).first ?? "zh-Hans")
        case .chinese: return Locale(identifier: "zh-Hans")
        case .english: return Locale(identifier: "en")
        }
    }
}

@MainActor
final class LanguageStore: ObservableObject {
    static let shared = LanguageStore()
    @Published private(set) var language: AppLanguage
    private var localeObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        language = AppLanguage(rawValue: defaults.string(forKey: Prefs.language) ?? "system") ?? .system
        localeObserver = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.language == .system else { return }
                self.objectWillChange.send()
                NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
            }
        }
    }

    deinit { if let localeObserver { NotificationCenter.default.removeObserver(localeObserver) } }

    var locale: Locale { language.locale }

    func set(_ value: AppLanguage) {
        guard value != language else { return }
        language = value
        UserDefaults.standard.set(value.rawValue, forKey: Prefs.language)
        NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
    }
}

struct LocalizedRoot<Content: View>: View {
    @ObservedObject private var languages = LanguageStore.shared
    @AppStorage(Prefs.uiScale) private var scale = 1.0
    @AppStorage(Prefs.lineSpacing) private var spacing = 2.0
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environment(\.locale, languages.locale)
            .environment(\.typography, AppTypography(scale: scale, lineSpacing: spacing))
    }
}

/// 值类型的排版配置由窗口根节点传入；只有读取它的视图随字号变化刷新。
struct AppTypography: Equatable {
    let scale: Double
    let lineSpacing: CGFloat

    init(scale: Double = 1, lineSpacing: Double = 2) {
        self.scale = scale.isFinite ? min(1.5, max(0.8, scale)) : 1
        self.lineSpacing = CGFloat(lineSpacing.isFinite ? min(10, max(0, lineSpacing)) : 2)
    }

    func pt(_ value: CGFloat) -> CGFloat { value * scale }
}

private struct TypographyKey: EnvironmentKey {
    static let defaultValue = AppTypography()
}

extension EnvironmentValues {
    var typography: AppTypography {
        get { self[TypographyKey.self] }
        set { self[TypographyKey.self] = newValue }
    }
}

/// 界面字号倍数。基准字号在各处保持原样，渲染时统一乘以倍数。
enum UIScale {
    static var factor: CGFloat {
        let value = UserDefaults.standard.double(forKey: Prefs.uiScale)
        return value == 0 ? 1 : CGFloat(value)
    }

    static func pt(_ value: CGFloat) -> CGFloat { value * factor }

    static var lineSpacing: CGFloat {
        let value = UserDefaults.standard.object(forKey: Prefs.lineSpacing) as? Double
        return CGFloat(value ?? 2.0).clamped(to: 0...10)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

private struct AppCommandsKey: EnvironmentKey {
    static let defaultValue: CommandCenter? = nil
}

extension EnvironmentValues {
    /// 视图里可选地拿到命令中心（不像 @EnvironmentObject 那样缺了就崩溃，搜索面板等地方可以没有）。
    var appCommands: CommandCenter? {
        get { self[AppCommandsKey.self] }
        set { self[AppCommandsKey.self] = newValue }
    }
}

/// 菜单栏、键盘和通知发给主界面的命令。
enum AppCommand {
    /// 选中的任务：打开截止日期、标签面板；固定、放弃、开始专注、打开笔记（键盘也能做到扇形菜单里的事）。
    case deadlineSelected, tagsSelected, pinSelected, dropSelected, focusSelected, notesSelected
    /// 选中的任务往后 / 往前挪一天（没有日期的从今天算起）。
    case postponeSelected(Int)
    case newTodo, newLog, insertLink, today, search
    case shiftDay(Int), shiftMonth(Int)
    case agenda(AgendaFilter)
    case toggleTasks, toggleDayLog, rollover
    case selectAdjacent(Int), toggleSelected, editSelected, deleteSelected, deselect
    case reveal(UUID)
    case export, backups, settings, quickCapture, notes, toggleNotes
    /// 快捷键一览。
    case shortcuts
    /// 全局快捷键触发：只有笔记已在当前桌面前台时才关闭，否则在当前桌面唤起。
    case notesHotKey(appWasActive: Bool)
    /// 打开某个任务的笔记（扇形菜单、右键菜单）。
    case notesForTask(UUID)
}

/// 别的窗口（笔记、日志）要动主窗口时用的入口；由 AppDelegate 设置，测试里都是空操作。
@MainActor
enum AppRouter {
    /// 把主窗口调到前面（它可能被收起了）。
    static var presentMain: () -> Void = {}
    /// 主窗口是不是当前的键盘窗口。
    static var mainIsKey: () -> Bool = { true }
    static var showSettings: () -> Void = {}
    static var showQuickCapture: () -> Void = {}
    /// 打开某个任务的笔记。
    static var openNotes: (UUID) -> Void = { _ in }
    /// 打开 / 收起一个面板，和对应的全局快捷键效果相同（菜单栏图标和主窗口右上角菜单都用它）。
    static var togglePanel: (HotKeyAction) -> Void = { _ in }
    /// 打开日记并定位到某条日志。
    static var openLog: (Date, UUID) -> Void = { _, _ in }
}

@MainActor
final class CommandCenter: ObservableObject {
    let subject = PassthroughSubject<AppCommand, Never>()
    func send(_ command: AppCommand) { subject.send(command) }
}

/// 窗口底部短暂出现的反馈条，可带一个操作（通常是「撤销」）。
@MainActor
final class ToastCenter: ObservableObject {
    /// 哪些操作完成后要给一个带「撤销」的提示，以及提示的文字。
    static let undoMessages = ["删除任务": "已删除事项", "删除日志": "已删除日志", "移动任务": "已移动事项", "移到今天": "已把逾期事项的截止日期改到今天",
                               "完成状态": "已更新完成状态", "放弃待办": "已放弃", "恢复待办": "已恢复", "重命名标签": "已重命名标签", "删除标签": "已删除标签（内容都保留）"]
    struct Toast: Identifiable {
        let id = UUID()
        let message: String
        let actionTitle: String?
        let action: (() -> Void)?
    }

    @Published private(set) var current: Toast?
    private var dismissal: Task<Void, Never>?

    func show(_ message: String, actionTitle: String? = nil, duration: TimeInterval = 5, action: (() -> Void)? = nil) {
        let toast = Toast(message: message, actionTitle: actionTitle, action: action)
        current = toast
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if self?.current?.id == toast.id { self?.current = nil }
        }
    }

    func dismiss() {
        dismissal?.cancel()
        current = nil
    }
}

struct ToastView: View {
    @Environment(\.typography) private var typography
    @ObservedObject var center: ToastCenter

    var body: some View {
        Group {
            if let toast = center.current {
                HStack(spacing: 12) {
                    Text(LocalizedStringKey(toast.message)).font(.system(size: typography.pt(12), weight: .medium)).lineLimit(1)
                    if let title = toast.actionTitle, let action = toast.action {
                        Button(LocalizedStringKey(title)) { action(); center.dismiss() }
                            .buttonStyle(HitAreaButtonStyle(compact: true))
                            .font(.system(size: typography.pt(12), weight: .semibold))
                            .foregroundStyle(Palette.accent)
                    }
                    Button { center.dismiss() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                        .buttonStyle(HitAreaButtonStyle(compact: true)).foregroundStyle(Palette.muted)
                        .accessibilityLabel("关闭提示")
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Palette.card, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.line))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
                .accessibilityElement(children: .combine)
            }
        }
        .animation(Motion.spring, value: center.current?.id)
    }
}

enum Motion {
    /// 测试里一律按「减少动态效果」处理：淡入淡出和弹簧动画立刻完成，不依赖屏幕是否亮着。
    static var reduced: Bool { Headless.active || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var spring: Animation? { reduced ? nil : .spring(response: 0.3, dampingFraction: 0.85) }
    static var quick: Animation? { reduced ? nil : .easeOut(duration: 0.16) }
}

/// 创建 DateFormatter 很贵，列表和日历每次重绘都要格式化日期：按语言和格式缓存。只在主线程使用。
enum DateFormatters {
    private static var cache: [String: DateFormatter] = [:]

    /// `template` 走本地化模板；否则 `format` 是固定格式。
    static func formatter(locale: Locale, template: String? = nil, format: String? = nil) -> DateFormatter {
        let zone = TimeZone.current
        let key = "\(locale.identifier)|\(template ?? "")|\(format ?? "")"
        if let cached = cache[key], cached.timeZone == zone { return cached }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = JournalDates.calendar
        formatter.timeZone = zone
        if let template { formatter.setLocalizedDateFormatFromTemplate(template) }
        if let format { formatter.dateFormat = format }
        cache[key] = formatter
        return formatter
    }
}

extension Date {
    /// 「今天 / 明天 / 10月8日」之类的短标签。
    var relativeLabel: String {
        let calendar = JournalDates.calendar
        if calendar.isDateInToday(self) { return AppLocalized("今天") }
        if calendar.isDateInTomorrow(self) { return AppLocalized("明天") }
        if calendar.isDateInYesterday(self) { return AppLocalized("昨天") }
        let template = calendar.isDate(self, equalTo: Date(), toGranularity: .year) ? "MMMd" : "yMMMd"
        return DateFormatters.formatter(locale: AppLanguage.current.locale, template: template).string(from: self)
    }
}
