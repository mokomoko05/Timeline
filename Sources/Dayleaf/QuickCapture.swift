import AppKit
import Carbon.HIToolbox
import SwiftUI
import DayleafCore

/// 全局热键（Carbon），不需要辅助功能权限。可同时注册多个，按各自的 identifier 区分。
final class GlobalHotKey {
    /// 当前绑定的显示名（跟随用户在设置里的自定义）。
    static var logLabel: String { HotKeyStore.binding(for: .log).label }
    static var mainLabel: String { HotKeyStore.binding(for: .main).label }
    static var shellLabel: String { HotKeyStore.binding(for: .shell).label }

    let identifier: UInt32
    var keyCode: UInt32
    var modifiers: UInt32
    var onPress: (() -> Void)?
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(identifier: UInt32, keyCode: Int, modifiers: Int = controlKey | optionKey) {
        self.identifier = identifier
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
    }

    convenience init(action: HotKeyAction) {
        let binding = HotKeyStore.binding(for: action)
        self.init(identifier: action.identifier, keyCode: binding.keyCode, modifiers: binding.modifiers)
    }

    /// 改成新的组合并重新注册。
    @discardableResult
    func rebind(_ binding: HotKeyBinding) -> Bool {
        keyCode = UInt32(binding.keyCode)
        modifiers = UInt32(binding.modifiers)
        return register()
    }

    @discardableResult
    func register() -> Bool {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            // 每个实例都会收到所有热键事件，只处理属于自己的那个。
            guard status == noErr, pressed.id == hotKey.identifier else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { hotKey.onPress?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return false }
        let hotKeyID = EventHotKeyID(signature: OSType(0x444C4631), id: identifier)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
        if status != noErr { unregister() }
        return status == noErr
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
    }

    deinit { unregister() }
}

enum QuickCaptureMode: String { case todo, log }

/// 控制器和窗口里的视图共用：窗口开着时按另一个热键，直接切换模式。
@MainActor
final class QuickCaptureModel: ObservableObject {
    @Published var mode: QuickCaptureMode = .todo
    /// 草稿：窗口一失焦就会关闭（比如去别的应用复制东西），所以文字、图片、标签放在这里，窗口关掉再打开仍在，只有成功提交才清空。
    @Published var text = ""
    @Published var images: [String] = []
    @Published var tags: [String] = []
    /// 这条日志明确关联的待办（`@` 选的，或用选择器选的）；`unlinked` 表示明确不关联。都没有时按专注 / 固定关联自动处理。
    @Published var link: UUID?
    @Published var unlinked = false

    var hasDraft: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || !tags.isEmpty || link != nil
    }

    func clearDraft() {
        text = ""
        images = []
        tags = []
        link = nil
        unlinked = false
    }
}

private final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 菜单栏图标与快速记录浮窗：不切换窗口，直接添加待办或写一条日志。
@MainActor
final class QuickCaptureController: NSObject, NSMenuDelegate, NSWindowDelegate {
    private let store: JournalStore
    private let openMain: () -> Void
    private let openShell: () -> Void
    private var panel: QuickPanel?
    private let model = QuickCaptureModel()
    private var statusItem: NSStatusItem?
    private let summaryItem = NSMenuItem()
    private var hotKeyItems: [(item: NSMenuItem, action: HotKeyAction, title: String)] = []
    private var hotKeyObserver: NSObjectProtocol?

    init(store: JournalStore, openMain: @escaping () -> Void, openShell: @escaping () -> Void = {}) {
        self.store = store
        self.openMain = openMain
        self.openShell = openShell
        super.init()
    }

    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "leaf", accessibilityDescription: "Scheduler")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        hotKeyItems = []
        func hotKeyItem(_ title: String, _ action: HotKeyAction, _ selector: Selector) {
            let menuItem = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
            menuItem.target = self
            hotKeyItems.append((menuItem, action, title))
        }
        let todoItem = menu.addItem(withTitle: "快速添加待办…", action: #selector(captureTodo), keyEquivalent: "")
        todoItem.target = self
        hotKeyItem("快速写日志…", .log, #selector(captureLog))
        hotKeyItem("内置终端（zsh）", .shell, #selector(openShellWindow))
        let reset = menu.addItem(withTitle: "重置快速记录窗口位置", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(.separator())
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)
        hotKeyItem("打开 Scheduler", .main, #selector(openApp))
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Scheduler", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        item.menu = menu
        statusItem = item
        refreshHotKeyLabels()
        if hotKeyObserver == nil {
            hotKeyObserver = NotificationCenter.default.addObserver(forName: .dayleafHotKeysChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshHotKeyLabels() }
            }
        }
    }

    /// 图标提示和菜单项上的快捷键都读当前设置，改键后立即更新。
    func refreshHotKeyLabels() {
        statusItem?.button?.toolTip = "Scheduler · 打开 \(GlobalHotKey.mainLabel) · 日志 \(GlobalHotKey.logLabel) · 终端 \(GlobalHotKey.shellLabel)"
        for entry in hotKeyItems {
            let binding = HotKeyStore.binding(for: entry.action)
            var mask: NSEvent.ModifierFlags = []
            if binding.modifiers & controlKey != 0 { mask.insert(.control) }
            if binding.modifiers & optionKey != 0 { mask.insert(.option) }
            if binding.modifiers & shiftKey != 0 { mask.insert(.shift) }
            if binding.modifiers & cmdKey != 0 { mask.insert(.command) }
            let name = HotKeyBinding.keyName(binding.keyCode)
            // 单个字母、数字、符号可以作为菜单快捷键显示在右侧；方向键、F 键、空格等没有对应字符，写在标题后面。
            if name.count == 1, name.unicodeScalars.allSatisfy({ $0.isASCII }) {
                entry.item.title = entry.title
                entry.item.keyEquivalent = name.lowercased()
                entry.item.keyEquivalentModifierMask = mask
            } else {
                entry.item.title = "\(entry.title)    \(binding.label)"
                entry.item.keyEquivalent = ""
            }
        }
    }

    func removeStatusItem() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshHotKeyLabels()
        // 和清单顶部的摘要同一个口径：按截止日期算。
        let summary = store.taskSummary()
        summaryItem.title = summary.overdue > 0 ? "今天截止 \(summary.dueToday) · 逾期 \(summary.overdue)" : "今天截止 \(summary.dueToday)"
    }

    @objc private func captureTodo() { toggle(.todo) }
    @objc private func captureLog() { toggle(.log) }
    @objc private func openApp() { openMain() }
    @objc private func openShellWindow() { openShell() }

    /// 像 Spotlight：窗口没开就打开；已经开着时，再按同一个热键关闭，按另一个热键则切换到那个模式。
    func toggle(_ mode: QuickCaptureMode) {
        if let panel, panel.isVisible {
            if model.mode == mode { panel.close() } else { model.mode = mode }
            return
        }
        show(mode)
    }

    func show(_ mode: QuickCaptureMode) {
        if let panel, panel.isVisible { panel.close() }
        model.mode = mode
        let view = QuickCaptureView(store: store, model: model, close: { [weak self] in self?.panel?.close() },
                                    resize: { [weak self] height in self?.resize(height: height) })
        let host = NSHostingView(rootView: LocalizedRoot { view })
        // 一开始就按内容的真实高度创建，不先给个临时高度再长出来。
        host.setFrameSize(NSSize(width: 340, height: 158))
        host.layoutSubtreeIfNeeded()
        let fitted = host.fittingSize
        if fitted.height > 60 { host.setFrameSize(NSSize(width: 340, height: fitted.height)) }
        let panel = QuickPanel(contentRect: NSRect(origin: .zero, size: host.frame.size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.setFrameOrigin(restoredOrigin(for: panel.frame.size))
        panel.delegate = self
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) { panel?.close() }

    /// 内容高度变化（出现缩略图）时调整窗口，保持顶边位置不动。
    private func resize(height: CGFloat) {
        guard let panel, abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    /// 用户拖到哪里就记住哪里；下次呼出时回到同一位置。
    /// 记的是**左上角**而不是左下角：窗口高度会随内容变（标签栏、图片、多行输入），按左下角记，下次高度不同位置就会偏。
    func windowDidMove(_ notification: Notification) {
        guard let frame = panel?.frame else { return }
        UserDefaults.standard.set(NSStringFromPoint(Self.topLeft(of: frame)), forKey: Self.positionKey)
    }

    /// 旧版本记的是左下角（`quickCaptureOrigin`），高度不确定，不再沿用。
    static let positionKey = "quickCaptureTopLeft"

    static func topLeft(of frame: NSRect) -> NSPoint { NSPoint(x: frame.minX, y: frame.maxY) }
    static func origin(topLeft: NSPoint, height: CGFloat) -> NSPoint { NSPoint(x: topLeft.x, y: topLeft.y - height) }

    private func defaultOrigin(for size: NSSize) -> NSPoint {
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        return NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - frame.height * 0.28 - size.height)
    }

    /// 已保存的位置仍在某块屏幕内才使用；外接显示器拔掉后自动回到默认位置。
    private func restoredOrigin(for size: NSSize) -> NSPoint {
        guard let saved = UserDefaults.standard.string(forKey: Self.positionKey) else { return defaultOrigin(for: size) }
        let origin = Self.origin(topLeft: NSPointFromString(saved), height: size.height)
        let rect = NSRect(origin: origin, size: size)
        let visible = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(rect)
            return overlap.width >= 120 && overlap.height >= 60
        }
        return visible ? origin : defaultOrigin(for: size)
    }

    @objc private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.positionKey)
        if let panel { panel.setFrameOrigin(defaultOrigin(for: panel.frame.size)); UserDefaults.standard.removeObject(forKey: Self.positionKey) }
    }
}

struct QuickCaptureView: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var model: QuickCaptureModel
    let close: () -> Void
    let resize: (CGFloat) -> Void
    @StateObject private var mention = MentionState()
    @State private var restored = false
    @State private var focused = true
    @State private var message: String?
    @State private var failure: String?
    /// 草稿都在 model 里（窗口关掉也不丢）。
    private var text: String { get { model.text } nonmutating set { model.text = newValue } }
    private var images: [String] { get { model.images } nonmutating set { model.images = newValue } }
    /// 这条日志要带的标签（不需要关联待办）。
    private var tags: [String] { get { model.tags } nonmutating set { model.tags = newValue } }

    private var mode: QuickCaptureMode {
        get { model.mode }
        nonmutating set { model.mode = newValue }
    }
    /// 待办模式没有专属的全局快捷键，用 Esc 关闭；日志模式再按日志的快捷键关闭。
    private var closeHint: String { mode == .todo ? "Esc 关闭" : "再按 \(GlobalHotKey.logLabel) 关闭" }

    private var parsed: QuickAdd { QuickAdd.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule().fill(Palette.line).frame(width: 36, height: 4)
                .frame(maxWidth: .infinity).help("按住窗口空白处可拖动，位置会被记住")
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                Image(systemName: "leaf.fill").foregroundStyle(Palette.success)
                Picker("类型", selection: $model.mode) {
                    Text("待办").tag(QuickCaptureMode.todo)
                    Text("日志").tag(QuickCaptureMode.log)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 120)
                Spacer()
                Text("Tab 切换 · \(closeHint) · 可拖动").font(.system(size: UIScale.pt(11))).foregroundStyle(Palette.muted)
            }
            HStack(spacing: 8) {
                Image(systemName: mode == .todo ? "plus.circle" : "chevron.right.2").foregroundStyle(Palette.accent)
                TaskInput(text: $model.text, focused: $focused,
                          placeholder: mode == .todo ? "添加待办，例如：明天 15:00 开会 #项目A" : "记录…  @ 待办 · # 标签 · /done /block /plan · ⌘V 贴图",
                          fontSize: 12, submit: submit, cancel: close, complete: { mode = mode == .todo ? .log : .todo },
                          onPasteImages: mode == .log ? addImages : nil,
                          minHeight: 42, maxLines: 4, allowsNewlines: mode == .log, mention: mode == .log ? mention : nil)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Palette.background, in: RoundedRectangle(cornerRadius: 10))
            if mode == .log {
                Color.clear.frame(height: 0)
            }
            if mode == .log, !images.isEmpty {
                PendingImagesStrip(store: store, names: images,
                                   remove: { name in images.removeAll { $0 == name } },
                                   preview: { NSWorkspace.shared.open(store.imageURL(images[$0])) })
            }
            Group {
                if let message {
                    Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(Palette.success)
                } else if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(Palette.deadline)
                } else if restored, model.hasDraft {
                    HStack(spacing: 6) {
                        Label("已恢复上次没发送的草稿", systemImage: "arrow.uturn.backward.circle").foregroundStyle(Palette.muted)
                        Button("清空") { model.clearDraft(); restored = false; focused = true }
                            .buttonStyle(.plain).foregroundStyle(Palette.accent)
                    }
                } else if mode == .todo {
                    if parsed.hasSchedule || !parsed.tags.isEmpty {
                        ParsedChips(parsed: parsed)
                    } else {
                        Text("回车添加；写上日期、时间会成为截止日期，不写则之后再分配").foregroundStyle(Palette.muted)
                    }
                } else {
                    LogChipsBar(store: store, link: $model.link, unlinked: $model.unlinked, tags: $model.tags, contextTags: model.tags,
                                hint: "回车记录到今天 · @ 关联待办 · # 选标签")
                }
            }.font(.system(size: UIScale.pt(12))).frame(height: LogChipsBar.height, alignment: .leading)
        }
        .padding(16)
        .frame(width: 340)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line))
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .padding(1)
        .background(GeometryReader { proxy in Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height) })
        .onPreferenceChange(PanelHeightKey.self) { resize($0) }
        .onChange(of: mode) { _ in failure = nil; focused = true }
        .onChange(of: model.text) { _ in restored = false }
        .onAppear {
            restored = model.hasDraft
            mention.triggers = [.task, .tag]
            mention.provider = MentionProviders.make(store: store, contextTags: { [model] in model.tags }, chosenTags: { [model] in model.tags })
            mention.onPick = { [model] item in
                switch item {
                case .task(let task): model.link = task.id; model.unlinked = false
                case .tag(let tag):
                    model.tags = TagText.merge(model.tags, [tag.name])
                }
            }
        }
        .popover(isPresented: Binding(get: { mention.isActive && mode == .log }, set: { if !$0 { mention.dismiss() } }), arrowEdge: .bottom) {
            MentionList(state: mention, store: store, contextTags: model.tags).frame(width: 320)
        }
    }

    private func addImages(_ datas: [Data]) {
        images += ImageTools.save(datas, in: store)
        failure = nil
        focused = true
    }

    private func submit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty || (mode == .log && !images.isEmpty), message == nil else { return }
        failure = nil
        switch mode {
        case .todo:
            guard let added = store.addParsedTodo(value, on: Date()) else { failure = "当前数据只读，无法保存。"; return }
            message = added.task.dueDate.map { "已添加 #\(added.task.number ?? 0)，截止\($0.relativeLabel)" } ?? "已添加 #\(added.task.number ?? 0)，还没有截止日期"
        case .log:
            do {
                let paused = store.focusPaused
                let result = try store.quickLogEntry(value, images: images,
                                                     taskID: paused ? nil : model.link,
                                                     linkDefault: paused ? false : !model.unlinked,
                                                     tags: paused ? [] : tags,
                                                     allowInlineTaskReference: !paused, on: Date())
                guard case .entry = result.command else { failure = "快速记录只支持普通文字和 /note /done /block /plan。"; return }
                let linked = result.entry.flatMap(FocusHint.label(of:)).map { "，已关联 " + $0 } ?? ""
                message = (images.isEmpty ? "已记录" : "已记录，含 \(images.count) 张图片") + linked
                    + (paused ? " · 专注暂停，未关联任务或标签" : (tags.isEmpty ? "" : "，标签 " + tags.map { "#" + $0 }.joined(separator: " ")))
                images = []
                tags = []
                model.link = nil
                model.unlinked = false
                ImageIndexer.run(store: store)
            } catch { failure = error.localizedDescription; return }
        }
        text = ""
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            close()
        }
    }
}

/// 输入框下方的解析结果：用户在提交前就能确认「明天 15:00」被理解对了。
struct ParsedChips: View {
    let parsed: QuickAdd
    /// 识别出的日期是任务的截止日期，标签上写明。
    var dayIsDeadline = false

    var body: some View {
        HStack(spacing: 6) {
            if let day = parsed.day { chip("calendar", (dayIsDeadline ? "截止 " : "") + day.relativeLabel) }
            if let hour = parsed.hour { chip("clock", String(format: "%02d:%02d", hour, parsed.minute)) }
            if let reminder = parsed.reminderMinutes { chip("bell", reminder == 0 ? "准时提醒" : "提前 \(Self.duration(reminder))") }
            if parsed.repeatRule != .none { chip("repeat", parsed.repeatRule.title) }
            ForEach(parsed.tags, id: \.self) { chip("tag", $0) }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: UIScale.pt(11), weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Palette.soft, in: Capsule())
            .foregroundStyle(Palette.accent)
    }

    private static func duration(_ minutes: Int) -> String {
        if minutes % 1440 == 0 { return "\(minutes / 1440) 天" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }
}

private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 160
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

enum FocusHint {
    /// 一条日志关联的待办：「#3 读论文」；没有关联为 nil。
    static func label(of log: DailyLogEntry) -> String? {
        guard let title = log.taskTitle else { return nil }
        let short = title.count > 24 ? String(title.prefix(24)) + "…" : title
        let prefix: String = log.taskNumber.map { "#\($0) " } ?? ""
        return prefix + short
    }

    /// 「#3 读论文」；任务标题太长时截断。
    static func label(_ task: ScheduledTask) -> String {
        let title = String(TaskText.rendered(task.task.title).characters)
        let short = title.count > 24 ? String(title.prefix(24)) + "…" : title
        return "\(task.task.number.map { "#\($0) " } ?? "")\(short)"
    }
}
