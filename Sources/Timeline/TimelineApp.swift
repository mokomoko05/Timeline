import AppKit
import Carbon.HIToolbox
import CoreSpotlight
import SwiftUI
import TimelineCore

@main
enum TimelineApp {
    @MainActor
    static func main() {
        do {
            try LegacyMigration.run()
        } catch {
            if CommandLine.arguments.contains("--migrate-legacy") || CommandLine.arguments.contains("--configure-login") {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            } else {
                let alert = NSAlert()
                alert.messageText = AppLocalized("Timeline 迁移未完成")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
            exit(1)
        }
        if CommandLine.arguments.contains("--migrate-legacy") { return }
        if CommandLine.arguments.contains("--configure-login") {
            let loginItem = LoginItem()
            loginItem.configureForInstallation()
            if let error = loginItem.errorMessage {
                print(error)
            } else {
                print("登录启动已启用。")
            }
            if !loginItem.enabled || loginItem.errorMessage != nil { exit(1) }
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

/// 菜单项携带的动作：普通命令、带勾选状态的偏好开关，以及「输入文字时不可用」的标记。
private final class MenuAction: NSObject {
    let run: () -> Void
    var toggleKey: String?
    var toggleDefault = false
    var disabledWhileTyping = false
    init(_ run: @escaping () -> Void) { self.run = run }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    /// 主界面、笔记 / 日记和常用终端共用窗口的位置和大小。
    private let pages = WorkspacePagesView(defaults: .standard)
    private var store: JournalStore!
    private var reminders: ReminderScheduler!
    private var loginItem: LoginItem!
    private var quickCapture: QuickCaptureController!
    private var settings: SettingsWindowController!
    private var undoItem: NSMenuItem?
    private var keyMonitor: Any?
    private var boardTerminationPrepared = false
    private var boardTerminationPending = false
    /// 用全局快捷键打开 Timeline 之前的前台应用，隐藏 Timeline 时把焦点还给它。
    private var hotKeysRegistered = false
    private var hotKeysAttempted = false
    private let logHotKey = GlobalHotKey(action: .log)
    private let notesHotKey = GlobalHotKey(action: .notes)
    private let focusHotKey = GlobalHotKey(action: .focusPanel)
    private let mainHotKey = GlobalHotKey(action: .main)
    private let shellHotKey = GlobalHotKey(action: .shell)
    private let boardHotKey = GlobalHotKey(action: .board)
    private let searchHotKey = GlobalHotKey(action: .search)
    private let shell = ShellWindowController()
    private let interaction = WorkspaceInteraction()
    private let commands = CommandCenter()
    private let toast = ToastCenter()
    private let focus = FocusSession()
    private var focusPanel: FocusPanelController?
    private var autoHide: AutoHideOnResign?
    private var languageObserver: NSObjectProtocol?
    private var memoryPressure: DispatchSourceMemoryPressure?
    /// 主窗口隐藏半小时以上就释放界面，下次显示前重建。
    private var mainContent: HiddenContentReleaser?
    private var cloudSync: CloudSyncController?
    private var centeringObserver: NSObjectProtocol?
    /// 让日志、待办和工作板出现在系统 Spotlight 里。
    private var spotlight: SpotlightIndexer?

    /// 点开了 Spotlight 里的结果：跳到那条日志、那个待办或那页工作板。
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let (kind, id) = SpotlightItem.parse(identifier) else { return false }
        switch kind {
        case .task:
            guard store.locate(id) != nil else { return false }
            AppRouter.presentMain()
            NotificationCenter.default.post(name: .timelineReveal, object: id)
        case .log:
            guard let found = store.allLogs(includeFocus: true).first(where: { $0.log.id == id }) else { return false }
            if let taskID = found.log.taskID, store.locate(taskID) != nil {
                NotesWindowController.shared.nav.revealNote = id
                AppRouter.openNotes(taskID)
            } else {
                AppRouter.openLog(JournalDates.date(for: found.key) ?? found.log.createdAt, id)
            }
        case .board:
            guard let board = store.boards.first(where: { $0.id == id }) else { return false }
            BoardWindowController.shared.show(store: store, owner: board.owner)
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        let snapshotRun = CommandLine.arguments.contains("--snapshot")
        store = JournalStore()
        store.writesInBackground = true
        reminders = ReminderScheduler(store: store)
        reminders.isEnabled = !snapshotRun
        BoardWindowController.shared.navigation.connectFavorites(to: store)
        focus.store = store
        focusPanel = FocusPanelController(session: focus)
        loginItem = LoginItem()
        if !snapshotRun { cloudSync = CloudSyncController(store: store) }
        AppRouter.cloudSync = cloudSync
        AppIssues.shared.attach(store: store, cloudSync: cloudSync)
        if !snapshotRun { LogKeyboardSelection.shared.install() }
        settings = SettingsWindowController(loginItem: loginItem, cloudSync: cloudSync, reminders: reminders, failedHotKeys: { [weak self] in self?.failedHotKeys })
        // 切到别的应用就把工作窗口收起来；快速面板和专注计时窗口不在其中。
        autoHide = AutoHideOnResign(windows: { [weak self] in
            [self?.window, ImageViewerController.shared.window, self?.settings.window]
        }, extraHide: { [weak self] in self?.shell.hideForAppDeactivation() })
        shell.handoffWindow = { [unowned self] in otherWindowForHandoff(excluding: nil) }
        _ = ThemeStore.shared   // 读取已保存的配色和外观并应用
        _ = LanguageStore.shared
        languageObserver = NotificationCenter.default.addObserver(forName: .appLanguageDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.buildMenu()
                self?.window?.title = AppLocalized(self?.pages.showsTerminal == true ? "终端" : (self?.pages.showsNotes == true ? "笔记 / 日记" : "Timeline"))
            }
        }
        AppRouter.presentMain = { [unowned self] in
            if !(window.isVisible && !window.isMiniaturized) || NSApp.keyWindow !== window || pages.page != .main { showMainWindowSoftly() }
        }
        AppRouter.mainIsKey = { [unowned self] in NSApp.keyWindow === window && pages.page == .main }
        AppRouter.showSettings = { [unowned self] in settings.show() }
        AppRouter.showQuickCapture = { [unowned self] in quickCapture.toggle(.todo) }
        AppRouter.openNotes = { [unowned self] id in commands.send(.notesForTask(id)) }
        quickCapture = QuickCaptureController(store: store, openMain: { [weak self] in self?.showMainWindow() },
                                              openShell: { [weak self] in self?.shell.show() })
        UserDefaults.standard.register(defaults: [Prefs.clickExpands: true, Prefs.globalHotKey: true, Prefs.uiScale: 1.0])
        buildMenu()
        let mainWindow = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: MainWindow.workspaceStyle,
            backing: .buffered, defer: false
        )
        window = mainWindow
        // 笔记 / 日记、终端和主界面共用窗口。
        mainWindow.cancel = { [unowned self] in
            if pages.showsTerminal { hideMainWindowSoftly(); return true }
            guard pages.showsNotes else { return false }
            NotesWindowController.shared.close()
            return true
        }
        window.title = AppLocalized("Timeline")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // 去掉红绿灯；关闭 / 最小化仍可用 ⌘W、⌘M，也可以用全局快捷键隐藏。
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { window.standardWindowButton($0)?.isHidden = true }
        window.minSize = NSSize(width: 640, height: 560)
        window.isReleasedWhenClosed = false
        // 在当前桌面（Space）打开，而不是切到窗口原来所在的桌面。
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self
        window.contentView = pages
        shell.workspaceWindow = mainWindow
        shell.installWorkspaceContent = { [weak self] in self?.pages.setTerminal($0) }
        shell.presentWorkspace = { [weak self] in self?.showTerminalPage() }
        shell.hideWorkspace = { [weak self] in self?.hideMainWindowSoftly() }
        shell.finishWorkspace = { [weak self] in self?.showMainWindowSoftly() }
        pages.setMain(makeMainContent())
        NotesWindowController.shared.host = self
        // 只释放主界面那一页；笔记页很小，一直留着。
        mainContent = HiddenContentReleaser(window: window, delay: .seconds(30 * 60), release: { [weak self] in self?.pages.setMain(nil) }, rebuild: { [weak self] in
            guard let self else { return }
            pages.setMain(makeMainContent())
        })
        window.center()
        window.setFrameAutosaveName("TimelineMainWindow")
        UserDefaults.standard.register(defaults: [Prefs.mainWindowCentered: true])
        mainWindow.keepsCentered = UserDefaults.standard.bool(forKey: Prefs.mainWindowCentered)
        centeringObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak mainWindow] _ in
            MainActor.assumeIsolated {
                let centered = UserDefaults.standard.bool(forKey: Prefs.mainWindowCentered)
                if mainWindow?.keepsCentered != centered { mainWindow?.keepsCentered = centered }
            }
        }
        if !snapshotRun, pages.savedPage == .terminal {
            shell.show()
        } else if !snapshotRun, pages.savedPage == .notes {
            NotesWindowController.shared.show(store: store, taskID: nil, reveal: { _ in }, openDay: { _ in })
        } else {
            window.makeKeyAndOrderFront(nil)
            Headless.activateApp()
        }
        reminders.onComplete = { [weak self] in self?.toast.show(AppLocalizedFormat("已从通知完成「%@」", $0)) }
        // 专注期间允许自由切换网页和应用；任务链接只用于开始时打开，不再需要 Safari 自动化权限。
        if CommandLine.arguments.contains("--enable-login") { loginItem.setEnabled(true) }
        if !snapshotRun {
            ImageIndexer.run(store: store)
            spotlight = SpotlightIndexer(store: store)
            spotlight?.start()
            // 启动稍后清理不再被任何数据或备份引用的图片，不拖慢启动。
            Task { @MainActor [weak store] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                await store?.removeUnusedImagesInBackground()
            }
            quickCapture.installStatusItem()
            AppRouter.togglePanel = { [weak self] action in self?.togglePanel(action) }
            AppRouter.hideMain = { [weak self] in self?.hideMainWindowSoftly() }
            AppRouter.openLog = { [weak self] date, id in
                guard let self else { return }
                PreviousApp.remember()
                NSApp.unhide(nil)
                NotesWindowController.shared.showJournal(store: self.store, date: date, log: id)
            }
            AppRouter.openJournal = { [weak self] date in
                guard let self else { return }
                PreviousApp.remember()
                NSApp.unhide(nil)
                NotesWindowController.shared.showJournal(store: self.store, date: date)
            }
            for (action, hotKey) in allHotKeys { hotKey.onPress = { AppRouter.togglePanel(action) } }
            applyHotKeyPreference()
            NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyHotKeyPreference() }
            }
            installKeyboardNavigation()
            installMemoryPressureHandler()
            NotificationCenter.default.addObserver(forName: .timelineHotKeysChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyNotesShortcut(); self?.rebindHotKeysIfNeeded() }
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
            let destination = CommandLine.arguments[index + 1]
            // 截图时可以临时指定配色、外观和要拍的窗口（不会写进偏好）：--theme forest --appearance dark --snapshot-window daylog|notes
            func option(_ name: String) -> String? {
                CommandLine.arguments.firstIndex(of: name).flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
            }
            if let id = option("--theme") { AppTheme.current = AppTheme.theme(id: id) }
            if let mode = option("--appearance").flatMap(AppearanceMode.init(rawValue:)) { NSApp.appearance = mode.nsAppearance }
            func panel<Content: View>(_ content: Content) -> NSWindow {
                let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 158),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.contentView = NSHostingView(rootView: LocalizedRoot { content })
                return panel
            }
            var target: NSWindow = window
            switch option("--snapshot-window") {
            case "focus":
                if let task = TaskSortMode.deadline.sorted(store.tasks()).first(where: { !$0.task.completed }) {
                    focus.start(task: task, url: nil, plannedSeconds: 25 * 60,
                                goal: "读完方法部分，记下两个问题", now: Date().addingTimeInterval(-7 * 60))
                    focus.tick(now: Date())
                }
                target = panel(FocusPanelView(session: focus))
            case "capture":
                let model = QuickCaptureModel()
                model.mode = .log
                target = panel(QuickCaptureView(store: store, model: model, close: {}, resize: { _ in }))
            case "daylog":
                NotesWindowController.shared.showJournal(store: store, date: Date())
                target = NotesWindowController.shared.window ?? window
            case "notes":
                NotesWindowController.shared.show(store: store, taskID: nil, reveal: { _ in }, openDay: { _ in })
                target = NotesWindowController.shared.window ?? window
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [target] in
                guard let view = target.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
                do {
                    try data.write(to: URL(fileURLWithPath: destination))
                    print("Rendered \(Int(view.bounds.width)) × \(Int(view.bounds.height)) window to \(destination)")
                    NSApp.terminate(nil)
                } catch { exit(1) }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if pages.showsTerminal { shell.show() }
        else if pages.showsNotes { showWindowSoftly(notes: true) }
        else { showMainWindow() }
        return true
    }

    /// ⌘W：按窗口代理的规则关闭当前窗口（终端有程序在运行时会先确认）。红绿灯被隐藏后，performClose 可能没有反应，所以直接判断。
    private func closeKeyWindow() {
        guard let target = NSApp.keyWindow ?? window else { return }
        if target === window, pages.showsTerminal { hideMainWindowSoftly(); return }
        // 笔记页上 ⌘W 和 Esc 一样收起窗口。
        if target === window, pages.showsNotes { NotesWindowController.shared.close(); return }
        if target.delegate?.windowShouldClose?(target) ?? true { target.close() }
    }

    private func makeMainContent() -> NSView {
        NSHostingView(rootView: LocalizedRoot {
            ContentView(store: self.store, loginItem: self.loginItem)
                .environmentObject(self.reminders).environmentObject(self.interaction)
                .environmentObject(self.commands).environmentObject(self.toast).environment(\.focusSession, self.focus).environment(\.appCommands, self.commands)
        })
    }

    private func showMainWindow() {
        // 和全局快捷键一样：出现在鼠标所在的屏幕上。
        if !window.isVisible { moveToMouseScreenIfNeeded() }
        mainContent?.restoreIfNeeded()
        switchPage(notes: false)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        Headless.activateApp()
    }

    /// 全局快捷键：Timeline 不在前台就在**当前桌面**淡入并调到最前面（不会把你切到 Timeline 所在的桌面）；
    /// 已经在前台就淡出隐藏，焦点回到刚才的应用。
    private func toggleMainWindow() {
        // 正显示主界面时收起；在笔记 / 日记或终端页时切回主界面。
        if NSApp.isActive, NSApp.keyWindow === window, pages.page == .main, window.isVisible, !window.isMiniaturized {
            hideMainWindowSoftly()
        } else {
            showMainWindowSoftly()
        }
    }

    private func showMainWindowSoftly() { showWindowSoftly(notes: false) }

    /// 窗口显示主界面（`notes == false`）或笔记 / 日记页，带到当前桌面的最前面。窗口已经开着就只换页，不淡入。
    private func showWindowSoftly(notes: Bool) {
        PreviousApp.remember()
        NSApp.unhide(nil)
        moveToMouseScreenIfNeeded()
        if !notes { mainContent?.restoreIfNeeded() }
        switchPage(notes: notes)
        if window.isMiniaturized { window.deminiaturize(nil) }
        let appearing = !window.isVisible
        WindowFade.reset(window)
        if appearing, !Motion.reduced { window.alphaValue = 0 }
        window.makeKeyAndOrderFront(nil)
        Headless.activateApp()
        if appearing, !Motion.reduced { fadeWindow(to: 1, duration: 0.18) }
    }

    /// 只隐藏主窗口本身，不隐藏整个应用：否则之后别的窗口（比如快速记录窗口）一出现，系统会把被隐藏的主窗口一起带回来。
    private func hideMainWindowSoftly() {
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            window.orderOut(nil)
            mainContent?.windowHidden()
            WindowFade.reset(window)
            PreviousApp.restore(handoff: otherWindowForHandoff(excluding: window))
        }
        if Motion.reduced { finish() } else { fadeWindow(to: 0, duration: 0.14, completion: finish) }
    }

    /// 换页时保留共用窗口的几何信息，标题跟着页面走。
    private func switchPage(notes: Bool) {
        if pages.page != (notes ? .notes : .main) { NotificationCenter.default.post(name: .timelineCommitEditing, object: nil) }
        pages.show(notes: notes)
        window.title = AppLocalized(pages.showsNotes ? "笔记 / 日记" : "Timeline")
    }

    private func showTerminalPage() {
        PreviousApp.remember()
        NSApp.unhide(nil)
        if !window.isVisible { moveToMouseScreenIfNeeded() }
        if !pages.showsTerminal { NotificationCenter.default.post(name: .timelineCommitEditing, object: nil) }
        pages.show(.terminal)
        window.title = AppLocalized("终端")
        if window.isMiniaturized { window.deminiaturize(nil) }
        WindowFade.reset(window)
        window.makeKeyAndOrderFront(nil)
        Headless.activateApp()
    }

    /// 收起工作区后，把焦点交给仍可见的额外终端窗口。
    private func otherWindowForHandoff(excluding: NSWindow?) -> NSWindow? {
        if window !== excluding, window.isVisible, !window.isMiniaturized { return window }
        return shell.visibleWindow.flatMap { $0 === excluding ? nil : $0 }
    }

    private func fadeWindow(to alpha: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        WindowFade.animate(window, to: alpha, duration: duration, completion: completion)
    }

    /// 窗口不在鼠标所在的屏幕上时，把它放到那块屏幕的中央，这样按下快捷键后窗口就出现在你正在看的地方。
    private func moveToMouseScreenIfNeeded() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              window.screen != screen else { return }
        let area = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        store.save()
        return true
    }

    // MARK: - 全局快捷键

    private var allHotKeys: [(HotKeyAction, GlobalHotKey)] {
        [(.main, mainHotKey), (.shell, shellHotKey), (.log, logHotKey), (.notes, notesHotKey), (.focusPanel, focusHotKey), (.board, boardHotKey), (.search, searchHotKey)]
    }

    /// 被其他应用占用而注册失败的动作，设置里据此逐条提示。
    private(set) var failedHotKeys: Set<HotKeyAction> = []

    private func applyHotKeyPreference() {
        let wanted = UserDefaults.standard.bool(forKey: Prefs.globalHotKey)
        if wanted, !hotKeysAttempted {
            hotKeysAttempted = true
            registerAllHotKeys()
        } else if !wanted, hotKeysAttempted {
            allHotKeys.forEach { $0.1.unregister() }
            hotKeysAttempted = false
            hotKeysRegistered = false
            failedHotKeys = []
            applyNotesShortcut()
        }
    }

    /// 按设置里最新的绑定重新注册全部快捷键。
    /// 全局快捷键、菜单栏图标菜单、主窗口右上角菜单打开面板都走这里。
    private func togglePanel(_ action: HotKeyAction) {
        switch action {
        case .log: quickCapture.toggle(.log)
        case .notes: toggleNotesGlobally()
        case .focusPanel: focusPanel?.toggleWorkspace()
        case .main: toggleMainWindow()
        case .shell: shell.toggle()
        case .board: BoardWindowController.shared.toggle(store: store)
        case .search: GlobalSearchController.shared.toggle(store: store)
        }
    }

    private func registerAllHotKeys() {
        failedHotKeys = []
        for (action, hotKey) in allHotKeys where !hotKey.rebind(HotKeyStore.binding(for: action)) { failedHotKeys.insert(action) }
        hotKeysRegistered = failedHotKeys.isEmpty
        applyNotesShortcut()
    }

    private func rebindHotKeysIfNeeded() {
        guard hotKeysAttempted else { return }
        registerAllHotKeys()
    }

    // MARK: - 内存压力

    /// 系统内存紧张时释放能重建的东西：看不见的工作板的编辑器状态，工作板窗口没开着时连同编辑器网页一起释放。
    private func installMemoryPressureHandler() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                BoardWindowController.shared.navigation.releaseInactiveEditors()
                ImageTools.purgeThumbnails()
                // 工作板窗口没开着：整个编辑器（一份网页进程）也释放，下次打开时重新加载。
                if BoardWindowController.shared.panel?.isVisible != true { BoardLiveEditorSession.releaseSharedEditor() }
                InlineMarkdownEditor.shared.release()
            }
        }
        source.resume()
        memoryPressure = source
    }

    // MARK: - 键盘导航

    private var isEditingText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSText)?.isEditable == true
            || BoardLiveEditorSession.active?.handlesTextCommands == true
            || InlineMarkdownEditor.shared.handlesTextCommands
    }

    /// 没有文本框占用键盘时：方向键选择事项或切换日期，空格完成，回车编辑，Delete 删除。
    private func installKeyboardNavigation() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handleControlZ(event) || self.handleKey(event) } ? nil : event
        }
    }

    /// ⌃Z / ⌃⇧Z：和 ⌘Z / ⇧⌘Z 一样撤销、重做。只在编辑文字（输入框、工作板）时接管，终端里的 ⌃Z 照常发给程序。
    private func handleControlZ(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard event.keyCode == 6, modifiers == .control || modifiers == [.control, .shift] else { return false }
        let board = (BoardLiveEditorSession.active.map { modifiers == .control ? $0.handlesUndo : $0.handlesRedo } ?? false)
            || InlineMarkdownEditor.shared.handlesTextCommands
        guard board || (NSApp.keyWindow?.firstResponder as? NSText)?.isEditable == true else { return false }
        if modifiers == .control { undoAction(nil) } else { redoAction(nil) }
        return true
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let keyWindow = NSApp.keyWindow, keyWindow === window, pages.page == .main, window.attachedSheet == nil, !isEditingText,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 126 where !shift: commands.send(.selectAdjacent(-1))
        case 125 where !shift: commands.send(.selectAdjacent(1))
        case 123 where !shift: commands.send(.shiftDay(-1))
        case 124 where !shift: commands.send(.shiftDay(1))
        case 49 where interaction.selectedTaskID != nil: commands.send(.toggleSelected)
        case 36, 76: guard interaction.selectedTaskID != nil else { return false }; commands.send(.editSelected)
        case 51, 117: guard interaction.selectedTaskID != nil else { return false }; commands.send(.deleteSelected)
        case 53: guard interaction.selectedTaskID != nil else { return false }; commands.send(.deselect)
        // 选中任务时的字母键：和扇形菜单里的操作一一对应。
        case 45 where interaction.selectedTaskID != nil && !shift: commands.send(.notesSelected)     // N
        case 2 where interaction.selectedTaskID != nil && !shift: commands.send(.deadlineSelected)   // D
        case 17 where interaction.selectedTaskID != nil && !shift: commands.send(.tagsSelected)      // T
        case 35 where interaction.selectedTaskID != nil && !shift: commands.send(.pinSelected)       // P
        case 7 where interaction.selectedTaskID != nil && !shift: commands.send(.dropSelected)       // X
        case 3 where interaction.selectedTaskID != nil && !shift: commands.send(.focusSelected)      // F
        case 46 where interaction.selectedTaskID != nil: commands.send(.postponeSelected(shift ? -1 : 1)) // M / ⇧M
        case 44 where shift: commands.send(.shortcuts)                                               // ?
        default: return false
        }
        return true
    }

    // MARK: - 撤销 / 重做

    /// ⌘Z：输入框里有能撤销的打字就撤销打字；没有（比如刚在日志窗口里删了日志，光标还在输入框里）就撤销上一步操作。
    @objc private func undoAction(_ sender: Any?) {
        if InlineMarkdownEditor.shared.handlesTextCommands { InlineMarkdownEditor.shared.undo(); return }
        if let editor = BoardLiveEditorSession.active, editor.handlesUndo { editor.undo(); return }
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable, editor.undoManager?.canUndo == true {
            editor.undoManager?.undo()
        } else { store.undo() }
    }

    @objc private func redoAction(_ sender: Any?) {
        if InlineMarkdownEditor.shared.handlesTextCommands { InlineMarkdownEditor.shared.redo(); return }
        if let editor = BoardLiveEditorSession.active, editor.handlesRedo { editor.redo(); return }
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable, editor.undoManager?.canRedo == true {
            editor.undoManager?.redo()
        } else { store.redo() }
    }

    /// 真正退出时才关 socket：退出被取消（有终端在运行、保存失败）时命令行服务要继续可用。
    func applicationWillTerminate(_ notification: Notification) {
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if boardTerminationPending { return .terminateLater }
        if !boardTerminationPrepared, let editor = BoardLiveEditorSession.active, editor.ready {
            boardTerminationPending = true
            editor.commit { [weak self] in
                guard let self else { sender.reply(toApplicationShouldTerminate: false); return }
                self.boardTerminationPending = false
                self.boardTerminationPrepared = true
                let reply = self.applicationShouldTerminate(sender)
                self.boardTerminationPrepared = false
                sender.reply(toApplicationShouldTerminate: reply == .terminateNow)
            }
            return .terminateLater
        }
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        window.makeFirstResponder(nil)
        if shell.busyCount > 0 {
            let alert = NSAlert()
            alert.messageText = AppLocalizedFormat("有 %lld 个终端正在运行程序", shell.busyCount)
            alert.informativeText = AppLocalized("退出 Timeline 会结束它们（比如正在进行的 agent 对话）。")
            alert.addButton(withTitle: AppLocalized("取消"))
            alert.addButton(withTitle: AppLocalized("仍然退出"))
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        // 先确认能保存，再结束终端和专注：选「返回 Timeline」时它们必须原样保留。
        if !store.isReadOnly {
            store.save()
            if store.errorMessage != nil {
                let alert = NSAlert()
                alert.messageText = AppLocalized("还有未保存的修改")
                alert.informativeText = AppLocalized("请返回 Timeline 重试保存，或使用「文件」菜单导出备份。直接退出会丢失未保存的修改。")
                alert.addButton(withTitle: AppLocalized("返回 Timeline"))
                alert.addButton(withTitle: AppLocalized("仍然退出"))
                if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
            }
        }
        shell.terminateAll()
        focus.stop(reason: "应用退出")
        // 结束专注会写一条记录。
        if !store.isReadOnly, store.hasPendingSave { store.save() }
        return .terminateNow
    }

    // MARK: - 菜单

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuAction else { return }
        if let key = action.toggleKey {
            let defaults = UserDefaults.standard
            let current = defaults.object(forKey: key) == nil ? action.toggleDefault : defaults.bool(forKey: key)
            defaults.set(!current, forKey: key)
        } else {
            action.run()
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.representedObject as? MenuAction else {
            if item.action == #selector(undoAction(_:)) {
                let typing = isEditingText || BoardLiveEditorSession.active?.handlesUndo == true
                let name = store.undoManager.undoActionName
                item.title = typing || name.isEmpty ? AppLocalized("撤销") : AppLocalizedFormat("撤销%@", AppLocalized(name))
                return typing || store.undoManager.canUndo
            }
            if item.action == #selector(redoAction(_:)) {
                let typing = isEditingText || BoardLiveEditorSession.active?.handlesRedo == true
                let name = store.undoManager.redoActionName
                item.title = typing || name.isEmpty ? AppLocalized("重做") : AppLocalizedFormat("重做%@", AppLocalized(name))
                return typing || store.undoManager.canRedo
            }
            return true
        }
        if let key = action.toggleKey {
            let defaults = UserDefaults.standard
            let on = defaults.object(forKey: key) == nil ? action.toggleDefault : defaults.bool(forKey: key)
            item.state = on ? .on : .off
        }
        if action.disabledWhileTyping { return !isEditingText && NSApp.keyWindow === window && pages.page == .main }
        return true
    }

    /// 「笔记」菜单项。全局快捷键生效时，按键由全局热键处理，菜单项不再绑定同一个键（否则会触发两次），只在标题里写出快捷键；
    /// 全局快捷键被关闭或这个组合被别的应用占用时，退回到菜单快捷键（Timeline 在前台时有效）。
    private var notesMenuItem = NSMenuItem()

    private func applyNotesShortcut() {
        let binding = HotKeyStore.binding(for: .notes)
        let globalWorks = hotKeysAttempted && !failedHotKeys.contains(.notes)
        if globalWorks {
            notesMenuItem.title = AppLocalized("笔记（开 / 关）") + "    \(binding.label)"
            notesMenuItem.keyEquivalent = ""
        } else {
            let equivalent = binding.menuEquivalent
            notesMenuItem.title = AppLocalized("笔记（开 / 关）")
            notesMenuItem.keyEquivalent = equivalent.key
            notesMenuItem.keyEquivalentModifierMask = equivalent.mask
        }
    }

    /// 全局快捷键：先在当前桌面显示笔记，再激活应用，避免跳回旧桌面。
    private func toggleNotesGlobally() {
        let wasActive = NSApp.isActive
        PreviousApp.remember()
        NSApp.unhide(nil)
        // 笔记窗口建好后直接开关它：主窗口常收起着，界面可能已经释放，不能再靠它转发。
        let notes = NotesWindowController.shared
        guard notes.window != nil else {
            mainContent?.restoreIfNeeded()
            commands.send(.notesHotKey(appWasActive: wasActive))
            return
        }
        switch notes.hotKeyAction(wasActive) {
        case .open, .bringForward: notes.bringToFront()
        case .close: notes.close()
        }
    }

    private func menuItem(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command],
                          typingSensitive: Bool = false, toggle: (key: String, defaultOn: Bool)? = nil,
                          _ run: @escaping () -> Void = {}) -> NSMenuItem {
        let item = NSMenuItem(title: AppLocalized(title), action: #selector(runMenuAction(_:)), keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        let action = MenuAction(run)
        action.disabledWhileTyping = typingSensitive
        if let toggle { action.toggleKey = toggle.key; action.toggleDefault = toggle.defaultOn }
        item.representedObject = action
        item.target = self
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: AppLocalized(title))
        items.forEach { menu.addItem($0) }
        let holder = NSMenuItem(title: AppLocalized(title), action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let send = { [commands, shell] (command: AppCommand) in { if !(shell.isTerminal(NSApp.keyWindow)) { commands.send(command) } } }
        /// 同一个快捷键：终端是当前窗口时做终端的事，否则做 Timeline 的事。
        let shell = self.shell
        let either = { (terminal: @escaping (ShellWindowController) -> Void, other: @escaping () -> Void) in {
            if shell.isTerminal(NSApp.keyWindow) { terminal(shell) } else { other() }
        } }
        let onlyInTerminal = { (action: @escaping (ShellWindowController) -> Void) in {
            guard shell.isTerminal(NSApp.keyWindow) else { return }
            action(shell)
        } }
        let notes = NotesWindowController.shared
        /// 换日期：合并窗口是当前窗口就换日记日期，否则换主窗口选中的日期。
        let shiftDay = { [commands] (amount: Int) in { if notes.isKey { notes.shift(amount) } else { commands.send(.shiftDay(amount)) } } }
        let arrow = { (scalar: Int) in String(UnicodeScalar(scalar)!) }
        let left = arrow(NSLeftArrowFunctionKey), right = arrow(NSRightArrowFunctionKey)

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: AppLocalized("关于 Timeline"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("设置…", key: ",") { [weak self] in self?.settings.show() })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: AppLocalized("隐藏 Timeline"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: AppLocalized("退出 Timeline"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let file = submenu("文件", [
            menuItem("新建待办", send(.newTodo)),
            menuItem("写日志…", key: "l", send(.newLog)),
            menuItem("快速添加待办…") { [weak self] in self?.quickCapture.toggle(.todo) },
            menuItem("快速写日志…") { [weak self] in self?.quickCapture.toggle(.log) },
            menuItem("插入链接…    ⌘K", send(.insertLink)),
            .separator(),
            menuItem("导出为文件夹…", send(.export)),
            menuItem("最近删除…", send(.recentlyDeleted)),
            menuItem("备份与恢复…", send(.backups)),
            menuItem("打开数据文件夹") { [weak self] in if let store = self?.store { NSWorkspace.shared.open(store.directory) } },
        ])
        mainMenu.addItem(file)

        let editMenu = NSMenu(title: AppLocalized("编辑"))
        let undo = editMenu.addItem(withTitle: AppLocalized("撤销"), action: #selector(undoAction(_:)), keyEquivalent: "z")
        undo.target = self
        let redo = NSMenuItem(title: AppLocalized("重做"), action: #selector(redoAction(_:)), keyEquivalent: "z")
        redo.target = self
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        for (title, selector, key) in [("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: AppLocalized(title), action: Selector(selector), keyEquivalent: key)
        }
        editMenu.addItem(.separator())
        // ⌘F：笔记窗口里搜它自己（笔记或日记页的搜索框）；其他窗口里打开全局搜索。
        editMenu.addItem(menuItem("搜索任务、日志与总结…", key: "f") { [weak self] in
            let notes = NotesWindowController.shared
            if notes.isKey { notes.workspace.focusSearch() }
            else if let store = self?.store { GlobalSearchController.shared.show(store: store) }
        })
        let editItem = NSMenuItem(title: AppLocalized("编辑"), action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let terminal = submenu("终端", [
            // ⌘N：在终端里是新建终端窗口；在其他窗口里打开笔记（选中了任务就打开它的笔记）。
            menuItem("新建终端窗口 / 打开笔记", key: "n") { [weak self] in
                guard let self else { return }
                if shell.isTerminal(NSApp.keyWindow) { shell.newWindow() }
                else if NotesWindowController.shared.isKey { NotesWindowController.shared.close() }
                else { commands.send(.notes) }
            },
            // ⌘T：终端里新建标签页；其他窗口里回到今天。
            menuItem("新建标签页（终端）/ 回到今天", key: "t", either({ $0.newTab() }, { [commands] in
                if notes.isKey { notes.setDate(Date()) } else { commands.send(.today) }
            })),
            menuItem("关闭标签页 / 窗口", key: "w") { [weak self] in self?.closeKeyWindow() },
            .separator(),
            menuItem("向右分栏", key: "d") { [weak self] in if shell.isTerminal(NSApp.keyWindow) { self?.shell.splitPane(sideBySide: true) } },
            menuItem("向下分栏", key: "d", modifiers: [.command, .shift]) { [weak self] in if shell.isTerminal(NSApp.keyWindow) { self?.shell.splitPane(sideBySide: false) } },
            menuItem("关闭窗格", key: "w", modifiers: [.command, .option]) { [weak self] in if shell.isTerminal(NSApp.keyWindow) { self?.shell.closePane() } },
            .separator(),
            // ⌘[ ⌘]：终端里切窗格；其他窗口里切月份。
            menuItem("上一个窗格（终端）/ 上个月", key: "[", either({ $0.selectPane(-1) }, send(.shiftMonth(-1)))),
            menuItem("下一个窗格（终端）/ 下个月", key: "]", either({ $0.selectPane(1) }, send(.shiftMonth(1)))),
            menuItem("上一个标签页", key: "[", modifiers: [.command, .shift], onlyInTerminal { $0.selectAdjacentTab(-1) }),
            menuItem("下一个标签页", key: "]", modifiers: [.command, .shift], onlyInTerminal { $0.selectAdjacentTab(1) }),
        ] + (1...9).map { number in
            menuItem(AppLocalizedFormat("切换到第 %lld 个标签页", number), key: String(number), onlyInTerminal { $0.selectTab(at: number - 1) })
        } + [
            .separator(),
            // ⌘K：终端里清屏；其他窗口里插入链接。
            menuItem("清屏（终端）/ 插入链接", key: "k", either({ $0.clearScreen() }, send(.insertLink))),
            .separator(),
            menuItem("显示 / 隐藏全部终端") { [weak self] in self?.shell.toggle() },
        ])
        mainMenu.addItem(terminal)

        let task = submenu("事项", [
            menuItem("完成 / 取消完成（空格）", typingSensitive: true, send(.toggleSelected)),
            menuItem("编辑所选事项（回车）", typingSensitive: true, send(.editSelected)),
            menuItem("删除所选事项（Delete）", typingSensitive: true, send(.deleteSelected)),
            .separator(),
            menuItem("选择上一条（↑）", typingSensitive: true, send(.selectAdjacent(-1))),
            menuItem("选择下一条（↓）", typingSensitive: true, send(.selectAdjacent(1))),
            .separator(),
            menuItem("打开笔记（N）", typingSensitive: true, send(.notesSelected)),
            menuItem("截止日期…（D）", typingSensitive: true, send(.deadlineSelected)),
            menuItem("标签…（T）", typingSensitive: true, send(.tagsSelected)),
            menuItem("固定 / 取消固定（P）", typingSensitive: true, send(.pinSelected)),
            menuItem("放弃 / 恢复（X）", typingSensitive: true, send(.dropSelected)),
            menuItem("开始 / 结束专注（F）", typingSensitive: true, send(.focusSelected)),
            menuItem("推到明天（M）", typingSensitive: true, send(.postponeSelected(1))),
            menuItem("提前一天（⇧M）", typingSensitive: true, send(.postponeSelected(-1))),
            .separator(),
            menuItem("把逾期事项的截止日期改到今天", key: "m", modifiers: [.command, .shift], send(.rollover)),
        ])
        mainMenu.addItem(task)

        notesMenuItem = menuItem("笔记（开 / 关）", send(.toggleNotes))
        applyNotesShortcut()
        let view = submenu("视图", [
            menuItem("回到今天    ⌘T", { [commands] in if notes.isKey { notes.setDate(Date()) } else { commands.send(.today) } }),
            menuItem("前一天", key: left, modifiers: [.command, .option], typingSensitive: true, shiftDay(-1)),
            menuItem("后一天", key: right, modifiers: [.command, .option], typingSensitive: true, shiftDay(1)),
            menuItem("上个月", send(.shiftMonth(-1))),
            menuItem("下个月", send(.shiftMonth(1))),
            .separator(),
            notesMenuItem,
            menuItem("工作板（开 / 关）", { [weak self] in
                guard let self else { return }
                BoardWindowController.shared.toggle(store: self.store)
            }),
            .separator(),
            menuItem("未完成事项…", send(.agenda(.unfinished))),
            menuItem("即将截止…", send(.agenda(.upcoming))),
            menuItem("已逾期…", send(.agenda(.overdue))),
            .separator(),
            menuItem("显示 / 隐藏待办清单", key: "\\", send(.toggleTasks)),
            menuItem("当天日志（开 / 关）", key: "j", send(.toggleDayLog)),
            menuItem("隐藏已完成", key: "h", modifiers: [.command, .shift], toggle: (Prefs.hideCompleted, false)),
            menuItem("单击日期时展开待办清单", toggle: (Prefs.clickExpands, true)),
        ])
        mainMenu.addItem(view)

        let windowMenu = NSMenu(title: AppLocalized("窗口"))
        windowMenu.addItem(withTitle: AppLocalized("最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: AppLocalized("缩放"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(menuItem("显示 / 隐藏 Timeline") { [weak self] in self?.toggleMainWindow() })
        windowMenu.addItem(menuItem("固定在屏幕中央", toggle: (Prefs.mainWindowCentered, true)))
        let windowItem = NSMenuItem(title: AppLocalized("窗口"), action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        let helpMenu = NSMenu(title: AppLocalized("帮助"))
        helpMenu.addItem(menuItem("快捷键一览    ?", key: "/", modifiers: [.command]) { [weak self] in self?.commands.send(.shortcuts) })
        let helpItem = NSMenuItem(title: AppLocalized("帮助"), action: nil, keyEquivalent: "")
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }
}

/// 笔记 / 日记页放在主窗口里：和主界面互斥，同一个窗口里切换。
extension AppDelegate: NotesHost {
    var hostWindow: NSWindow { window }
    var showsNotes: Bool { pages.showsNotes }
    func installNotes(_ view: NSView) { pages.setNotes(view) }
    func presentNotes() { showWindowSoftly(notes: true) }
    func dismissNotes() { hideMainWindowSoftly() }
}
