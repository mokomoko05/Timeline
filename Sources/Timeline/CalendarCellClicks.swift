import AppKit
import SwiftUI

struct CalendarCellClicks: NSViewRepresentable {
    let select: () -> Void
    let expand: () -> Void
    /// 格内按钮（勾选框）的区域：点击它们只切换完成状态，不触发选中日期。
    var excluded: [CGRect] = []

    func makeNSView(context: Context) -> CalendarClickView {
        let view = CalendarClickView()
        view.installMonitor()
        return view
    }

    func updateNSView(_ view: CalendarClickView, context: Context) {
        view.select = select
        view.expand = expand
        view.excluded = excluded
    }

    static func dismantleNSView(_ view: CalendarClickView, coordinator: ()) { view.removeMonitor() }
}

final class CalendarClickView: NSView {
    var select: (() -> Void)?
    var expand: (() -> Void)?
    var excluded: [CGRect] = []
    private var origin: NSPoint?
    private var dragged = false
    private var monitor: Any?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, let window, event.window === window, window.attachedSheet == nil else { return event }
            track(event.type, at: convert(event.locationInWindow, from: nil), clickCount: event.clickCount)
            return event
        }
    }

    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func track(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 1) {
        switch type {
        case .leftMouseDown:
            origin = bounds.contains(point) && !excluded.contains(where: { $0.contains(point) }) ? point : nil
            dragged = false
        case .leftMouseDragged:
            if let origin, hypot(point.x - origin.x, point.y - origin.y) > 4 { dragged = true }
        case .leftMouseUp:
            let activate = origin != nil && !dragged && bounds.contains(point)
            origin = nil
            guard activate else { return }
            select?()
            if clickCount == 2 { expand?() }
        default: break
        }
    }
}
