import AppKit

@MainActor
final class ScreenBoundDragging {
    private var drag: (mouse: NSPoint, origin: NSPoint, moving: Bool, titlebar: Bool)?
    private let mouseLocation: () -> NSPoint
    private let defaults: UserDefaults

    init(mouseLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation }, defaults: UserDefaults = .standard) {
        self.mouseLocation = mouseLocation
        self.defaults = defaults
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
        case "zoom", "maximize": if window.styleMask.contains(.resizable) { window.performZoom(nil) }
        default: break
        }
    }

    func filter(_ event: NSEvent, in window: NSWindow) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            drag = nil
            guard window.isMovable, !window.styleMask.contains(.fullScreen), let content = window.contentView else { break }
            let point = event.locationInWindow
            if window.styleMask.contains(.resizable),
               point.x < 5 || point.x > window.frame.width - 5 || point.y < 5 || point.y > window.frame.height - 5 { break }
            let inTitlebar = window.styleMask.contains(.titled) && point.y >= window.contentLayoutRect.maxY
            let root = inTitlebar ? content.superview ?? content : content
            let hitPoint = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            guard let hit = root.hitTest(hitPoint), hit.mouseDownCanMoveWindow else { break }
            var ancestor: NSView? = hit
            while let view = ancestor {
                if view is NSControl { return event }
                ancestor = view.superview
            }
            let titlebar = inTitlebar && !hit.isDescendant(of: content)
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
                drag = current
                var target = window.frame
                // NSWindow 的屏幕原点会取整；先使用相同粒度，避免半点目标不断触发无效移动。
                target.origin = NSPoint(x: (current.origin.x + dx).rounded(), y: (current.origin.y + dy).rounded())
                target = window.constrainFrameRect(target, to: nil)
                if target.origin != window.frame.origin { window.setFrameOrigin(target.origin) }
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

class ScreenBoundWindow: NSWindow {
    private let dragging = ScreenBoundDragging()
    private var screenObserver: NSObjectProtocol?
    /// 实际屏幕可用区域；测试替身只替换显示器信息，不替换约束路径。
    var screenVisibleFrames: [NSRect] { NSScreen.screens.map(\.visibleFrame) }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
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
}

class QuietPanel: NSPanel {
    private let dragging = ScreenBoundDragging()
    private var screenObserver: NSObjectProtocol?
    var screenVisibleFrames: [NSRect] { NSScreen.screens.map(\.visibleFrame) }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
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
}
