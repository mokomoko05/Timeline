import AppKit

/// 单元测试里运行时：窗口不能真的出现在用户屏幕上闪动，也不能抢走前台。
enum Headless {
    static let active: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    /// 把应用调到前台；测试里什么都不做。
    @MainActor
    static func activateApp() {
        guard !active else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// 日页所有窗口的基类。平时和 NSWindow 完全一样；测试环境下窗口照常"显示"（isVisible、焦点、层级关系都正常，
/// 断言不受影响），但实际透明度恒为 0、不接收鼠标，所以屏幕上什么也看不到。
/// `alphaValue` 在测试里只记录「逻辑值」，淡入淡出的代码读到的和平时一样。
class QuietWindow: NSWindow {
    private var logicalAlpha: CGFloat = 1

    override var alphaValue: CGFloat {
        get { Headless.active ? logicalAlpha : super.alphaValue }
        set {
            guard Headless.active else { super.alphaValue = newValue; return }
            logicalAlpha = newValue
            silence()
        }
    }

    /// 窗口真正画出来的透明度（测试用来确认没有窗口真的可见）。
    var actualAlpha: CGFloat { super.alphaValue }

    private func silence() {
        guard Headless.active else { return }
        super.alphaValue = 0
        ignoresMouseEvents = true
    }

    override func orderFront(_ sender: Any?) { silence(); super.orderFront(sender) }
    override func makeKeyAndOrderFront(_ sender: Any?) { silence(); super.makeKeyAndOrderFront(sender) }
    override func orderFrontRegardless() { silence(); super.orderFrontRegardless() }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place != .out { silence() }
        super.order(place, relativeTo: otherWin)
    }
}
