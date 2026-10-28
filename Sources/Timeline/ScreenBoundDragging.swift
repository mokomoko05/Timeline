import AppKit

@MainActor
final class ScreenBoundDragging {
    private var drag: (mouse: NSPoint, origin: NSPoint, moving: Bool, titlebar: Bool)?

    func filter(_ event: NSEvent, in window: NSWindow) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            drag = nil
            guard window.isMovable, !window.styleMask.contains(.fullScreen), let content = window.contentView else { break }
            let point = event.locationInWindow
            if window.styleMask.contains(.resizable),
               point.x < 5 || point.x > window.frame.width - 5 || point.y < 5 || point.y > window.frame.height - 5 { break }
            let titlebar = window.styleMask.contains(.titled) && point.y >= window.contentLayoutRect.maxY
            let root = titlebar ? content.superview ?? content : content
            let hitPoint = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            guard let hit = root.hitTest(hitPoint), hit.mouseDownCanMoveWindow else { break }
            if titlebar, hit is NSControl { break }
            if titlebar { window.makeKeyAndOrderFront(nil) }
            if titlebar && event.clickCount == 2 {
                window.performZoom(nil)
                return nil
            }
            drag = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin, false, titlebar)
            if titlebar { return nil }
        case .leftMouseDragged:
            if var current = drag {
                let mouse = window.convertPoint(toScreen: event.locationInWindow)
                let dx = mouse.x - current.mouse.x, dy = mouse.y - current.mouse.y
                if !current.moving && hypot(dx, dy) < 3 { return current.titlebar ? nil : event }
                current.moving = true
                drag = current
                var target = window.frame
                target.origin = NSPoint(x: current.origin.x + dx, y: current.origin.y + dy)
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
    private let dragging = ScreenBoundDragging()

    override func sendEvent(_ event: NSEvent) {
        if let event = dragging.filter(event, in: self) { super.sendEvent(event) }
    }
}

class QuietPanel: NSPanel {
    private let dragging = ScreenBoundDragging()

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        if Headless.active { ignoresMouseEvents = true }
    }

    override func sendEvent(_ event: NSEvent) {
        if let event = dragging.filter(event, in: self) { super.sendEvent(event) }
    }
}
