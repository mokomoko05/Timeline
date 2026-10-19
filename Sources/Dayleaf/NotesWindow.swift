import AppKit
import SwiftUI
import DayleafCore

private final class NotesWindow: QuietWindow {
    /// 没有文字框处理 Esc 时关闭窗口，和原来 sheet 里的「关闭」一致。
    override func cancelOperation(_ sender: Any?) { close() }
}

/// 笔记窗口：可以自由调整大小的独立窗口。它和主窗口、终端、快速记录窗口互不依赖：
/// 各自用自己的快捷键开关，主窗口收起（⌃⌥D）时笔记照常留着；大小和位置会被记住。
@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    static let frameName = "DayleafNotesWindow"
    /// 应用里唯一的笔记窗口：界面和全局快捷键共用同一个。
    static let shared = NotesWindowController()
    private(set) var window: NSWindow?
    /// 上次停留的位置，存进偏好；窗口关闭后视图和里面没发送的草稿也留着。
    let nav: NotesNavigation
    /// 合并窗口与页面共用当前模式和日期。
    let workspace = NotesWorkspaceNavigation()
    var journalDate: Date { workspace.date }

    init(nav: NotesNavigation? = nil) {
        self.nav = nav ?? NotesNavigation(defaults: .standard)
        super.init()
    }
    /// 笔记关闭后，Scheduler 别的窗口（主窗口、终端）如果还开着，焦点交给它；由 AppDelegate 设置。
    var handoffWindow: () -> NSWindow? = { nil }

    var isVisible: Bool { window?.isVisible == true }

    /// 打开笔记窗口。指定 `taskID` 或 `tag` 就跳到那里；都不指定则保持上次关闭时的样子。已经开着就复用同一个窗口。
    func show(store: JournalStore, taskID: UUID?, tag: String? = nil,
              reveal: @escaping (UUID) -> Void, openDay: @escaping (Date) -> Void) {
        let window = self.window ?? makeWindow()
        self.window = window
        if let taskID { nav.open(task: taskID) }
        if let tag { nav.open(tag: tag) }
        workspace.open(.notes)
        let view = UnifiedNotesView(store: store, workspace: workspace, nav: nav,
                                    close: { [weak self] in self?.close() },
                                    reveal: reveal, openDay: openDay)
        // 不再给视图换新的 id：保持同一个视图，里面的草稿、编辑状态和滚动位置都留着。
        if let host = window.contentViewController as? NSHostingController<AnyView> {
            host.rootView = AnyView(LocalizedRoot { view })
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// 打开合并窗口的日记模式。日期列表和右侧日志视图共用同一个窗口及窗口状态。
    func showJournal(store: JournalStore, date: Date,
                     reveal: @escaping (UUID) -> Void = { _ in }, openDay: @escaping (Date) -> Void = { _ in }) {
        let window = self.window ?? makeWindow()
        self.window = window
        NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
        workspace.open(.journal, date: date)
        let view = UnifiedNotesView(store: store, workspace: workspace, nav: nav,
                                    close: { [weak self] in self?.close() },
                                    reveal: reveal, openDay: openDay)
        if let host = window.contentViewController as? NSHostingController<AnyView> {
            host.rootView = AnyView(LocalizedRoot { view })
        }
        window.makeKeyAndOrderFront(nil)
    }

    func setDate(_ date: Date) {
        NotificationCenter.default.post(name: .dayleafCommitEditing, object: nil)
        workspace.open(.journal, date: date)
    }
    func shift(_ days: Int) { setDate(JournalDates.calendar.date(byAdding: .day, value: days, to: journalDate) ?? journalDate) }
    var isKey: Bool { window?.isKeyWindow == true }

    func close() { window?.close() }

    /// 快捷键（默认 ⌃N）：开着就关，关着就开。
    func toggle(store: JournalStore, taskID: UUID?,
                reveal: @escaping (UUID) -> Void, openDay: @escaping (Date) -> Void) {
        if isVisible { close() } else { show(store: store, taskID: taskID, reveal: reveal, openDay: openDay) }
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: AnyView(LocalizedRoot { EmptyView() }))
        let window = NotesWindow(contentViewController: host)
        window.title = "笔记 / 日记"
        // 没有红绿灯：用 Esc 或快捷键关闭。标题栏透明，整个窗口背景都可以拖动。
        window.styleMask = [.titled, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 420)
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.delegate = self
        if !window.setFrameUsingName(Self.frameName) {
            window.setContentSize(NSSize(width: 1000, height: 680))
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
        return window
    }

    /// 关闭后：Scheduler 还有别的窗口开着就交给它，否则回到刚才在用的应用（和主窗口、终端的收起一致）。
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
    @Published var date = JournalDates.calendar.startOfDay(for: Date())
    @Published private(set) var requestID = 0

    func open(_ mode: UnifiedNotesMode, date: Date? = nil) {
        self.mode = mode
        if let date { self.date = JournalDates.calendar.startOfDay(for: date) }
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
            if workspace.mode == .notes {
                NotesView(store: store, nav: nav, close: close, reveal: reveal, openDay: openDay)
            } else {
                journalBody
            }
        }
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
        .environmentObject(interaction)
        .environmentObject(toast)
    }

    private var modeBar: some View {
        HStack(spacing: 8) {
            Image(systemName: workspace.mode == .notes ? "note.text" : "book.pages").foregroundStyle(Palette.accent)
            Picker("", selection: Binding(get: { workspace.mode == .notes ? 0 : 1 }, set: { workspace.mode = $0 == 0 ? .notes : .journal })) {
                Text("笔记").tag(0)
                Text("日记").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 126)
            Spacer()
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(HitAreaButtonStyle(compact: true)).foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 16).padding(.top, 5).padding(.bottom, 6)
    }

    private var journalBody: some View {
        UnifiedJournalView(store: store, date: $workspace.date, navigationRequest: workspace.requestID)
    }

}

/// 笔记窗口里的日记模式：沿用笔记的侧栏、卡片和编辑器，不再嵌入带复盘区的 DayLogView。
private struct UnifiedJournalView: View {
    @Environment(\.locale) private var locale
    @Environment(\.typography) private var typography
    @ObservedObject var store: JournalStore
    @Binding var date: Date
    let navigationRequest: Int
    @StateObject private var mention = MentionState()
    @State private var focused = false
    @State private var error: String?
    @State private var editingID: UUID?
    @State private var editingDate: Date?
    @State private var editText = ""
    @State private var editFocused = false
    /// 日记侧栏和笔记侧栏共用同一套搜索入口；日期、星期和日志正文都可检索。
    @State private var query = ""

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
        .onAppear { configureMention() }
        .onChange(of: date) { _ in saveEdit(); configureMention() }
        .onChange(of: navigationRequest) { _ in query = "" }
        .onReceive(NotificationCenter.default.publisher(for: .dayleafCommitEditing)) { _ in saveEdit() }
        .onDisappear { saveEdit() }
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
        .accessibilityLabel("\(item.formatted(.dateTime.year().month().day()))，\(logs.count) 条日志")
    }

    private var detail: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if entry.logsInTimeOrder.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "book.pages").font(.system(size: 30, weight: .light)).foregroundStyle(Palette.muted.opacity(0.6))
                            Text("这一天还没有日志").font(.system(size: 14, weight: .medium))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 60)
                    } else {
                        let logs = entry.logsInTimeOrder
                        ForEach(Array(logs.enumerated()), id: \.element.id) { index, log in
                            journalRow(log, hasPrevious: index > 0, hasNext: index < logs.count - 1)
                        }
                    }
                }
                .padding(20)
            }
            .id(JournalDates.key(date))
            .contentShape(Rectangle())
            .onTapGesture { if editingID != nil { NSApp.keyWindow?.makeFirstResponder(nil) } }
            Divider()
            composer
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(date.formatted(.dateTime.year().month(.wide).day().locale(locale)))
                    .font(.system(size: 18, weight: .semibold))
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

    private func journalRow(_ log: DailyLogEntry, hasPrevious: Bool, hasNext: Bool) -> some View {
        let editing = editingID == log.id
        return LogTimelineRow(log: log, hasPrevious: hasPrevious, hasNext: hasNext) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    LogEventBadge(log: log)
                    if log.showsTimelineContext || !hasPrevious, let label = LogTaskLabel.saved(log, store: store, logDate: date) {
                        Text(label).font(.system(size: typography.pt(11))).foregroundStyle(Palette.accent)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                    if !store.isReadOnly {
                        HStack(spacing: 0) {
                            journalAction("pencil", "编辑这条日志") { beginEdit(log) }
                            journalAction("trash", "删除这条日志 · ⌘Z 撤销", destructive: true) {
                                store.deleteLog(log.id, on: date); error = "已删除这条日志，⌘Z 可撤销"
                            }
                        }.fixedSize()
                    }
                }
                if editing {
                    TaskInput(text: $editText, focused: $editFocused, fontSize: 13,
                              submit: { saveEdit() }, cancel: { editingID = nil }, minHeight: 24, maxLines: 12)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.accent.opacity(0.6)))
                } else if !LogEventStyle.body(log).isEmpty {
                    TaskLinkText(source: LogEventStyle.body(log), completed: false, color: Palette.ink, fontSize: 13,
                                 edit: { beginEdit(log) }, open: SafariLinks.open, maxLines: 0,
                                 markdown: true, compactLines: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let detail = LogEventStyle.detail(log) {
                    Text(detail).font(.system(size: typography.pt(11), design: .monospaced))
                        .foregroundStyle(Palette.muted)
                }
                LogFocusGoal(log: log)
                if !log.images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(log.images.enumerated()), id: \.element) { index, name in
                                Button { ImageViewerController.shared.show(store: store, around: log, index: index) } label: {
                                    ImageFit(url: store.imageURL(name), maxWidth: 360, maxHeight: 190)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                if log.showsTimelineTags, !log.tags.isEmpty { TaskTagLine(tags: log.tags) }
            }
        }
    }

    private func journalAction(_ symbol: String, _ help: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11)).frame(width: 24, height: 22).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(destructive ? Palette.deadline : Palette.muted)
            .raisedOnHover(radius: 5).help(LocalizedStringKey(help)).accessibilityLabel(LocalizedStringKey(help))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !entry.logDraftImages.isEmpty {
                PendingImagesStrip(store: store, names: entry.logDraftImages,
                                   remove: { store.removeDraftImage($0, on: date) },
                                   preview: { ImageViewerController.shared.show(store: store, names: entry.logDraftImages, index: $0) })
            }
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").foregroundStyle(Palette.accent)
                TaskInput(text: Binding(get: { store.entry(for: date).logDraft }, set: { store.setLogDraft($0, on: date) }),
                          focused: $focused, placeholder: "写下日志…", fontSize: 13,
                          submit: submit, onPasteImages: { datas in
                    for name in ImageTools.save(datas, in: store) { store.addDraftImage(name, on: date) }
                    focused = true
                }, minHeight: 24, maxLines: 10, mention: mention)
                .disabled(store.isReadOnly)
                Button(action: submit) { Image(systemName: "arrow.turn.down.left") }
                    .buttonStyle(HitAreaButtonStyle())
                    .disabled(store.isReadOnly || (entry.logDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && entry.logDraftImages.isEmpty))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .popover(isPresented: Binding(get: { mention.isActive }, set: { if !$0 { mention.dismiss() } }), arrowEdge: .bottom) {
            MentionList(state: mention, store: store).frame(width: 340)
        }
    }

    private func configureMention() {
        mention.triggers = [.task, .tag]
        mention.provider = MentionProviders.make(store: store, chosenTags: { store.entry(for: date).logDraftTags })
        mention.onPick = { item in
            switch item {
            case .task(let task): store.setLogTask(task.id, on: date)
            case .tag(let tag): store.addDraftTag(tag.name, on: date)
            }
        }
    }

    private func submit() {
        let draft = entry.logDraft
        guard !store.isReadOnly, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !entry.logDraftImages.isEmpty else { return }
        do {
            let command = try store.commitLog(on: date)
            if case .entry = command { error = nil; focused = true; ImageIndexer.run(store: store) }
            else if case .help = command { store.setLogDraft("", on: date); error = "日志命令：/link、/done、/filter、/help" }
        } catch let issue { error = AppErrorDescription(issue) }
    }

    private func beginEdit(_ log: DailyLogEntry) { saveEdit(); editingID = log.id; editingDate = date; editText = log.text; editFocused = true }
    private func saveEdit() {
        guard let id = editingID else { return }
        editingID = nil; editFocused = false
        store.updateLog(id, text: editText, on: editingDate ?? date)
        editingDate = nil
    }

}
