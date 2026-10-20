import AppKit
import SwiftUI

/// 主窗口里点了待办以外的地方，就取消对待办的选中（聚焦）。
///
/// 只看左键按下的位置是否落在某一行待办上（行的位置由清单上报，并且和清单可见区域取交集，滚到看不见的行不算）。
/// 判断放在事件处理**之后**：这样点「笔记」按钮之类时，按钮还能用到当前选中的任务；
/// 如果这次点击本身选中了别的任务（比如点日历格子里的事项），也不会被清掉。
@MainActor
final class TaskRowRegions {
    /// 每行待办在主窗口内容里的位置（左上角为原点，和 SwiftUI 的 .global 一致）。
    var rows: [UUID: CGRect] = [:]
    /// 清单可见区域；行要在这里面才算点得到。
    var viewport: CGRect = .null

    func containsRow(at point: CGPoint) -> Bool {
        rows.values.contains { frame in
            let visible = viewport.isNull ? frame : frame.intersection(viewport)
            return !visible.isNull && visible.contains(point)
        }
    }
}

struct TaskRowGlobalFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
}

struct ClickAwayDeselect: NSViewRepresentable {
    let regions: TaskRowRegions
    let selection: () -> UUID?
    let deselect: () -> Void

    func makeNSView(context: Context) -> ClickAwayView {
        let view = ClickAwayView()
        update(view)
        return view
    }

    func updateNSView(_ view: ClickAwayView, context: Context) { update(view) }

    private func update(_ view: ClickAwayView) {
        view.regions = regions
        view.selection = selection
        view.deselect = deselect
    }

    final class ClickAwayView: NSView {
        var regions: TaskRowRegions?
        var selection: () -> UUID? = { nil }
        var deselect: () -> Void = {}
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        /// 按下时记下当时的选中项和点的位置；事件处理完之后再决定要不要取消选中。
        func handle(_ event: NSEvent) {
            guard let window, event.window === window, let content = window.contentView, let regions else { return }
            let point = content.convert(event.locationInWindow, from: nil)
            let flipped = content.isFlipped ? point : CGPoint(x: point.x, y: content.bounds.height - point.y)
            guard let before = selection(), !regions.containsRow(at: flipped) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selection() == before else { return }
                self.deselect()
            }
        }
    }
}
