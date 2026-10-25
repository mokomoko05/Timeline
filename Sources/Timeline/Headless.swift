import AppKit

/// 单元测试里运行时：窗口不能真的出现在用户屏幕上闪动，也不能抢走前台。
enum Headless {
    /// 第一次读到时（测试进程里）顺手装上窗口静音：几乎所有建窗口的代码都会先问一句 `Headless.active`。
    static let active: Bool = {
        let active = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        if active { installWindowSilencing() }
        return active
    }()

    /// 测试结束时还真的画在屏幕上的窗口（逐个用例检查）。守门测试据此报错。
    @MainActor static var visibleOrders: [String] = []

    /// 测试进程里所有窗口在窗口服务器那边的透明度恒为 0，屏幕上什么也看不到：
    /// - `alphaValue` 的设置只记成「逻辑值」，读到的还是它，淡入淡出、复位透明度的代码照常工作；
    /// - 显示（order）前再压一次，浮窗（NSPopover）、sheet 这类系统建的窗口也一样；
    /// - 关掉窗口出现/消失的系统动画、透明度渐变动画（`animator().alphaValue` 在窗口服务器里渐变，绕过上面的设置）
    ///   和浮窗弹出动画（动画中途会以半透明画出来）。
    /// 压不住的只有 sheet 滑入（窗口服务器自己的动画）：测试里不要真的弹 sheet。
    /// 由 `active` 自动装上，重复调用无害。
    static func silenceWindows() { _ = active }

    /// 窗口真正交给窗口服务器的透明度（测试用来确认没有窗口真的可见）。
    static func actualAlpha(of window: NSWindow) -> CGFloat {
        silencingInstalled ? window.headlessAlphaValue() : window.alphaValue
    }

    /// 测试里不在屏幕上画出来的窗口（逻辑上可见、真实透明度大于 0）。
    @MainActor static func drawnWindows() -> [NSWindow] {
        NSApplication.shared.windows.filter { $0.isVisible && actualAlpha(of: $0) > 0 }
    }

    private nonisolated(unsafe) static var silencingInstalled = false

    private static func installWindowSilencing() {
        guard !silencingInstalled else { return }
        silencingInstalled = true
        let pairs: [(Selector, Selector)] = [
            (#selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.headlessOrder(_:relativeTo:))),
            (#selector(setter: NSWindow.alphaValue), #selector(NSWindow.headlessSetAlphaValue(_:))),
            (#selector(getter: NSWindow.alphaValue), #selector(NSWindow.headlessAlphaValue)),
        ]
        for (original, replacement) in pairs {
            exchange(NSWindow.self, original, replacement)
        }
        exchange(NSWindow.self, #selector(NSWindow.animation(forKey:)), #selector(NSWindow.headlessAnimation(forKey:)))
        exchange(NSPopover.self, #selector(getter: NSPopover.animates), #selector(NSPopover.headlessAnimates))
    }

    private static func exchange(_ type: AnyClass, _ original: Selector, _ replacement: Selector) {
        if let a = class_getInstanceMethod(type, original), let b = class_getInstanceMethod(type, replacement) {
            method_exchangeImplementations(a, b)
        }
    }

    /// 把应用调到前台；测试里什么都不做。
    @MainActor
    static func activateApp() {
        guard !active else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private nonisolated(unsafe) var logicalAlphaKey: UInt8 = 0

/// 下面三个方法和 NSWindow 原来的实现交换过（只在测试进程里）：方法体里调用自己，调到的其实是原来的实现。
extension NSWindow {
    private var logicalAlpha: CGFloat? {
        get { (objc_getAssociatedObject(self, &logicalAlphaKey) as? NSNumber).map { CGFloat($0.doubleValue) } }
        set { objc_setAssociatedObject(self, &logicalAlphaKey, newValue.map { NSNumber(value: Double($0)) }, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    @objc fileprivate func headlessOrder(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place != .out {
            if logicalAlpha == nil { logicalAlpha = headlessAlphaValue() }
            headlessSetAlphaValue(0)
            animationBehavior = .none
        }
        headlessOrder(place, relativeTo: otherWin)
    }

    @objc fileprivate func headlessSetAlphaValue(_ value: CGFloat) {
        logicalAlpha = value
        headlessSetAlphaValue(0)
    }

    @objc fileprivate func headlessAlphaValue() -> CGFloat {
        logicalAlpha ?? headlessAlphaValue()
    }

    /// 透明度没有动画：`animator().alphaValue = x` 直接落到上面的设置上。
    @objc fileprivate func headlessAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "alphaValue" ? nil : headlessAnimation(forKey: key)
    }
}

extension NSPopover {
    @objc fileprivate func headlessAnimates() -> Bool { false }
}

/// 日页所有窗口的基类。平时和 NSWindow 完全一样；测试环境下窗口照常"显示"（isVisible、焦点、层级关系都正常，
/// 断言不受影响），但实际透明度恒为 0、不接收鼠标，所以屏幕上什么也看不到。
/// `alphaValue` 在测试里只记录「逻辑值」，淡入淡出的代码读到的和平时一样。
class QuietWindow: NSWindow {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        silence()
    }

    /// 窗口真正画出来的透明度（测试用来确认没有窗口真的可见）。
    var actualAlpha: CGFloat { Headless.actualAlpha(of: self) }

    private func silence() {
        guard Headless.active else { return }
        ignoresMouseEvents = true
    }

    override func orderFront(_ sender: Any?) { silence(); super.orderFront(sender) }
    override func makeKeyAndOrderFront(_ sender: Any?) { silence(); super.makeKeyAndOrderFront(sender) }
    override func orderFrontRegardless() { silence(); super.orderFrontRegardless() }
}
