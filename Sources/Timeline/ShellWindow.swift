import AppKit
import SwiftTerm
import SwiftUI

/// 窗口的柔和淡入淡出，主窗口和内置终端窗口共用。
@MainActor
enum WindowFade {
    /// 窗口上弹出的 sheet（笔记、搜索、备份等）是独立的附属窗口，必须和主窗口一起渐变，否则会在主窗口消失后才突然消失。
    static func family(of window: NSWindow) -> [NSWindow] {
        var result = [window]
        var current = window.attachedSheet
        while let sheet = current {
            result.append(sheet)
            current = sheet.attachedSheet
        }
        return result + (window.childWindows ?? [])
    }

    /// 把整个窗口家族的透明度恢复为 1（隐藏之后复位，下次显示才不会是透明的）。
    static func reset(_ window: NSWindow) {
        for member in family(of: window) { member.alphaValue = 1 }
    }

    static func animate(_ window: NSWindow, to alpha: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for member in family(of: window) { member.animator().alphaValue = alpha }
        }, completionHandler: {
            MainActor.assumeIsolated { completion?() }
        })
    }
}

/// 一个窗格里的终端。焦点变化由所在窗口的 makeFirstResponder 感知，用来高亮当前窗格。
final class PaneTerminalView: LocalProcessTerminalView {
    /// 回滚行数：默认 500 行对长时间的 agent 对话太少。
    static let scrollbackLines = 10_000

    /// 底色、前景、光标、选区和 16 色 ANSI 都取自应用配色，随深浅外观切换。
    func applyTheme() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let colors = AppTheme.current.colors(dark: dark)
        func ns(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: alpha)
        }
        nativeBackgroundColor = ns(colors.background)
        nativeForegroundColor = ns(colors.ink)
        caretColor = ns(colors.accent)
        selectedTextBackgroundColor = ns(colors.accent, dark ? 0.35 : 0.25)
        installColors(TerminalTheme.ansi(dark: dark))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    /// 结束 shell 并回收子进程。SwiftTerm 的 terminate() 发出 SIGTERM 后就取消了退出监听，
    /// 不会 waitpid，每关一个窗格就留下一个僵尸进程，直到应用退出。
    func end() {
        let pid = process?.shellPid ?? 0
        terminate()
        guard pid > 0 else { return }
        ShellReaper.reap(pid)
    }
}

/// 在后台回收已结束的 shell。交互式 zsh 忽略 SIGTERM，所以像真正的终端关闭时一样向整个进程组发 SIGHUP；
/// 一秒后仍未退出就 SIGKILL。每个进程各自等待，关闭多个窗格时互不排队。
enum ShellReaper {
    private static let queue = DispatchQueue(label: "Timeline.ShellReaper", qos: .utility, attributes: .concurrent)

    static func reap(_ pid: pid_t) {
        killpg(pid, SIGHUP)
        kill(pid, SIGHUP)
        queue.async {
            var status: Int32 = 0
            for attempt in 0..<40 {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid || (result == -1 && errno == ECHILD) { return }
                if attempt == 20 { killpg(pid, SIGKILL); kill(pid, SIGKILL) }
                usleep(50_000)
            }
            waitpid(pid, &status, 0)
        }
    }
}

/// GitHub 风格的 16 色 ANSI，和「墨蓝」配色同源。
enum TerminalTheme {
    private static let darkANSI: [UInt32] = [
        0x484F58, 0xFF7B72, 0x3FB950, 0xD29922, 0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4,
        0x6E7681, 0xFFA198, 0x56D364, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xF0F6FC,
    ]
    private static let lightANSI: [UInt32] = [
        0x24292F, 0xCF222E, 0x116329, 0x4D2D00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
        0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F,
    ]

    static func ansi(dark: Bool) -> [SwiftTerm.Color] {
        (dark ? darkANSI : lightANSI).map { hex in
            SwiftTerm.Color(red8: UInt16((hex >> 16) & 255), green8: UInt16((hex >> 8) & 255), blue8: UInt16(hex & 255))
        }
    }
}

/// 包住一个窗格，留出 2pt 空隙，焦点时在这圈空隙里画高亮边框。
final class PaneFrameView: NSView {
    let terminal: PaneTerminalView

    var focused = false {
        didSet { updateBorder() }
    }

    private func updateBorder() {
        var color = NSColor.clear.cgColor
        if focused { effectiveAppearance.performAsCurrentDrawingAppearance { color = NativePalette.accent.withAlphaComponent(0.75).cgColor } }
        layer?.borderColor = color
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    init(terminal: PaneTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1.5
        layer?.cornerRadius = 3
        layer?.borderColor = NSColor.clear.cgColor
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class PaneSplitView: NSSplitView {
    override var dividerColor: NSColor { NativePalette.line }
}

/// 新建终端窗口 / 标签页的默认布局。
enum TerminalLayout: String {
    /// 一个窗口三个窗格：左边上下两格，右边一整栏。
    case threePanes
    case single
}

/// 终端窗口：一个窗口（或原生标签页）包含一个或三个窗格，每个窗格是独立的 zsh。
final class TerminalWindow: QuietWindow {
    /// 按「左上、左下、右」的顺序。
    var panes: [PaneTerminalView] = []
    weak var focusedPane: PaneTerminalView?
    /// 当前窗格的终端。
    var terminal: LocalProcessTerminalView! { focusedPane ?? panes.first }
    /// shell 已经退出（输入了 exit）：关闭时不再询问。
    var ended = false
    /// 标签栏右侧的「+」按钮会调用它。
    var onNewTab: (() -> Void)?
    /// 顶部的按钮工具条。
    var toolbarView: NSView?
    /// 工具条下面放窗格的区域，里面只有一个根视图（单个窗格或分栏视图）。
    var bodyHost: NSView?

    override func newWindowForTab(_ sender: Any?) { onNewTab?() }

    /// 点击或键盘切换到某个窗格时，记下并高亮它。
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted, let pane = responder as? PaneTerminalView, panes.contains(where: { $0 === pane }) { setFocused(pane) }
        return accepted
    }

    func setFocused(_ pane: PaneTerminalView) {
        focusedPane = pane
        for other in panes { (other.superview as? PaneFrameView)?.focused = panes.count > 1 && other === pane }
    }

    func setRoot(_ view: NSView) {
        guard let bodyHost else { return }
        bodyHost.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        bodyHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: bodyHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: bodyHost.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: bodyHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: bodyHost.trailingAnchor),
        ])
    }

    /// 在 `pane` 旁边放入新窗格：`sideBySide` 为 true 是向右，false 是向下。新窗格拿走原窗格一半的空间。
    func insertPane(_ newPane: PaneTerminalView, beside pane: PaneTerminalView, sideBySide: Bool) {
        guard let anchor = pane.superview as? PaneFrameView, let index = panes.firstIndex(where: { $0 === pane }) else { return }
        let newFrame = PaneFrameView(terminal: newPane)
        panes.insert(newPane, at: index + 1)
        let oldLength = sideBySide ? anchor.frame.width : anchor.frame.height
        let host = anchor.superview
        let target: NSSplitView
        let origin: CGFloat
        if let split = host as? NSSplitView, split.isVertical == sideBySide {
            // 方向相同：直接并排放进同一个分栏视图。
            origin = sideBySide ? anchor.frame.minX : anchor.frame.minY
            split.insertArrangedSubview(newFrame, at: (split.arrangedSubviews.firstIndex(of: anchor) ?? 0) + 1)
            target = split
        } else {
            // 方向不同（或还没有分栏）：用一个新的分栏视图把原窗格和新窗格包起来，替换原窗格的位置。
            let nested = PaneSplitView()
            nested.isVertical = sideBySide
            nested.dividerStyle = .thin
            nested.frame = anchor.frame
            if let parent = host as? NSSplitView {
                let at = parent.arrangedSubviews.firstIndex(of: anchor) ?? 0
                anchor.removeFromSuperview()
                parent.insertArrangedSubview(nested, at: at)
            } else {
                anchor.removeFromSuperview()
                setRoot(nested)
            }
            nested.addArrangedSubview(anchor)
            nested.addArrangedSubview(newFrame)
            target = nested
            origin = 0
        }
        contentView?.layoutSubtreeIfNeeded()
        target.adjustSubviews()
        if let dividerIndex = target.arrangedSubviews.firstIndex(of: anchor) {
            target.setPosition(origin + oldLength / 2, ofDividerAt: dividerIndex)
        }
        setFocused(focusedPane ?? newPane)
    }

    /// 窗格里的 shell 结束后把它从界面上拿掉，其余窗格自动补位。
    func removePane(_ pane: PaneTerminalView) {
        guard let index = panes.firstIndex(where: { $0 === pane }) else { return }
        panes.remove(at: index)
        if focusedPane === pane { focusedPane = nil }
        var container = pane.superview?.superview
        pane.superview?.removeFromSuperview()
        while let split = container as? NSSplitView {
            let parent = split.superview
            if split.arrangedSubviews.isEmpty {
                // 一栏里的窗格都没了：把空的分栏视图一起拿掉。
                split.removeFromSuperview()
                (parent as? NSSplitView)?.adjustSubviews()
                container = parent
            } else if split.arrangedSubviews.count == 1, let only = split.arrangedSubviews.first {
                // 只剩一个：让它顶替分栏视图，避免留下只有一个孩子的分栏。
                let frame = split.frame
                only.removeFromSuperview()
                if let parentSplit = parent as? NSSplitView {
                    let at = parentSplit.arrangedSubviews.firstIndex(of: split) ?? 0
                    split.removeFromSuperview()
                    parentSplit.insertArrangedSubview(only, at: at)
                    only.frame = frame
                    parentSplit.adjustSubviews()
                } else {
                    split.removeFromSuperview()
                    setRoot(only)
                }
                break
            } else {
                split.adjustSubviews()
                break
            }
        }
        for other in panes { (other.superview as? PaneFrameView)?.focused = panes.count > 1 && other === focusedPane }
    }
}

/// 终端窗口顶部常驻的工具条：按钮加快捷键提示，不需要记忆也能找到「新标签页」。
struct ShellToolbar: View {
    let newTab: () -> Void
    let newWindow: () -> Void
    let splitRight: () -> Void
    let splitDown: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            button("plus", "新标签页", "⌘T", newTab)
            button("macwindow.badge.plus", "新窗口", "⌘N", newWindow)
            button("rectangle.split.2x1", "右分栏", "⌘D", splitRight)
            button("rectangle.split.1x2", "下分栏", "⇧⌘D", splitDown)
            button("xmark", "关闭", "⌘W", close)
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                hints("⌘[ ⌘] 切换窗格  ·  ⌥⌘W 关窗格  ·  ⌘⇧[ ⌘⇧] 切换标签页  ·  ⌘K 清屏  ·  \(GlobalHotKey.shellLabel) 隐藏")
                hints("⌘[ ⌘] 切换窗格  ·  ⌥⌘W 关窗格")
                hints("⌘[ ⌘] 切换窗格")
                Color.clear.frame(width: 0)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .foregroundStyle(Palette.ink.opacity(0.85))
    }

    private func button(_ symbol: String, _ title: String, _ key: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11))
                Text(key).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 7).frame(height: 20)
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .raisedOnHover(radius: 5)
        .help("\(title)  \(key)")
        .accessibilityLabel("\(title)，快捷键 \(key)")
    }

    private func hints(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1).fixedSize()
    }
}

enum ShellProcessInfo {
    /// 进程当前所在目录，新开的标签页和窗口用它作为起始目录。
    static func currentDirectory(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// 终端里是否有程序在前台运行（比如正在和 agent 对话），而不是停在 shell 提示符。
    static func hasForegroundProgram(fd: Int32, shellPid: pid_t) -> Bool {
        guard fd >= 0, shellPid > 0 else { return false }
        let group = tcgetpgrp(fd)
        return group > 0 && group != shellPid
    }
}

/// 内置 zsh 终端：真正的 PTY 终端（能运行 vim、htop、agent 等）。
/// 可以同时开多个窗口，每个窗口还能有多个原生标签页；终端全局快捷键把所有终端窗口一起显示 / 隐藏（隐藏只是收起，里面的程序继续运行）。
/// 关闭标签页或窗口会结束里面的 shell；有程序在前台运行时会先确认。
@MainActor
final class ShellWindowController: NSObject, NSWindowDelegate, LocalProcessTerminalViewDelegate {
    private(set) var windows: [TerminalWindow] = []
    private weak var lastKey: TerminalWindow?
    /// 终端收起后，Timeline 别的窗口（主窗口）如果还开着，焦点交给它；由 AppDelegate 设置。
    var handoffWindow: () -> NSWindow? = { nil }
    /// 启动 shell 的命令，测试里可替换。
    var executable = "/bin/zsh"
    var arguments = ["-l"]
    /// 测试里可固定布局；平时跟随设置。
    var layoutOverride: TerminalLayout?
    var layout: TerminalLayout {
        layoutOverride ?? TerminalLayout(rawValue: UserDefaults.standard.string(forKey: Prefs.terminalLayout) ?? "") ?? .threePanes
    }
    static func shellEnvironment(base environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var result = Terminal.getEnvironmentVariables(termName: "xterm-256color") + ["SHELL=/bin/zsh", "TERM_PROGRAM=Timeline"]
        result.append("PATH=" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"))
        if let directory = environment["ZDOTDIR"], !directory.isEmpty {
            result.append("ZDOTDIR=\(directory)")
        }
        return result
    }

    /// 前台有程序时关闭前的确认；测试里可替换。
    var confirmClose: (TerminalWindow) -> Bool = { ShellWindowController.askToClose($0) }

    var isFrontmost: Bool { NSApplication.shared.isActive && NSApplication.shared.keyWindow is TerminalWindow }
    /// 当前可见的终端窗口（优先正在用的那个），给主窗口收起时交接焦点。
    var visibleWindow: NSWindow? {
        let candidates = [keyTerminal].compactMap { $0 } + windows
        return candidates.first { $0.isVisible && !$0.isMiniaturized }.map { $0.tabGroup?.selectedWindow ?? $0 }
    }
    var keyTerminal: TerminalWindow? { (NSApplication.shared.keyWindow as? TerminalWindow) ?? lastKey ?? windows.last }

    /// 前台正在运行程序的终端数量。
    var busyCount: Int { windows.filter(isBusy).count }

    func isBusy(_ window: TerminalWindow) -> Bool {
        window.panes.contains { pane in
            guard let process = pane.process else { return false }
            return ShellProcessInfo.hasForegroundProgram(fd: process.childfd, shellPid: process.shellPid)
        }
    }

    func currentDirectory(of window: TerminalWindow) -> String? {
        window.terminal?.process.flatMap { ShellProcessInfo.currentDirectory(of: $0.shellPid) }
    }

    // MARK: - 显示 / 隐藏

    func toggle() {
        if isFrontmost { hide() } else { show() }
    }

    /// 在当前桌面显示全部终端窗口（每组标签页显示选中的那一页）；一个都没有就新开一个。
    func show() {
        PreviousApp.remember()
        NSApplication.shared.unhide(nil)
        guard !windows.isEmpty else { newWindow(); return }
        var shown = Set<ObjectIdentifier>()
        for window in windows {
            let representative = window.tabGroup?.selectedWindow ?? window
            guard shown.insert(ObjectIdentifier(representative)).inserted, !representative.isVisible else { continue }
            moveToMouseScreenIfNeeded(representative)
            representative.alphaValue = Motion.reduced ? 1 : 0
            representative.orderFront(nil)
            if !Motion.reduced { WindowFade.animate(representative, to: 1, duration: 0.18) }
        }
        let front = keyTerminal.flatMap { $0.tabGroup?.selectedWindow ?? $0 } ?? windows[0]
        front.makeKeyAndOrderFront(nil)
        Headless.activateApp()
        if let terminal = (front as? TerminalWindow)?.terminal { front.makeFirstResponder(terminal) }
    }

    /// 只收起，不结束 shell。
    func hide() {
        let visible = windows.filter(\.isVisible)
        guard !visible.isEmpty else { return }
        let finish: () -> Void = { [weak self] in
            for window in visible { window.orderOut(nil); WindowFade.reset(window) }
            PreviousApp.restore(handoff: self?.handoffWindow())
        }
        if Motion.reduced { finish(); return }
        var remaining = visible.count
        for window in visible {
            WindowFade.animate(window, to: 0, duration: 0.14) {
                remaining -= 1
                if remaining == 0 { finish() }
            }
        }
    }

    /// 应用失去前台时的收起：只藏窗口，不交还焦点（用户已经在别的应用里了）。shell 照常运行。
    func hideForAppDeactivation() {
        for window in windows where window.isVisible {
            WindowFade.reset(window)
            window.orderOut(nil)
        }
    }

    // MARK: - 窗口与标签页

    /// 新开一个独立窗口（`⌘N`），起始目录继承当前终端。
    @discardableResult
    func newWindow() -> TerminalWindow {
        let anchor = keyTerminal
        let window = makeWindow(directory: anchor.flatMap(currentDirectory(of:)), size: anchor?.frame.size)
        if let anchor, anchor.isVisible {
            let origin = anchor.cascadeTopLeft(from: NSPoint(x: anchor.frame.minX, y: anchor.frame.maxY))
            window.setFrameTopLeftPoint(origin)
        }
        present(window)
        return window
    }

    /// 在当前窗口里新开一页（`⌘T`），起始目录继承当前页。
    @discardableResult
    func newTab() -> TerminalWindow {
        guard let anchor = keyTerminal, anchor.isVisible else { return newWindow() }
        let window = makeWindow(directory: currentDirectory(of: anchor), size: anchor.frame.size)
        window.setFrame(anchor.frame, display: false)
        anchor.addTabbedWindow(window, ordered: .above)
        present(window)
        return window
    }

    func selectTab(at index: Int) {
        guard let tabs = keyTerminal?.tabbedWindows, tabs.indices.contains(index) else { return }
        tabs[index].makeKeyAndOrderFront(nil)
    }

    func selectAdjacentTab(_ offset: Int) {
        guard let window = keyTerminal, let tabs = window.tabbedWindows, let index = tabs.firstIndex(of: window), tabs.count > 1 else { return }
        tabs[(index + offset + tabs.count) % tabs.count].makeKeyAndOrderFront(nil)
    }

    /// `⌘[` / `⌘]`：在当前窗口的窗格之间切换。
    func selectPane(_ offset: Int) {
        guard let window = keyTerminal, window.panes.count > 1, let current = window.terminal,
              let index = window.panes.firstIndex(where: { $0 === current }) else { return }
        window.makeFirstResponder(window.panes[(index + offset + window.panes.count) % window.panes.count])
    }

    /// `⌘D` / `⇧⌘D`：把当前窗格向右 / 向下分成两个，新窗格从当前窗格所在的目录开始并获得焦点。
    @discardableResult
    func splitPane(sideBySide: Bool) -> PaneTerminalView? {
        guard let window = keyTerminal, let current = window.terminal as? PaneTerminalView,
              let anchor = current.superview as? PaneFrameView else { return nil }
        // 连按几次分栏时上一次的布局可能还没算完，先布局再量尺寸。
        window.contentView?.layoutSubtreeIfNeeded()
        // 太小就不再分，免得出现几乎看不见的窗格。
        guard (sideBySide ? anchor.frame.width : anchor.frame.height) >= (sideBySide ? 260 : 160) else { NSSound.beep(); return nil }
        let pane = makePane()
        let directory = current.process.flatMap { ShellProcessInfo.currentDirectory(of: $0.shellPid) } ?? NSHomeDirectory()
        window.insertPane(pane, beside: current, sideBySide: sideBySide)
        pane.startProcess(executable: executable, args: arguments,
                          environment: ShellWindowController.shellEnvironment(),
                          execName: nil, currentDirectory: directory)
        window.makeFirstResponder(pane)
        return pane
    }

    /// `⌥⌘W`：关闭当前窗格（里面有程序在运行时先确认）；这是最后一个窗格时关闭整个窗口。
    func closePane() {
        guard let window = keyTerminal, let pane = window.terminal as? PaneTerminalView else { return }
        if window.panes.count <= 1 {
            if windowShouldClose(window) { window.close() }
            return
        }
        if let process = pane.process, ShellProcessInfo.hasForegroundProgram(fd: process.childfd, shellPid: process.shellPid), !confirmClose(window) { return }
        pane.end()
        finish(pane, in: window)
    }

    /// 某个窗格结束（输入 exit 或被关闭）后的善后。
    private func finish(_ pane: PaneTerminalView, in window: TerminalWindow) {
        guard window.panes.contains(where: { $0 === pane }) else { return }
        window.removePane(pane)
        if let next = window.focusedPane ?? window.panes.first {
            window.makeFirstResponder(next)
            window.setFocused(next)
            return
        }
        window.ended = true
        let wasAlone = window.tabbedWindows?.count ?? 1 <= 1
        window.close()
        if wasAlone, windows.isEmpty { PreviousApp.restore(handoff: handoffWindow()) }
    }

    /// `⌘K`：清屏。
    func clearScreen() {
        keyTerminal?.terminal?.send(txt: "\u{0c}")
    }

    private func present(_ window: TerminalWindow) {
        NSApplication.shared.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        Headless.activateApp()
        window.makeFirstResponder(window.terminal)
    }

    private func makePane() -> PaneTerminalView {
        let pane = PaneTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        pane.processDelegate = self
        pane.getTerminal().changeScrollback(PaneTerminalView.scrollbackLines)
        pane.font = .monospacedSystemFont(ofSize: UIScale.pt(13), weight: .regular)
        pane.applyTheme()
        return pane
    }

    private func makeWindow(directory: String?, size: NSSize?) -> TerminalWindow {
        let three = layout == .threePanes
        let frame = NSRect(origin: .zero, size: size ?? (three ? NSSize(width: 1240, height: 780) : NSSize(width: 920, height: 580)))
        let panes = (0..<(three ? 3 : 1)).map { _ in makePane() }
        let frames = panes.map { PaneFrameView(terminal: $0) }
        let window = TerminalWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.panes = panes
        window.title = "zsh"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NativePalette.background
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: three ? 640 : 420, height: three ? 360 : 240)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.tabbingIdentifier = "timeline.shell"
        window.tabbingMode = .preferred
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { window.standardWindowButton($0)?.isHidden = true }
        window.delegate = self
        window.onNewTab = { [weak self] in self?.newTab() }
        // 工具条放在窗口自己的内容区顶部（不用标题栏附件：标签页组会把各页的附件合并共享，会叠出多条工具条）。
        let toolbar = NSHostingView(rootView: LocalizedRoot { ShellToolbar(
            newTab: { [weak self, weak window] in window?.makeKeyAndOrderFront(nil); self?.newTab() },
            newWindow: { [weak self, weak window] in window?.makeKeyAndOrderFront(nil); self?.newWindow() },
            splitRight: { [weak self, weak window] in window?.makeKeyAndOrderFront(nil); self?.splitPane(sideBySide: true) },
            splitDown: { [weak self, weak window] in window?.makeKeyAndOrderFront(nil); self?.splitPane(sideBySide: false) },
            close: { [weak self, weak window] in
                guard let self, let window, windowShouldClose(window) else { return }
                window.close()
            }) })
        // 三窗格：左边上下两格，右边一整栏。
        let body: NSView
        var leftSplit: PaneSplitView?
        var rootSplit: PaneSplitView?
        if three {
            let left = PaneSplitView()
            left.isVertical = false
            left.dividerStyle = .thin
            left.addArrangedSubview(frames[0])
            left.addArrangedSubview(frames[1])
            let root = PaneSplitView()
            root.isVertical = true
            root.dividerStyle = .thin
            root.addArrangedSubview(left)
            root.addArrangedSubview(frames[2])
            leftSplit = left
            rootSplit = root
            body = root
        } else {
            body = frames[0]
        }
        let container = NSView(frame: frame)
        let bodyHost = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        bodyHost.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolbar)
        container.addSubview(bodyHost)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 28),
            bodyHost.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            bodyHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bodyHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bodyHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        window.toolbarView = toolbar
        window.bodyHost = bodyHost
        window.setRoot(body)
        container.layoutSubtreeIfNeeded()
        // 初始比例：左栏约 45% 宽，左边上下各一半。
        if let rootSplit, let leftSplit {
            rootSplit.setPosition(rootSplit.bounds.width * 0.45, ofDividerAt: 0)
            leftSplit.layoutSubtreeIfNeeded()
            leftSplit.setPosition(leftSplit.bounds.height * 0.5, ofDividerAt: 0)
        }
        if windows.isEmpty {
            window.center()
            window.setFrameAutosaveName("TimelineShellWindow")
        }
        windows.append(window)
        window.setFocused(panes[0])
        let environment = ShellWindowController.shellEnvironment()
        for pane in panes {
            pane.startProcess(executable: executable, args: arguments, environment: environment,
                              execName: nil, currentDirectory: directory ?? NSHomeDirectory())
        }
        return window
    }

    private func moveToMouseScreenIfNeeded(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }), window.screen != screen else { return }
        let area = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
    }

    /// 退出 Timeline 前结束全部 shell。
    func terminateAll() {
        for window in windows { window.panes.forEach { $0.end() } }
    }

    static func askToClose(_ window: TerminalWindow) -> Bool {
        let alert = NSAlert()
        alert.messageText = "关闭这个终端？"
        alert.informativeText = "里面还有程序在运行（比如正在和 agent 对话），关闭会结束它。"
        alert.addButton(withTitle: "关闭")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let window = sender as? TerminalWindow, !window.ended, isBusy(window) else { return true }
        return confirmClose(window)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? TerminalWindow else { return }
        window.panes.forEach { $0.end() }
        windows.removeAll { $0 === window }
        if lastKey === window { lastKey = windows.last }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        lastKey = notification.object as? TerminalWindow
    }

    // MARK: - LocalProcessTerminalViewDelegate

    private func window(for source: AnyObject) -> TerminalWindow? {
        windows.first { $0.panes.contains { $0 === source } }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in
            if let window = self?.window(for: source), window.terminal === source { window.title = title.isEmpty ? "zsh" : title }
        } }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// 用户在某个窗格里输入 exit：只拿掉这个窗格，其余补位；最后一个窗格结束时关掉整个窗口（标签页）。
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in
            guard let self, let window = window(for: source), let pane = window.panes.first(where: { $0 === source }) else { return }
            finish(pane, in: window)
        } }
    }
}
