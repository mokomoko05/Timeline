import AppKit
import SwiftUI
import DayleafCore

private final class DayLogWindow: QuietWindow {
    /// 没有文字框处理 Esc 时关闭窗口。
    override func cancelOperation(_ sender: Any?) { close() }
}

/// 日志窗口正在看哪一天。
@MainActor
final class DayLogDay: ObservableObject {
    @Published var date = JournalDates.calendar.startOfDay(for: Date())
}

/// 当天日志窗口（⌘J）：独立窗口，可以拖边缘调整大小；大小和位置会被记住。
/// 和主窗口、笔记、终端互不依赖，各自开关。
@MainActor
final class DayLogWindowController: NSObject, NSWindowDelegate {
    static let defaultFrameName = "DayleafDayLogWindow"
    static let shared = DayLogWindowController()
    /// 窗口大小、位置保存在偏好里的名字（测试里换成独立的名字）。
    let frameName: String

    init(frameName: String = "DayleafDayLogWindow") {
        self.frameName = frameName
        super.init()
    }
    private(set) var window: NSWindow?
    var interaction = WorkspaceInteraction()
    /// 日志窗口自己的提示条：复制、删除的「撤销」出现在这个窗口里，而不是主窗口。
    let toast = ToastCenter()
    /// 正在看的那一天：窗口一直复用同一个视图，换日期只改这个，选中和编辑状态不会因为重新打开而丢掉。
    let day = DayLogDay()
    private var store: JournalStore?
    /// 关闭后，Scheduler 别的窗口还开着就把焦点交给它；由 AppDelegate 设置。
    var handoffWindow: () -> NSWindow? = { nil }
    /// 点日志里的任务标签跳到主窗口的任务：把主窗口调到前面；由 AppDelegate 设置。
    var showMainWindow: () -> Void = {}

    var isVisible: Bool { window?.isVisible == true }

    /// 打开某一天的日志；已经开着就复用同一个窗口，切到这一天。
    func show(store: JournalStore, date: Date) {
        let window = self.window ?? makeWindow()
        self.window = window
        setDate(date)
        if self.store !== store, let host = window.contentViewController as? NSHostingController<AnyView> {
            self.store = store
            let view = DayLogView(store: store, day: day, close: { [weak self] in self?.close() },
                                  showMain: { [weak self] in self?.showMainWindow() })
                .environmentObject(interaction).environmentObject(toast)
            host.rootView = AnyView(LocalizedRoot { view })
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// 换到某一天（主窗口选了别的日期时也会调用）。先提交正在编辑的内容。
    func setDate(_ date: Date) {
        let start = JournalDates.calendar.startOfDay(for: date)
        guard day.date != start else { return }
        NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
        day.date = start
    }

    /// 前一天 / 后一天（日志窗口是当前窗口时，菜单里的「前一天」「后一天」作用在这里）。
    func shift(_ days: Int) {
        setDate(JournalDates.calendar.date(byAdding: .day, value: days, to: day.date) ?? day.date)
    }

    var isKey: Bool { window?.isKeyWindow == true }

    func close() { window?.close() }

    func toggle(store: JournalStore, date: Date) {
        if isVisible { close() } else { show(store: store, date: date) }
    }

    static let minSize = NSSize(width: 760, height: 480)

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: AnyView(LocalizedRoot { EmptyView() }))
        let window = DayLogWindow(contentViewController: host)
        window.title = "当天日志"
        // 和笔记窗口一样没有红绿灯：用 Esc、⌘J 或「完成」关闭；标题栏透明，空白处可以拖动窗口。
        window.styleMask = [.titled, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = Self.minSize
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.delegate = self
        if !window.setFrameUsingName(frameName) {
            window.setContentSize(NSSize(width: 1040, height: 700))
            window.center()
        }
        window.setFrameAutosaveName(frameName)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, NSApplication.shared.isActive else { return }
            PreviousApp.restore(handoff: handoffWindow())
        }
    }
}
