import AppKit

/// SwiftTerm 在收到 shell 的隐藏 / 显示插入点指令时增删 caret 子视图，重建光标区域。
/// AppKit「隐藏到鼠标移动」的状态会被重置，连续输入时指针反复出现。
/// 在一段输入期间成对 hide / unhide，只有真实鼠标操作、失焦或换页才恢复。
@MainActor
final class TerminalPointerHiding {
    static let shared = TerminalPointerHiding()
    private(set) var hidden = false
    private var monitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private let setHidden: (Bool) -> Void

    init(setHidden: @escaping (Bool) -> Void = { hidden in
        guard !Headless.active else { return }
        if hidden { NSCursor.hide() } else { NSCursor.unhide() }
    }) { self.setHidden = setHidden }

    func hide(in window: NSWindow) {
        guard !hidden else { return }
        hidden = true
        setHidden(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                               .leftMouseDragged, .rightMouseDragged, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.restore() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.restore() }
        }
        for (name, object) in [(NSApplication.didResignActiveNotification, nil), (NSWindow.didResignKeyNotification, window as Any?)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restore() }
            })
        }
    }

    func restore() {
        guard hidden else { return }
        hidden = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        setHidden(false)
    }
}
