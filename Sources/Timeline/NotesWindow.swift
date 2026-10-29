import AppKit
import SwiftUI
import TimelineCore

private final class NotesWindow: QuietWindow {
    /// 没有文字框处理 Esc 时关闭窗口，和原来 sheet 里的「关闭」一致。
    override func cancelOperation(_ sender: Any?) { close() }
}

enum NotesHotKeyAction: Equatable {
    case open, close, bringForward

    static func resolve(appWasActive: Bool, visible: Bool, onActiveSpace: Bool, isKey: Bool, miniaturized: Bool) -> Self {
        guard visible else { return .open }
        return appWasActive && onActiveSpace && isKey && !miniaturized ? .close : .bringForward
    }
}

/// 和主界面共用一个窗口时，笔记 / 日记页的宿主（AppDelegate）：两页互斥，同一个窗口里切换。
@MainActor
protocol NotesHost: AnyObject {
    var hostWindow: NSWindow { get }
    /// 窗口里现在显示的是笔记 / 日记页。
    var showsNotes: Bool { get }
    /// 第一次打开时把笔记页放进窗口（先藏着）。
    func installNotes(_ view: NSView)
    /// 切到笔记页并把窗口带到前面。
    func presentNotes()
    /// 关掉笔记页：收起整个窗口，焦点回到之前的应用。
    func dismissNotes()
}

/// 笔记 / 日记。应用里和主界面共用主窗口（`host`），切换时整页换掉，窗口位置大小不变；
/// 没有宿主时（测试、截图）用一个独立的、可以自由调整大小的窗口。
@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    static let frameName = "TimelineNotesWindow"
    /// 应用里唯一的笔记页：界面和全局快捷键共用同一个。
    static let shared = NotesWindowController()
    /// 共用的主窗口；设置后不再建独立窗口。
    weak var host: NotesHost?
    private var ownWindow: NSWindow?
    private var hostedView: NSHostingView<AnyView>?
    /// 笔记页所在的窗口（还没打开过就是 nil）。
    var window: NSWindow? { host.map { hostedView == nil ? nil : $0.hostWindow } ?? ownWindow }
    /// 上次停留的位置，存进偏好；窗口关闭后视图和里面没发送的草稿也留着。
    let nav: NotesNavigation
    /// 合并窗口与页面共用当前模式和日期。
    let workspace = NotesWorkspaceNavigation()
    var journalDate: Date { workspace.date }

    init(nav: NotesNavigation? = nil) {
        self.nav = nav ?? NotesNavigation(defaults: .standard)
        super.init()
    }
    /// 独立窗口关闭后，Timeline 别的窗口（主窗口、终端）如果还开着，焦点交给它；由 AppDelegate 设置。
    var handoffWindow: () -> NSWindow? = { nil }

    /// 笔记页正显示着（共用窗口时还要求窗口当前是笔记页）。
    var isVisible: Bool {
        guard let window, window.isVisible else { return false }
        return host?.showsNotes ?? true
    }
    var isKey: Bool { isVisible && window?.isKeyWindow == true }

    /// 打开笔记。指定 `taskID` 或 `tag` 就跳到那里；都不指定则保持上次关闭时的样子。已经开着就复用同一个页面。
    func show(store: JournalStore, taskID: UUID?, tag: String? = nil,
              reveal: @escaping (UUID) -> Void, openDay: @escaping (Date) -> Void) {
        if let taskID { nav.open(task: taskID) }
        if let tag { nav.open(tag: tag) }
        workspace.open(.notes)
        install(store: store, reveal: reveal, openDay: openDay)
        bringToFront()
    }

    /// 打开日记模式。日期列表和右侧日志视图共用同一个页面及状态。
    func showJournal(store: JournalStore, date: Date, log: UUID? = nil,
                     reveal: @escaping (UUID) -> Void = { _ in }, openDay: @escaping (Date) -> Void = { _ in }) {
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        workspace.open(.journal, date: date, log: log)
        install(store: store, reveal: reveal, openDay: openDay)
        bringToFront()
    }

    /// 不再给视图换新的 id：保持同一个视图，里面的草稿、编辑状态和滚动位置都留着。
    private func install(store: JournalStore, reveal: @escaping (UUID) -> Void, openDay: @escaping (Date) -> Void) {
        let view = UnifiedNotesView(store: store, workspace: workspace, nav: nav,
                                    close: { [weak self] in self?.close() },
                                    reveal: reveal, openDay: openDay)
        let root = AnyView(LocalizedRoot { view })
        if let host {
            if let hostedView { hostedView.rootView = root; return }
            let hosting = NSHostingView(rootView: root)
            hostedView = hosting
            host.installNotes(hosting)
        } else {
            let window = ownWindow ?? makeWindow()
            ownWindow = window
            (window.contentViewController as? NSHostingController<AnyView>)?.rootView = root
        }
    }

    /// 先把复用的窗口带到当前桌面，再激活应用，避免系统先切回窗口原来的桌面。
    func bringToFront() {
        if let host {
            guard hostedView != nil else { return }
            host.presentNotes()
            return
        }
        guard let window = ownWindow else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        WindowFade.reset(window)
        window.makeKeyAndOrderFront(nil)
        Headless.activateApp()
    }

    /// 在已经建好的笔记页里打开一个标签的笔记本，停在 `log` 那一条。
    func openTag(_ tag: String, log: UUID?) {
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        nav.open(tag: tag)
        workspace.open(.notes)
        if let log { nav.revealNote = log }
        bringToFront()
    }

    func hotKeyAction(_ appWasActive: Bool) -> NotesHotKeyAction {
        NotesHotKeyAction.resolve(appWasActive: appWasActive, visible: isVisible,
                                  onActiveSpace: window?.isOnActiveSpace == true,
                                  isKey: isKey, miniaturized: window?.isMiniaturized == true)
    }

    func setDate(_ date: Date) {
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        workspace.open(.journal, date: date)
    }
    /// 在同一个页面里切到日记的这一天，停在 `log` 那一条（从笔记的日期点过来）。
    func openJournal(date: Date, log: UUID?) {
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        workspace.open(.journal, date: date, log: log)
    }

    /// 在同一个页面里切到这个任务的笔记，滚到 `log` 那一条（从日记里点了日志关联的任务）。
    func openTaskNotes(_ id: UUID, log: UUID?) {
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        nav.open(task: id)
        workspace.open(.notes)
        if let log { nav.revealNote = log }
        bringToFront()
    }
    func shift(_ days: Int) { setDate(JournalDates.calendar.date(byAdding: .day, value: days, to: journalDate) ?? journalDate) }

    /// 关掉笔记：共用窗口时收起整个窗口（笔记页不在前面就什么都不做），独立窗口时关掉它。
    func close() {
        if let host {
            if isVisible { host.dismissNotes() }
        } else {
            ownWindow?.close()
        }
    }

    /// 菜单切换：当前桌面开着就关，其他桌面开着就带到当前桌面。
    func toggle(store: JournalStore, taskID: UUID?,
                reveal: @escaping (UUID) -> Void, openDay: @escaping (Date) -> Void) {
        if isVisible, window?.isOnActiveSpace == true { close() }
        else if isVisible { bringToFront() }
        else { show(store: store, taskID: taskID, reveal: reveal, openDay: openDay) }
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: AnyView(LocalizedRoot { EmptyView() }))
        let window = NotesWindow(contentViewController: host)
        window.title = AppLocalized("笔记 / 日记")
        // 没有红绿灯：用 Esc 或快捷键关闭。标题栏透明，整个窗口背景都可以拖动。
        window.styleMask = [.titled, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 420)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        if !window.setFrameUsingName(Self.frameName) {
            window.setContentSize(NSSize(width: 1000, height: 680))
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
        return window
    }

    /// 独立窗口关闭后：Timeline 还有别的窗口开着就交给它，否则回到刚才在用的应用（和主窗口、终端的收起一致）。
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, NSApplication.shared.isActive else { return }
            PreviousApp.restore(handoff: handoffWindow())
        }
    }
}

enum UnifiedNotesMode { case notes, journal }

@MainActor
final class NotesWorkspaceNavigation: ObservableObject {
    @Published var mode: UnifiedNotesMode = .notes
    @Published var date: Date
    @Published private(set) var requestID = 0
    /// 打开时要定位并高亮的那条日志（来自搜索结果）。
    @Published var revealLog: UUID?
    /// ⌘F：聚焦当前页面自己的搜索框。两页各自计数，隐藏的那页不响应。
    @Published private(set) var notesSearchRequest = 0
    @Published private(set) var journalSearchRequest = 0

    init(date: Date = Date()) {
        self.date = JournalDates.calendar.startOfDay(for: date)
    }

    func focusSearch() {
        if mode == .notes { notesSearchRequest += 1 } else { journalSearchRequest += 1 }
    }

    func open(_ mode: UnifiedNotesMode, date: Date? = nil, log: UUID? = nil) {
        self.mode = mode
        if let date { self.date = JournalDates.calendar.startOfDay(for: date) }
        revealLog = log
        requestID += 1
    }
}

/// 窗口与页面共用导航状态，复用 hosting view 时也立即响应外部日期跳转。
struct UnifiedNotesView: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var workspace: NotesWorkspaceNavigation
    let nav: NotesNavigation
    let close: () -> Void
    let reveal: (UUID) -> Void
    let openDay: (Date) -> Void
    @StateObject private var interaction = WorkspaceInteraction()
    @StateObject private var toast = ToastCenter()

    var body: some View {
        VStack(spacing: 0) {
            modeBar
            Divider()
            RetainedWorkspacePages(showsFirst: workspace.mode == .notes) {
                NotesView(store: store, nav: nav, close: close, reveal: reveal, openDay: openDay,
                          searchRequest: workspace.notesSearchRequest)
            } second: {
                journalBody
            }
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
            AppIssueBanner()
        }
        .background(AmbientBackdrop())
        .foregroundStyle(Palette.ink)
        .overlay(alignment: .bottom) { ToastView(center: toast).padding(.bottom, 18) }
        // 在笔记窗口里删除或修改：撤销提示出现在这里（主窗口只在自己是当前窗口时提示）。
        .onReceive(store.$lastAction.dropFirst()) { event in
            guard let event, NotesWindowController.shared.isKey, let message = ToastCenter.undoMessages[event.name] else { return }
            toast.show(message, actionTitle: "撤销") { store.undo() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .timelineEditorRecovered)) { note in
            guard note.object as? String == "inline" else { return }
            toast.show(AppLocalized("编辑器意外退出，已保存输入并重新载入"))
        }
        .environmentObject(interaction)
        .environmentObject(toast)
    }

    private var modeBar: some View {
        WorkspaceTopBar(closeAction: .notes, close: close) {
            PillSegmentedControl(selection: Binding(get: { workspace.mode }, set: { mode in
                NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
                NSApp.keyWindow?.makeFirstResponder(nil)
                workspace.mode = mode
            }), segments: [.init(value: UnifiedNotesMode.notes, title: "笔记", symbol: "note.text"),
                           .init(value: .journal, title: "日记", symbol: "book.pages")],
            height: 28, fontSize: 12)
            .fixedSize()
            .accessibilityLabel("笔记或日记")
        }
    }

    private var journalBody: some View {
        UnifiedJournalView(store: store, workspace: workspace)
    }

}

/// 笔记窗口里的日记模式：沿用笔记的侧栏、卡片和编辑器。
struct UnifiedJournalView: View {
    @Environment(\.locale) private var locale
    @Environment(\.typography) private var typography
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: JournalStore
    @ObservedObject var workspace: NotesWorkspaceNavigation

    private var date: Date {
        get { workspace.date }
        nonmutating set { workspace.date = newValue }
    }

    private var revealLog: UUID? {
        get { workspace.revealLog }
        nonmutating set { workspace.revealLog = newValue }
    }

    private var navigationRequest: Int { workspace.requestID }
    private var searchRequest: Int { workspace.journalSearchRequest }
    @StateObject private var mention = MentionState()
    @State private var focused = false
    @State private var error: String?
    /// 从节奏条跳过去的那一条短暂高亮，便于在长日志里找到。
    @State private var highlightedID: UUID?
    /// 滚动位置（页面不订阅，只有节奏条滑块和回到顶部按钮订阅）。
    @State private var tracker = ScrollTracker()
    /// 收起的专注轮次（只在窗口打开期间保留）。
    @State private var foldedRuns: Set<UUID> = []
    /// 刚提交的那条日志：滚过去并高亮。
    @State private var revealID: UUID?
    /// 已经按「打开这一天」定位过的日期：切到笔记再切回来时页面会重新出现，不能再把读到一半的位置拉走。
    @State private var openedDay: String?
    @State private var unlinked = false
    /// 日记侧栏和笔记侧栏共用同一套搜索入口；日期、星期和日志正文都可检索。
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var entry: DayEntry { store.entry(for: date) }
    private var allDates: [Date] {
        var result = store.days.keys.compactMap(JournalDates.date(for:))
            .filter { !store.entry(for: $0).logs.isEmpty }
        if !result.contains(where: { JournalDates.calendar.isDate($0, inSameDayAs: date) }) { result.append(date) }
        return result.sorted(by: >)
    }

    private var dates: [Date] {
        let sorted = allDates
        guard !query.isEmpty else { return sorted }
        return sorted.filter { item in
            let entry = store.entry(for: item)
            let dateText = item.formatted(.dateTime.year().month(.wide).day().locale(locale))
            let weekday = item.formatted(.dateTime.weekday(.wide).locale(locale))
            return dateText.localizedStandardContains(query)
                || weekday.localizedStandardContains(query)
                || entry.logs.contains { $0.searchableText.localizedStandardContains(query) || $0.tags.contains { $0.localizedStandardContains(query) } }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 250)
            Divider()
            detail.frame(maxWidth: .infinity)
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
        .onAppear { configureMention(); InlineMarkdownEditor.shared.preload() }
        .onChange(of: date) { _ in unlinked = false; configureMention() }
        .onChange(of: navigationRequest) { _ in query = "" }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "book.pages").foregroundStyle(Palette.accent)
                Text("日记").font(.system(size: 16, weight: .semibold))
                Spacer()
                let key = HotKeyStore.binding(for: .notes).label
                Text("\(key) 关闭").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField("搜索日期或日志", text: $query).textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onChange(of: searchRequest) { _ in searchFocused = true }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 7))

            if dates.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "book.pages").font(.system(size: 26, weight: .light)).foregroundStyle(Palette.muted.opacity(0.6))
                    Text(query.isEmpty ? "还没有日记" : "没有匹配的日期").font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            Text("日期（\(allDates.count) 天）").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                                .padding(.horizontal, 10).padding(.top, 6)
                            ForEach(dates, id: \.self) { item in dateRow(item).id(item) }
                        }
                    }
                    .onAppear { proxy.scrollTo(date, anchor: .center) }
                    .onChange(of: date) { proxy.scrollTo($0, anchor: .center) }
                    .onChange(of: navigationRequest) { _ in proxy.scrollTo(date, anchor: .center) }
                }
            }
        }
        .padding(16)
    }

    private func dateRow(_ item: Date) -> some View {
        let selected = JournalDates.calendar.isDate(item, inSameDayAs: date)
        let logs = store.entry(for: item).logs
        return Button { date = item } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "calendar").font(.system(size: 11)).foregroundStyle(selected ? Palette.accent : Palette.muted)
                    Text(item.formatted(.dateTime.year().month(.wide).day().locale(locale)))
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(JournalDates.calendar.isDateInToday(item) ? AppLocalized("今天") : item.formatted(.dateTime.weekday(.abbreviated).locale(locale)))
                    Text("\(logs.count) 条日志").monospacedDigit()
                    Spacer(minLength: 4)
                }
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Palette.soft : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalizedFormat("%@，%lld 条日志", item.formatted(.dateTime.year().month().day()), logs.count))
    }

    private var detail: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                header
                Divider()
                let all = entry.logsInTimeOrder
                let runs = FocusRun.runs(in: all)
                // 折叠的一轮专注只留结束那一条和它的小结，中间的开始、笔记、反馈都收起来。
                let hidden = Set(runs.filter { foldedRuns.contains($0.id) }.flatMap { [$0.start.id] + $0.inner.map(\.id) })
                let logs = all.filter { !hidden.contains($0.id) }
                ScrollView {
                    // 一天的日志不多时整列排好，滚动条按真实高度算（长日志也不会让它跳）。
                    NotesStack(lazy: DailyLogView.usesLazyLayout(entry.logs), spacing: 0) {
                        Color.clear.frame(height: 1).id("journal-top")
                        if entry.logsInTimeOrder.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "book.pages").font(.system(size: 30, weight: .light)).foregroundStyle(Palette.muted.opacity(0.6))
                                Text("这一天还没有日志").font(.system(size: 14, weight: .medium))
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 60)
                        } else {
                            let summaries = Dictionary(uniqueKeysWithValues: runs.map { ($0.end.id, $0) })
                            let segments = store.timelineSegments()
                            ForEach(Array(logs.enumerated()), id: \.element.id) { index, log in
                                VStack(alignment: .leading, spacing: 0) {
                                    if index > 0, let gap = NoteThread.gapLabel(from: logs[index - 1].createdAt, to: log.createdAt) {
                                        NoteThreadGap(label: gap)
                                    }
                                    journalRow(log, hasPrevious: index > 0, hasNext: index < logs.count - 1, segment: segments[log.id])
                                        .id(log.id)
                                        .recordsScrollPosition(log.id, in: tracker)
                                    if let run = summaries[log.id] {
                                        FocusRunSummary(run: run, folded: foldedRuns.contains(run.id), continues: index < logs.count - 1) {
                                            withAnimation(Motion.quick) {
                                                if foldedRuns.contains(run.id) { foldedRuns.remove(run.id) } else { foldedRuns.insert(run.id) }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("journal-bottom")
                    }
                    .padding(20)
                    .padding(.trailing, logs.isEmpty ? 0 : EntryRail.width)
                    .tracksScroll(tracker)
                }
                // 右边是这一天的节奏条（代替滚动条：按时刻排，点、拖都能跳到某一条）；右下角是「回到顶部」「跳到最新」。
                // 定位直接落到目标位置（和笔记页一致）：长日志的滚动动画一路排版，很卡。
                .entryRail(DayRhythm.marks(logs), spans: DayRhythm.spans(all, date: date), ticks: DayRhythm.ticks, tracker: tracker,
                           select: { proxy.scrollTo($0, anchor: .top) }, settle: { highlightedID = $0 }) { edge in
                    proxy.scrollTo(edge == .top ? "journal-top" : "journal-bottom", anchor: edge == .top ? .top : .bottom)
                }
                .id(JournalDates.key(date))
                .contentShape(Rectangle())
                // 今天从最新一条开始（接着写），往日从当天第一条开始读。
                .onAppear {
                    registerKeyboardPage()
                    if let id = revealLog { revealID = id; revealLog = nil }
                    else if openedDay != JournalDates.key(date) { openDay(proxy) }
                }
                .onChange(of: revealLog) { id in if let id { revealID = id; revealLog = nil } }
                .scrollsToKeyboardSelection(proxy)
                // 带着要定位的那一条换日期时，不再按「打开这一天」滚到开头 / 末尾，免得把定位冲掉。
                .onChange(of: date) { _ in
                    tracker.reset()
                    DispatchQueue.main.async {
                        if revealID == nil && highlightedID == nil { openDay(proxy) } else { openedDay = JournalDates.key(date) }
                    }
                }
                .onChange(of: revealID) { id in
                    guard let id else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(id, anchor: .center)
                        highlightedID = id
                        revealID = nil
                    }
                }
                .task(id: highlightedID) {
                    guard highlightedID != nil else { return }
                    try? await Task.sleep(for: .seconds(1.2))
                    withAnimation(.easeOut(duration: 0.4)) { highlightedID = nil }
                }
                Divider()
                composer
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(date.formatted(.dateTime.year().month(.wide).day().locale(locale)))
                        .font(.system(size: 18, weight: .semibold))
                    dayStep("chevron.left", "前一天 · ⌘⌥←", -1)
                    dayStep("chevron.right", "后一天 · ⌘⌥→", 1)
                    if !JournalDates.calendar.isDateInToday(date) {
                        Button { date = JournalDates.calendar.startOfDay(for: Date()) } label: {
                            Text("今天").font(.system(size: 11, weight: .medium)).padding(.horizontal, 7).frame(height: 20)
                                .background(Palette.soft, in: Capsule())
                        }
                        .buttonStyle(.plain).foregroundStyle(Palette.accent).raisedOnHover(radius: 10).help("回到今天")
                    }
                }
                HStack(spacing: 10) {
                    Text(date.formatted(.dateTime.weekday(.wide).locale(locale))).foregroundStyle(Palette.muted)
                    Text("\(entry.logs.count) 条日志").foregroundStyle(Palette.muted)
                }.font(.system(size: 12))
            }
            Spacer()
            if let error {
                Text(LocalizedStringKey(error)).font(.system(size: 11)).foregroundStyle(error.hasPrefix("已") ? Palette.success : Palette.deadline)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func journalRow(_ log: DailyLogEntry, hasPrevious: Bool, hasNext: Bool, segment: LogTimelineSegment?) -> some View {
        let taskLabel = log.showsTimelineContext || !hasPrevious ? LogTaskLabel.saved(log, store: store, logDate: date) : nil
        let showsMetadata = NoteThread.kindLabel(log) != nil || taskLabel != nil || (log.showsTimelineTags && !log.tags.isEmpty)
        return NoteThreadRow(log: log, hasPrevious: hasPrevious, hasNext: hasNext,
                             focusBefore: segment?.focusBefore == true, focusAfter: segment?.focusAfter == true,
                             highlighted: highlightedID == log.id, actionWidth: store.isReadOnly ? 0 : 72, showsMetadata: showsMetadata,
                             prepareEdit: !store.isReadOnly && log.hasEditableText ? { beginEdit(log, at: nil, prepare: true) } : nil) {
            if let kind = NoteThread.kindLabel(log) {
                Text(kind).foregroundStyle(LogEventStyle.color(log)).fontWeight(.medium)
            }
            if let label = taskLabel {
                // 点关联的任务：切到它的笔记，停在这一条。
                Button {
                    if let id = log.taskID, store.noteTopic(for: id) != nil { NotesWindowController.shared.openTaskNotes(id, log: log.id) }
                } label: { Text(label).lineLimit(1) }
                .buttonStyle(.plain).foregroundStyle(Palette.accent).help("查看这个待办的全部笔记")
            }
            if log.showsTimelineTags, !log.tags.isEmpty { TaskTagLine(tags: log.tags, log: log.id) }
        } content: {
            if !LogEventStyle.body(log).isEmpty {
                // 先选中，再点击正文就地编辑；点别处、Esc 或 ⌘↩ 保存。
                EditableLogText(log: log, editable: !store.isReadOnly && log.hasEditableText, begin: { beginEdit(log, at: $0, prepare: $1) }) { editAt in
                    TaskLinkText(source: LogEventStyle.body(log), completed: false, color: LogEventStyle.quiet(log) ? Palette.muted : Palette.ink,
                                 fontSize: LogEventStyle.quiet(log) ? 12 : 13,
                                 edit: { beginEdit(log, at: nil) }, open: SafariLinks.open, maxLines: 0,
                                 markdown: true, compactLines: true, editAt: editAt, foldID: "log.\(log.id.uuidString)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let detail = LogEventStyle.detail(log) {
                Text(detail).font(.system(size: typography.pt(11))).monospacedDigit()
                    .foregroundStyle(Palette.muted)
            }
            LogFocusGoal(log: log)
            if !log.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(log.images.enumerated()), id: \.offset) { index, _ in
                            NoteImageCard(store: store, log: log, index: index, maxWidth: 360, maxHeight: 190)
                        }
                    }
                }
            }
        } actions: {
            if !store.isReadOnly {
                HStack(spacing: 0) {
                    EntryMetadataButtons(store: store, log: log, date: date)
                    journalAction("trash", "删除这条日志 · ⌘Z 撤销", destructive: true) {
                        store.deleteLog(log.id, on: date); error = "已删除这条日志，⌘Z 可撤销"
                    }
                }.fixedSize()
            }
        }
    }

    private func openDay(_ proxy: ScrollViewProxy) {
        openedDay = JournalDates.key(date)
        guard let first = entry.logsInTimeOrder.first else { return }
        if JournalDates.calendar.isDateInToday(date) { proxy.scrollTo("journal-bottom", anchor: .bottom) }
        else { proxy.scrollTo(first.id, anchor: .top) }
    }

    private func dayStep(_ symbol: String, _ help: String, _ amount: Int) -> some View {
        Button {
            date = JournalDates.calendar.date(byAdding: .day, value: amount, to: date) ?? date
        } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Palette.muted).raisedOnHover(radius: 5)
        .help(LocalizedStringKey(help)).accessibilityLabel(LocalizedStringKey(help))
    }

    private func journalAction(_ symbol: String, _ help: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11)).frame(width: 24, height: 22).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(destructive ? Palette.danger : Palette.muted)
            .raisedOnHover(radius: 5).help(LocalizedStringKey(help)).accessibilityLabel(LocalizedStringKey(help))
    }

    private var composer: some View {
        JournalComposer(store: store, date: date, focused: $focused, unlinked: $unlinked, mention: mention, submit: submit)
            .id(JournalDates.key(date))
    }

    private func configureMention() {
        mention.triggers = [.task, .tag]
        mention.provider = MentionProviders.make(store: store, chosenTags: { store.entry(for: date).logDraftTags })
        mention.onPick = { item in
            switch item {
            case .task(let task): store.setLogTask(task.id, on: date); unlinked = false
            case .tag(let tag): store.addDraftTag(tag.name, on: date)
            }
        }
    }

    private func submit() {
        let draft = entry.logDraft
        guard !store.isReadOnly, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !entry.logDraftImages.isEmpty else { return }
        do {
            let command = try store.commitLog(on: date, linkDefault: !unlinked)
            if case .entry = command {
                error = nil; focused = true; unlinked = false; ImageIndexer.run(store: store)
                revealID = store.entry(for: date).logs.max(by: { $0.createdAt < $1.createdAt })?.id
            }
            else if case .help = command { store.setLogDraft("", on: date); error = "日志命令：/link、/done、/filter、/help" }
        } catch let issue { error = AppErrorDescription(issue) }
    }

    /// 键盘选中用的顺序：页面上从上到下（折叠的一轮专注里收起的那些不算）。
    private func registerKeyboardPage() {
        LogKeyboardSelection.shared.register(.journal, .init(order: {
            let all = entry.logsInTimeOrder
            let hidden = Set(FocusRun.runs(in: all).filter { foldedRuns.contains($0.id) }.flatMap { [$0.start.id] + $0.inner.map(\.id) })
            return all.filter { !hidden.contains($0.id) }.map(\.id)
        }, edit: { id in
            guard let log = entry.logs.first(where: { $0.id == id }), !store.isReadOnly else { return }
            beginEdit(log, at: nil)
        }, delete: { id in
            guard !store.isReadOnly else { return }
            if InlineMarkdownEditor.shared.isEditing(id) { InlineMarkdownEditor.shared.finish() }
            store.deleteLog(id, on: date); error = "已删除这条日志，⌘Z 可撤销"
        }))
    }

    private func beginEdit(_ log: DailyLogEntry, at point: CGPoint?, prepare: Bool = false) {
        guard log.hasEditableText else { return }
        InlineMarkdownEditor.shared.begin(log, on: date, store: store, at: point, fontSize: typography.pt(LogEventStyle.quiet(log) ? 12 : 13),
                                          lineSpacing: typography.lineSpacing, dark: colorScheme == .dark, muted: LogEventStyle.quiet(log), prepare: prepare)
    }

}
