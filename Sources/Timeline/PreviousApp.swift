import AppKit

/// 主窗口和终端共用的「刚才在用的应用」。两组窗口各自独立开关：
/// 收起其中一组时，如果 Timeline 的另一组窗口还开着，就把焦点交给它；只有 Timeline 再没有可见窗口，才回到刚才的应用。
@MainActor
enum PreviousApp {
    static var app: NSRunningApplication?

    /// Timeline 不在前台、要被唤起时，记下当前前台应用（只在第一次唤起时记，之后在两组窗口之间切换不覆盖）。
    static func remember() {
        guard !NSApplication.shared.isActive,
              let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        app = front
    }

    /// 一组窗口收起之后调用。`handoff` 是 Timeline 另一组仍然可见的窗口。
    static func restore(handoff: NSWindow?) {
        if let handoff {
            handoff.makeKeyAndOrderFront(nil)
            return
        }
        defer { app = nil }
        guard !Headless.active else { return }
        if let app, !app.isTerminated {
            app.activate(options: [])
        } else if #available(macOS 14, *) {
            // 只让出前台，不隐藏整个应用，否则会带走专注小窗等其他浮动窗口。
            NSApplication.shared.deactivate()
        } else {
            NSApplication.shared.hide(nil)
        }
    }
}
