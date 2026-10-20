import AppKit

/// Timeline 不在前台（切到了别的应用）时，把「工作窗口」立刻收起来：主窗口、笔记、当天日志、终端、设置。
/// 快速日志 / 待办面板和专注计时窗口不在名单里，它们本来就是悬浮的，失焦后仍留在屏幕上。
///
/// 判断的依据是**整个应用**是否失去前台，不是某个窗口是否还是键盘窗口：在 Timeline 自己的窗口之间切换、
/// 弹出选择器 / 菜单 / 对话框都不算失焦。收起只是 `orderOut`，位置、大小、草稿、终端里的程序都原样保留，
/// 用快捷键或点 Dock 图标再唤起即可。
@MainActor
final class AutoHideOnResign {
    /// 偏好：失去前台时是否自动收起（默认开）。
    static let prefKey = "autoHideOnResign"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: prefKey) == nil ? true : defaults.bool(forKey: prefKey)
    }

    /// 要收起的窗口（只收可见的）。
    var windows: () -> [NSWindow?]
    /// 额外的收起动作（终端：它有自己的一组窗口）。
    var extraHide: () -> Void
    var defaults: UserDefaults
    private var observer: NSObjectProtocol?
    /// 最近一次真的收起了几个窗口（测试用）。
    private(set) var lastHiddenCount = 0

    init(defaults: UserDefaults = .standard, windows: @escaping () -> [NSWindow?], extraHide: @escaping () -> Void = {}) {
        self.defaults = defaults
        self.windows = windows
        self.extraHide = extraHide
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appResignedActive() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func appResignedActive() {
        guard Self.isEnabled(defaults), !NSApplication.shared.isActive else { return }
        hideNow()
    }

    /// 立刻收起所有工作窗口。不做「交还焦点」：用户已经在别的应用里了，再去激活原来的应用会把他拉回去。
    @discardableResult
    func hideNow() -> Int {
        let visible = windows().compactMap { $0 }.filter { $0.isVisible && !$0.isMiniaturized }
        if !visible.isEmpty { NotificationCenter.default.post(name: .timelineCommitEditing, object: nil) }
        for window in visible {
            WindowFade.reset(window)
            window.orderOut(nil)
        }
        extraHide()
        PreviousApp.app = nil
        lastHiddenCount = visible.count
        return visible.count
    }
}
