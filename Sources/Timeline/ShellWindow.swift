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
final class PaneTerminalView: LocalProcessTerminalView {}

/// 包住一个窗格，留出 2pt 空隙，焦点时在这圈空隙里画高亮边框。
final class PaneFrameView: NSView {
    let terminal: PaneTerminalView

    var focused = false {
        didSet { layer?.borderColor = (focused ? NSColor.controlAccentColor.withAlphaComponent(0.75) : NSColor.clear).cgColor }
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
    override var dividerColor: NSColor { NSColor(white: 0.2, alpha: 1) }
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
        .foregroundStyle(Color.white.opacity(0.85))
    }

    private func button(_ symbol: String, _ title: String, _ key: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11))
                Text(key).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.white.opacity(0.5))
            }
            .padding(.horizontal, 7).frame(height: 20)
            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help("\(title)  \(key)")
        .accessibilityLabel("\(title)，快捷键 \(key)")
    }

    private func hints(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5)).foregroundStyle(Color.white.opacity(0.5)).lineLimit(1).fixedSize()
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
/// 可以同时开多个窗口，每个窗口还能有多个原生标签页；`⌃⌥T` 把所有终端窗口一起显示 / 隐藏（隐藏只是收起，里面的程序继续运行）。
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
    /// 应用包里放命令行工具 `timeline` 的目录。
    static var bundledToolsDirectory: String? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        return url.flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("timeline").path) ? $0.path : nil }
    }

    /// 终端里的环境变量。`PATH` 里加上应用包里的 bin：在应用内终端任何时候都能直接运行 `timeline`，
    /// 即使用户的 shell 配置里没有 ~/.local/bin。登录 shell 的 path_helper 会保留这一项，再补上系统路径。
    static func shellEnvironment(base environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var result = Terminal.getEnvironmentVariables(termName: "xterm-256color") + ["SHELL=/bin/zsh", "TERM_PROGRAM=Timeline"]
        var path = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let tools = bundledToolsDirectory { path.insert(tools, at: 0) }
        result.append("PATH=" + path.joined(separator: ":"))
        // zsh 自带 sched 内置命令；为旧命令保留的兼容入口关闭这个内置命令，
        // 并把你原来的 ZDOTDIR（没有就是主目录）里的 .zshenv、.zshrc 等照常加载，不改你的任何配置文件。
        if let zdotdir = startupDirectory() {
            result.append("ZDOTDIR=\(zdotdir)")
            if let original = environment["ZDOTDIR"], !original.isEmpty { result.append("TIMELINE_REAL_ZDOTDIR=\(original)") }
        }
        // 用环境变量指定了数据目录（测试、多份数据）时，终端里的 timeline 读同一份。
        if let dir = environment["TIMELINE_DATA_DIR"], !dir.isEmpty {
            result.append("TIMELINE_DATA_DIR=\(dir)")
        } else if let dir = environment["DAYLEAF_DATA_DIR"], !dir.isEmpty {
            result.append("TIMELINE_DATA_DIR=\(dir)")
        }
        return result
    }

    static let startupZshenv = """
    # Timeline 内置终端：保留旧 sched 命令的兼容入口，加载原来的 shell 配置。
    if [[ -n "$TIMELINE_REAL_ZDOTDIR" ]]; then ZDOTDIR="$TIMELINE_REAL_ZDOTDIR"; else unset ZDOTDIR; fi
    [[ -r "${ZDOTDIR:-$HOME}/.zshenv" ]] && source "${ZDOTDIR:-$HOME}/.zshenv"
    disable sched 2>/dev/null
    """

    /// 写出（或更新）启动目录并返回路径；写不出来就返回 nil，终端照常启动，只是 zsh 里要用 timeline 这个名字。
    static func startupDirectory(base: URL = FileManager.default.temporaryDirectory) -> String? {
        let directory = base.appendingPathComponent("timeline-zdotdir-\(getuid())", isDirectory: true)
        let file = directory.appendingPathComponent(".zshenv")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if (try? String(contentsOf: file, encoding: .utf8)) != startupZshenv { try startupZshenv.write(to: file, atomically: true, encoding: .utf8) }
            return directory.path
        } catch { return nil }
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
        pane.terminate()
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
        pane.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        pane.nativeBackgroundColor = NSColor(white: 0.035, alpha: 1)
        pane.nativeForegroundColor = NSColor(white: 0.88, alpha: 1)
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
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.035, alpha: 1)
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
        for window in windows { window.panes.forEach { $0.terminate() } }
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
        window.panes.forEach { $0.terminate() }
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
