import AppKit

/// 系统窗口移动始终关闭；是否允许用户拖动，由应用自己的拖动器决定。
@MainActor
protocol ScreenBoundMovable: AnyObject {
    var allowsScreenBoundDragging: Bool { get set }
}

@MainActor
final class ScreenBoundDragging {
    private var drag: (mouse: NSPoint, origin: NSPoint, moving: Bool, titlebar: Bool)?
    private let mouseLocation: () -> NSPoint
    private let defaults: UserDefaults

    init(mouseLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation }, defaults: UserDefaults = .standard) {
        self.mouseLocation = mouseLocation
        self.defaults = defaults
    }

    private func canMove(_ window: NSWindow) -> Bool {
        (window as? ScreenBoundMovable)?.allowsScreenBoundDragging ?? window.isMovable
    }

    func send(_ event: NSEvent, in window: NSWindow, forward: (NSEvent) -> Void) {
        guard let event = filter(event, in: window) else { return }
        let movable = window.isMovable
        let suspendsMovement = event.type == .leftMouseDown && drag != nil
        if suspendsMovement { window.isMovable = false }
        defer { if suspendsMovement { window.isMovable = movable } }
        forward(event)
    }

    func doubleClickTitlebar(in window: NSWindow) {
        // 读取系统全局偏好；旧版系统只有 AppleMiniaturizeOnDoubleClick。
        let action = defaults.string(forKey: "AppleActionOnDoubleClick")?.lowercased()
            ?? (defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") ? "minimize" : "zoom")
        switch action {
        case "minimize": if window.styleMask.contains(.miniaturizable) { window.performMiniaturize(nil) }
        case "none": break
        // 新系统的 Fill / 未识别值沿用默认缩放，避免静默吞掉双击。
        default: if window.styleMask.contains(.resizable) { window.performZoom(nil) }
        }
    }

    /// AppKit 自己认定可拖的按下（标题栏里的主题框架、透明标题栏下没接住点击的内容）会同步调用 performDrag；
    /// 默认实现把整段拖动交给窗口服务器，不经过 constrainFrameRect，窗口能拖出屏幕边缘。
    /// 这里改为接管随后的拖动事件，和标题栏拖动一样按屏幕边界移动。
    func performDrag(with event: NSEvent, in window: NSWindow, native: (NSEvent) -> Void) {
        guard event.type == .leftMouseDown, !window.styleMask.contains(.fullScreen) else { return native(event) }
        guard canMove(window) else { return }
        drag = (mouseLocation(), window.frame.origin, false, true)
    }

    func filter(_ event: NSEvent, in window: NSWindow) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            drag = nil
            guard canMove(window), !window.styleMask.contains(.fullScreen), let content = window.contentView else { break }
            let point = event.locationInWindow
            if window.styleMask.contains(.resizable),
               point.x < 5 || point.x > window.frame.width - 5 || point.y < 5 || point.y > window.frame.height - 5 { break }
            let inTitlebar = window.styleMask.contains(.titled) && point.y >= window.contentLayoutRect.maxY
            let root = inTitlebar ? content.superview ?? content : content
            let hitPoint = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            let hit = root.hitTest(hitPoint)
            var ancestor: NSView? = hit
            while let view = ancestor {
                if view is NSControl || view is NSTextView { return event }
                ancestor = view.superview
            }
            let titlebar = inTitlebar && (hit.map { !$0.isDescendant(of: content) } ?? true)
            // 全尺寸透明标题栏可能命中内容本身：先把按下交给按钮，
            // 超过拖动阈值才移动窗口；不能依赖系统再补发 performDrag。
            guard inTitlebar || hit?.mouseDownCanMoveWindow == true else { break }
            if titlebar { window.makeKeyAndOrderFront(nil) }
            if titlebar && event.clickCount == 2 {
                doubleClickTitlebar(in: window)
                return nil
            }
            drag = (mouseLocation(), window.frame.origin, false, titlebar)
            if titlebar { return nil }
        case .leftMouseDragged:
            if var current = drag {
                // 当前指针独立于正在移动的窗口；积压事件不会叠加窗口偏移。
                let mouse = mouseLocation()
                let dx = mouse.x - current.mouse.x, dy = mouse.y - current.mouse.y
                if !current.moving && hypot(dx, dy) < 3 { return current.titlebar ? nil : event }
                current.moving = true
                var target = window.frame
                // NSWindow 的屏幕原点会取整；先使用相同粒度，避免半点目标不断触发无效移动。
                target.origin = NSPoint(x: (current.origin.x + dx).rounded(), y: (current.origin.y + dy).rounded())
                target = window.constrainFrameRect(target, to: nil)
                if target.origin != window.frame.origin { window.setFrameOrigin(target.origin) }
                // 到边缘就丢弃越界位移；否则反向拖动还要先走完累计的越界距离。
                // 保留未取整的小数位移，慢拖时也不会一顿一顿地丢掉半像素。
                let proposed = NSPoint(x: current.origin.x + dx, y: current.origin.y + dy)
                current.origin = NSPoint(x: target.origin.x == proposed.x.rounded() ? proposed.x : window.frame.minX,
                                         y: target.origin.y == proposed.y.rounded() ? proposed.y : window.frame.minY)
                current.mouse = mouse
                drag = current
                return nil
            }
        case .leftMouseUp:
            if let current = drag {
                drag = nil
                if current.titlebar { return nil }
                if current.moving {
                    return NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -10_000, y: -10_000),
                                              modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                              windowNumber: event.windowNumber, context: nil,
                                              eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure)
                }
            }
        default:
            break
        }
        return event
    }

}

class ScreenBoundWindow: NSWindow, ScreenBoundMovable {
    var allowsScreenBoundDragging = true
    var dragMouseLocation: NSPoint { NSEvent.mouseLocation }
    private lazy var dragging = ScreenBoundDragging(mouseLocation: { [unowned self] in self.dragMouseLocation })
    private var screenObserver: NSObjectProtocol?
    /// 实际屏幕可用区域；测试替身只替换显示器信息，不替换约束路径。
    var screenVisibleFrames: [NSRect] { NSScreen.screens.map(\.visibleFrame) }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        // 标题栏的窗口服务器拖动不经过 sendEvent / constrainFrameRect；
        // 必须在显示前就关闭，不能只在转发 mouseDown 的片刻暂停它。
        isMovable = false
        isMovableByWindowBackground = false
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.setFrame(self.frame, display: true)
            }
        }
    }

    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard !styleMask.contains(.fullScreen) else { return frameRect }
        if inLiveResize {
            return WindowScreenBounds.constrainResize(frameRect, current: frame, minimum: minSize, to: screenVisibleFrames,
                                                     fallback: screen?.visibleFrame ?? NSScreen.main?.visibleFrame)
        }
        return WindowScreenBounds.constrain(frameRect, to: screenVisibleFrames, fallback: screen?.visibleFrame ?? NSScreen.main?.visibleFrame)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(constrainFrameRect(frameRect, to: nil), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate: Bool) {
        super.setFrame(constrainFrameRect(frameRect, to: nil), display: flag, animate: animate)
    }

    override func setFrameOrigin(_ point: NSPoint) { setFrame(NSRect(origin: point, size: frame.size), display: false) }
    override func setFrameTopLeftPoint(_ point: NSPoint) {
        setFrameOrigin(NSPoint(x: point.x, y: point.y - frame.height))
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place != .out { setFrame(frame, display: false) }
        super.order(place, relativeTo: otherWin)
    }

    override func sendEvent(_ event: NSEvent) {
        dragging.send(event, in: self) { super.sendEvent($0) }
    }

    override func performDrag(with event: NSEvent) {
        dragging.performDrag(with: event, in: self) { super.performDrag(with: $0) }
    }
}

class QuietPanel: NSPanel, ScreenBoundMovable {
    var allowsScreenBoundDragging = true
    var dragMouseLocation: NSPoint { NSEvent.mouseLocation }
    private lazy var dragging = ScreenBoundDragging(mouseLocation: { [unowned self] in self.dragMouseLocation })
    private var screenObserver: NSObjectProtocol?
    var screenVisibleFrames: [NSRect] { NSScreen.screens.map(\.visibleFrame) }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        // 标题栏的窗口服务器拖动不经过 sendEvent / constrainFrameRect；
        // 必须在显示前就关闭，不能只在转发 mouseDown 的片刻暂停它。
        isMovable = false
        isMovableByWindowBackground = false
        if Headless.active { ignoresMouseEvents = true }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.setFrame(self.frame, display: true)
            }
        }
    }

    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard !styleMask.contains(.fullScreen) else { return frameRect }
        if inLiveResize {
            return WindowScreenBounds.constrainResize(frameRect, current: frame, minimum: minSize, to: screenVisibleFrames,
                                                     fallback: screen?.visibleFrame ?? NSScreen.main?.visibleFrame)
        }
        return WindowScreenBounds.constrain(frameRect, to: screenVisibleFrames, fallback: screen?.visibleFrame ?? NSScreen.main?.visibleFrame)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(constrainFrameRect(frameRect, to: nil), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate: Bool) {
        super.setFrame(constrainFrameRect(frameRect, to: nil), display: flag, animate: animate)
    }

    override func setFrameOrigin(_ point: NSPoint) { setFrame(NSRect(origin: point, size: frame.size), display: false) }
    override func setFrameTopLeftPoint(_ point: NSPoint) {
        setFrameOrigin(NSPoint(x: point.x, y: point.y - frame.height))
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place != .out { setFrame(frame, display: false) }
        super.order(place, relativeTo: otherWin)
    }

    override func sendEvent(_ event: NSEvent) {
        dragging.send(event, in: self) { super.sendEvent($0) }
    }

    override func performDrag(with event: NSEvent) {
        dragging.performDrag(with: event, in: self) { super.performDrag(with: $0) }
    }
}
