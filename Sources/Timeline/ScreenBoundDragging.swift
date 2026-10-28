import AppKit

@MainActor
final class ScreenBoundDragging {
    private var drag: (mouse: NSPoint, origin: NSPoint, moving: Bool, titlebar: Bool)?
    private let eventScreenLocation: ((NSEvent) -> NSPoint)?
    private let mouseLocation: () -> NSPoint

    init(eventScreenLocation: ((NSEvent) -> NSPoint)? = nil, mouseLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation }) {
        self.eventScreenLocation = eventScreenLocation
        self.mouseLocation = mouseLocation
    }

    func send(_ event: NSEvent, in window: NSWindow, forward: (NSEvent) -> Void) {
        guard let event = filter(event, in: window) else { return }
        let movable = window.isMovable
        let suspendsMovement = event.type == .leftMouseDown && drag != nil
        if suspendsMovement { window.isMovable = false }
        defer { if suspendsMovement { window.isMovable = movable } }
        forward(event)
    }

    private func screenLocation(of event: NSEvent) -> NSPoint {
        if let eventScreenLocation { return eventScreenLocation(event) }
        // AppKit 可能按窗口的新位置重建 event.cgEvent 的屏幕坐标。拖动期间窗口一直在变，
        // 对排队事件再做这种换算会反复叠加偏移，贴边时尤其容易来回跳。
        // 直接跟随窗口坐标系之外的当前指针；旧事件最多重复最新目标，不追赶旧位置。
        return mouseLocation()
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
                window.performZoom(nil)
                return nil
            }
            drag = (screenLocation(of: event), window.frame.origin, false, titlebar)
            if titlebar { return nil }
        case .leftMouseDragged:
            if var current = drag {
                let mouse = screenLocation(of: event)
                let dx = mouse.x - current.mouse.x, dy = mouse.y - current.mouse.y
                if !current.moving && hypot(dx, dy) < 3 { return current.titlebar ? nil : event }
                current.moving = true
                drag = current
                var target = window.frame
                // NSWindow 的屏幕原点会取整；先使用相同粒度，避免半点目标不断触发无效移动。
                target.origin = NSPoint(x: (current.origin.x + dx).rounded(), y: (current.origin.y + dy).rounded())
                let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? window.screen ?? NSScreen.main
                if let screen { target = Self.clamp(target, to: screen.visibleFrame) }
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

    nonisolated static func clamp(_ frame: NSRect, to visible: NSRect) -> NSRect {
        var frame = frame
        frame.origin.x = max(min(frame.origin.x, visible.maxX - frame.width), visible.minX)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        return frame
    }
}

class ScreenBoundWindow: NSWindow {
    var dragging = ScreenBoundDragging()

    override func sendEvent(_ event: NSEvent) {
        dragging.send(event, in: self) { super.sendEvent($0) }
    }
}

class QuietPanel: NSPanel {
    var dragging = ScreenBoundDragging()

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        if Headless.active { ignoresMouseEvents = true }
    }

    override func sendEvent(_ event: NSEvent) {
        dragging.send(event, in: self) { super.sendEvent($0) }
    }
}
