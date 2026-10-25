import AppKit
import SwiftUI
import TimelineCore

@MainActor
final class BoardNavigation: ObservableObject {
    private let defaults: UserDefaults
    private var editorSessions: [UUID: BoardLiveEditorSession] = [:]
    private var editorOrder: [UUID] = []
    /// 最近用过的几个工作板保留编辑器（光标、撤销历史、滚动位置）。每个编辑器有一份 WebKit 内容进程，
    /// 长时间后台运行时限制数量；更早的切回来时重新加载正文。
    static let liveEditorLimit = 4

    func editorSession(for board: Board, store: JournalStore) -> BoardLiveEditorSession {
        if editorSessions[board.id] == nil { editorSessions[board.id] = BoardLiveEditorSession(store: store, board: board) }
        editorOrder.removeAll { $0 == board.id }
        editorOrder.append(board.id)
        while editorOrder.count > Self.liveEditorLimit {
            let oldest = editorOrder.removeFirst()
            editorSessions.removeValue(forKey: oldest)?.flush()
        }
        return editorSessions[board.id]!
    }

    /// 当前工作板是在看源码还是预览；换工作板回到预览。
    @Published var sourceMode = false

    func select(_ id: UUID) {
        guard selection != id else { return }
        if sourceMode { sourceMode = false }
        // The editor already debounces and flushes every change. Switching boards should
        // update the lightweight SwiftUI selection immediately instead of waiting for an
        // asynchronous WebKit round trip; the cached session keeps its caret and scroll.
        if let selection, let editor = editorSessions[selection] { editor.flush() }
        self.selection = id
    }
    @Published var selection: UUID? {
        didSet { defaults.set(selection?.uuidString, forKey: "board.selection") }
    }
    @Published private(set) var favoriteBoardIDs: [UUID] {
        didSet { defaults.set(favoriteBoardIDs.map(\.uuidString), forKey: "board.favorites") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: "board.selection").flatMap(UUID.init(uuidString:))
        var seen = Set<UUID>()
        favoriteBoardIDs = (defaults.stringArray(forKey: "board.favorites") ?? [])
            .compactMap(UUID.init(uuidString:)).filter { seen.insert($0).inserted }
    }

    func isFavorite(_ id: UUID) -> Bool { favoriteBoardIDs.contains(id) }

    func toggleFavorite(_ id: UUID) {
        if isFavorite(id) { favoriteBoardIDs.removeAll { $0 == id } }
        else { favoriteBoardIDs.append(id) }
    }

    func favoriteBoards(in store: JournalStore) -> [Board] {
        favoriteBoardIDs.compactMap { id in store.boards.first { $0.id == id } }
    }

    func moveFavorite(_ id: UUID, to destination: Int) {
        guard let source = favoriteBoardIDs.firstIndex(of: id) else { return }
        var reordered = favoriteBoardIDs
        reordered.remove(at: source)
        reordered.insert(id, at: max(0, min(destination, reordered.count)))
        favoriteBoardIDs = reordered
    }
}

private final class BoardPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {}
}

@MainActor
final class BoardWindowController: NSObject, NSWindowDelegate {
    static let shared = BoardWindowController()
    private(set) var panel: NSPanel?
    let navigation: BoardNavigation
    private var store: JournalStore?

    init(defaults: UserDefaults = .standard) {
        navigation = BoardNavigation(defaults: defaults)
        super.init()
    }

    func show(store: JournalStore, owner: BoardOwner? = nil) {
        let replacingContent = panel == nil || self.store !== store
        if replacingContent {
            panel?.makeFirstResponder(nil)
            self.store?.save()
        }
        self.store = store
        if let owner, let board = store.ensureBoard(for: owner) { navigation.select(board.id) }
        if panel == nil {
            let panel = BoardPanel(contentRect: NSRect(x: 0, y: 0, width: 410, height: 560),
                                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
            panel.title = AppLocalized("工作板")
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.minSize = NSSize(width: 350, height: 300)
            panel.delegate = self
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                panel.standardWindowButton(button)?.isHidden = true
            }
            if !panel.setFrameUsingName("TimelineBoardWindow") { panel.center() }
            panel.setFrameAutosaveName("TimelineBoardWindow")
            self.panel = panel
        }
        guard let panel else { return }
        if replacingContent {
            let content = BoardWorkspaceView(store: store, navigation: navigation,
                                             close: { [weak self] in self?.hide() })
            panel.contentView = NSHostingView(rootView: LocalizedRoot { content })
        }
        panel.level = .floating
        if Headless.active { panel.alphaValue = 0; panel.ignoresMouseEvents = true }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) { panel.center() }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func toggle(store: JournalStore) {
        if panel?.isVisible == true { hide() } else { show(store: store) }
    }

    func hide() {
        panel?.makeFirstResponder(nil)
        if let editor = BoardLiveEditorSession.active, editor.webView?.window === panel {
            editor.commit { [weak self] in self?.store?.save() }
        } else { store?.save() }
        panel?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
}

struct BoardOpenButton: View {
    @ObservedObject var store: JournalStore
    let owner: BoardOwner

    var body: some View {
        Button { BoardWindowController.shared.show(store: store, owner: owner) } label: {
            Label("工作板", systemImage: "list.bullet.rectangle")
        }
        .help("打开工作板").accessibilityLabel("打开工作板")
    }
}

struct BoardWorkspaceView: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var navigation: BoardNavigation
    var close: () -> Void = {}
    @State private var choosing = false

    private var board: Board? { store.boards.first { $0.id == navigation.selection } }

    var body: some View {
        VStack(spacing: 0) {
            if let board {
                // 标题栏和常用一栏在切换时保留（常用一栏的横向滚动位置不丢），只有编辑区按工作板重建。
                BoardContentView(store: store, navigation: navigation, board: board,
                                 choose: { choosing.toggle() }, close: close,
                                 favorites: navigation.favoriteBoards(in: store).isEmpty ? nil : AnyView(favoritesBar))
            } else {
                HStack {
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }
                        .buttonStyle(HitAreaButtonStyle(compact: true)).foregroundStyle(Palette.muted)
                        .help("关闭工作板").accessibilityLabel("关闭工作板")
                }
                .padding(.horizontal, 10).padding(.top, 8)
                VStack(spacing: 14) {
                    Image(systemName: "list.bullet.rectangle").font(.system(size: 34)).foregroundStyle(Palette.accent)
                    Text("把内容和资料放在眼前").font(.headline)
                    Text("选择一个待办或标签，整理议程、阅读目标与参考链接。")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                    Button("选择待办或标签") { choosing = true }.buttonStyle(.borderedProminent)
                        .keyboardShortcut("k", modifiers: .command)
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = store.errorMessage {
                HStack {
                    Text(error).font(.caption).foregroundStyle(Palette.deadline).textSelection(.enabled)
                    Button("重试保存") { store.save() }
                }.padding(10)
            }
        }
        .overlay {
            if choosing {
                ZStack(alignment: .top) {
                    // 点空白处关闭；底下一层很淡的遮罩，让切换器从内容里浮出来。
                    Color.black.opacity(0.12).contentShape(Rectangle()).onTapGesture { choosing = false }
                    BoardSwitcher(store: store, navigation: navigation, close: { choosing = false })
                        .padding(.horizontal, 10).padding(.top, 44)
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.reduced ? nil : .easeOut(duration: 0.12), value: choosing)
        .background(Palette.background).foregroundStyle(Palette.ink).tint(Palette.accent)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { if !Headless.active { BoardLiveEditorSession.prepareSpare() } }
    }

    private var favoritesBar: some View {
        BoardFavoritesBar(boards: navigation.favoriteBoards(in: store).map {
            BoardFavorite(id: $0.id, title: store.boardTitle($0))
        }, selection: navigation.selection, select: { id in
            guard navigation.selection != id else { return }
            NSApp.keyWindow?.makeFirstResponder(nil)
            navigation.select(id)
        }, move: { id, destination in
            let visible = navigation.favoriteBoards(in: store)
            guard visible.indices.contains(destination),
                  let index = navigation.favoriteBoardIDs.firstIndex(of: visible[destination].id) else { return }
            navigation.moveFavorite(id, to: index)
        }, remove: { navigation.toggleFavorite($0) })
        .frame(height: 34)
        .accessibilityLabel("常用工作板")
    }
}

struct BoardContentView: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var navigation: BoardNavigation
    let board: Board
    var choose: () -> Void = {}
    var close: () -> Void = {}
    /// 常用工作板一栏，排在标题下面。
    var favorites: AnyView?

    init(store: JournalStore, navigation: BoardNavigation, board: Board,
         choose: @escaping () -> Void = {}, close: @escaping () -> Void = {}, favorites: AnyView? = nil) {
        self.store = store
        self.navigation = navigation
        self.board = board
        self.choose = choose
        self.close = close
        self.favorites = favorites
    }

    private var editing: Bool { navigation.sourceMode }

    private var markdown: Binding<String> {
        Binding(get: { store.boards.first { $0.id == board.id }?.markdown ?? board.markdown },
                set: { store.setBoardMarkdown($0, for: board.id) })
    }

    private func setEditing(_ value: Bool) {
        navigation.sourceMode = value
        navigation.editorSession(for: board, store: store).setSourceMode(value)
    }

    private func insertTemplate(_ template: BoardMarkdownTemplate) {
        setEditing(true)
        let liveEditor = navigation.editorSession(for: board, store: store)
        if liveEditor.error == nil { liveEditor.insertTemplate(template); return }
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
           editor.isEditable {
            if editor.hasMarkedText() { editor.unmarkText() }
            guard template.insert(into: editor) else { return }
            (editor as? BoardMarkdownTextView)?.onFlush?()
            return
        }
        let insertion = template.insertion(into: markdown.wrappedValue)
        markdown.wrappedValue = insertion.source
        setEditing(true)
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                  editor.isEditable, editor.string == insertion.source else { return }
            editor.setSelectedRange(insertion.selectedRange)
            editor.scrollRangeToVisible(insertion.selectedRange)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let favorites { favorites.padding(.horizontal, 4) }
            Divider()
            BoardEditorArea(store: store, navigation: navigation, board: board, markdown: markdown,
                            preview: { setEditing(false) })
                .id(board.id)
            relatedBoards
        }
    }

    /// 一行标题栏：左边是当前工作板（点它切换），右边是一组同样大小的图标按钮。
    private var header: some View {
        HStack(spacing: 2) {
            Button(action: choose) {
                HStack(spacing: 7) {
                    Image(systemName: ownerSymbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.boardTitle(board)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                            .lineLimit(1).truncationMode(.tail)
                        Text(subtitle).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(HitAreaButtonStyle(compact: true, pressedScale: 0.98))
            .keyboardShortcut("k", modifiers: .command)
            .help("切换工作板 · ⌘K")
            .accessibilityLabel(AppLocalizedFormat("切换工作板，当前 %@", store.boardTitle(board)))
            .layoutPriority(1)
            Spacer(minLength: 6)
            Group {
                if !store.isReadOnly {
                    Menu {
                        templateItem("折叠内容", systemImage: "chevron.down.square", template: .disclosure)
                        templateItem("论文阅读", systemImage: "book.closed", template: .paper)
                        templateItem("会议议程", systemImage: "list.bullet", template: .meeting)
                    } label: {
                        Image(systemName: "plus").frame(width: 26, height: 24).contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .tint(Palette.muted).foregroundStyle(Palette.muted)
                    .help("插入模板").accessibilityLabel("插入模板")
                    headerButton(editing ? "eye" : "chevron.left.forwardslash.chevron.right",
                                 editing ? "预览" : "编辑 Markdown 源码", active: editing) { setEditing(!editing) }
                }
                if case .task(let id) = board.owner, store.locate(id) != nil {
                    headerButton("note.text", "笔记") { AppRouter.openNotes(id) }
                }
                headerButton(navigation.isFavorite(board.id) ? "star.fill" : "star",
                             navigation.isFavorite(board.id) ? "取消常用固定" : "固定到常用",
                             active: navigation.isFavorite(board.id)) { navigation.toggleFavorite(board.id) }
                Divider().frame(height: 14).padding(.horizontal, 3)
                headerButton("xmark", "关闭工作板", action: close)
            }
            .font(.system(size: 12))
        }
        .padding(.leading, 6).padding(.trailing, 8).padding(.top, 6).padding(.bottom, 4)
    }

    private var ownerSymbol: String {
        if store.isBoardArchived(board) { return "archivebox" }
        if case .tag = board.owner { return "number" }
        return "list.bullet.rectangle"
    }

    private var subtitle: String {
        if store.isReadOnly { return AppLocalized("只读") }
        if store.isBoardArchived(board) { return AppLocalized("已归档 · 内容保留") }
        switch board.owner {
        case .task(let id):
            guard let task = store.locate(id) else { return AppLocalized("待办") }
            if task.task.completed { return AppLocalized("任务已结束") }
            if let due = task.task.dueDate { return AppLocalizedFormat("待办 · 截止 %@", due.relativeLabel) }
            return AppLocalized("待办")
        case .tag(let tag):
            return AppLocalizedFormat("标签 · %lld 个待办", store.tasks(taggedWith: tag).count)
        }
    }

    private func headerButton(_ symbol: String, _ title: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 26, height: 24).contentShape(Rectangle()) }
            .buttonStyle(HitAreaButtonStyle(compact: true))
            .foregroundStyle(active ? Palette.accent : Palette.muted)
            .help(LocalizedStringKey(title)).accessibilityLabel(LocalizedStringKey(title))
    }

    private func templateItem(_ title: LocalizedStringKey, systemImage: String, template: BoardMarkdownTemplate) -> some View {
        Button { insertTemplate(template) } label: { Label(title, systemImage: systemImage) }
    }

    /// 标签工作板底部：这个标签下各待办的工作板，排成一行可以横向滚动的小标签。
    @ViewBuilder private var relatedBoards: some View {
        if case .tag(let tag) = board.owner, !board.archived {
            let taskIDs = Set(store.tasks(taggedWith: tag).map(\.id))
            let related = store.boards.filter { candidate in
                guard !candidate.archived, case .task(let id) = candidate.owner else { return false }
                return taskIDs.contains(id)
            }
            if !related.isEmpty {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("标签下的工作板").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
                        ForEach(related) { candidate in
                            Button {
                                NSApp.keyWindow?.makeFirstResponder(nil)
                                navigation.select(candidate.id)
                            } label: {
                                Label(store.boardTitle(candidate), systemImage: "list.bullet.rectangle")
                                    .font(.system(size: 11)).lineLimit(1)
                                    .padding(.horizontal, 8).frame(height: 22)
                                    .background(Palette.soft.opacity(0.6), in: Capsule())
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain).foregroundStyle(Palette.ink)
                            .help("打开这个待办的工作板")
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
        }
    }
}

/// 一个工作板的编辑区：每个工作板一份，持有它的编辑器会话。
private struct BoardEditorArea: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var navigation: BoardNavigation
    let board: Board
    let markdown: Binding<String>
    let preview: () -> Void
    @StateObject private var liveEditor: BoardLiveEditorSession

    init(store: JournalStore, navigation: BoardNavigation, board: Board, markdown: Binding<String>, preview: @escaping () -> Void) {
        self.store = store
        self.navigation = navigation
        self.board = board
        self.markdown = markdown
        self.preview = preview
        _liveEditor = StateObject(wrappedValue: navigation.editorSession(for: board, store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            if liveEditor.error != nil {
                if navigation.sourceMode {
                    BoardMarkdownEditor(text: markdown, preview: preview).padding(10)
                } else {
                    ScrollView { BoardMarkdownPreview(store: store, board: board).padding(12) }
                }
            } else {
                BoardLiveEditor(session: liveEditor, sourceMode: navigation.sourceMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDisappear { liveEditor.flush() }
    }
}

struct BoardMarkdownPreview: View {
    @ObservedObject var store: JournalStore
    let board: Board
    var edit: () -> Void = {}
    @StateObject private var cache = MarkdownDisclosureCache()

    init(store: JournalStore, board: Board, edit: @escaping () -> Void = {}, cache: MarkdownDisclosureCache? = nil) {
        self.store = store
        self.board = board
        self.edit = edit
        _cache = StateObject(wrappedValue: cache ?? MarkdownDisclosureCache())
    }

    var body: some View {
        BoardMarkdownBlocks(store: store, boardID: board.id, nodes: cache.parse(board.markdown),
                            cache: cache, edit: edit)
    }
}

private struct BoardMarkdownBlocks: View {
    @ObservedObject var store: JournalStore
    let boardID: UUID
    let nodes: [MarkdownDisclosureNode]
    @ObservedObject var cache: MarkdownDisclosureCache
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(nodes) { node in
                switch node {
                case .markdown(let fragment):
                    TaskLinkText(source: fragment.source, completed: false, color: Palette.ink,
                                 fontSize: 13, edit: edit, open: SafariLinks.open,
                                 maxLines: 0, markdown: true,
                                 toggleMarkdownTask: store.isReadOnly ? nil : { line in
                                     store.toggleBoardMarkdownTask(atLine: line + fragment.lineOffset, in: boardID)
                                 }, compactLines: true)
                case .code(let code):
                    BoardCodeBlock(code: code)
                case .disclosure(let disclosure):
                    let open = cache.isExpanded(disclosure)
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { cache.toggle(disclosure) }
                        } label: {
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 12, height: 20)
                                Text(disclosure.title).font(.system(size: 13, weight: .medium))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 2).padding(.vertical, 2).frame(minHeight: 24)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(Palette.ink).help(disclosure.title)
                        .accessibilityLabel(disclosure.title)
                        .accessibilityValue(open ? AppLocalized("已展开") : AppLocalized("已收起"))
                        if cache.hasRendered(disclosure) {
                            BoardMarkdownBlocks(store: store, boardID: boardID, nodes: disclosure.children,
                                                cache: cache, edit: edit)
                                .padding(.leading, 16)
                                .overlay(alignment: .leading) { Rectangle().fill(Palette.line).frame(width: 1) }
                                .frame(height: open ? nil : 0, alignment: .top)
                                .clipped().opacity(open ? 1 : 0).allowsHitTesting(open).accessibilityHidden(!open)
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BoardNotesSection: View {
    @ObservedObject var store: JournalStore
    let owner: BoardOwner
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let board = store.board(for: owner), board.hasContent {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("看板内容", systemImage: "list.bullet.rectangle")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                    Spacer()
                    Button {
                        BoardWindowController.shared.show(store: store, owner: owner)
                    } label: { Label("打开工作板", systemImage: "arrow.up.forward.square") }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.accent)
                }
                BoardMarkdownPreview(store: store, board: board).id(board.id)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 9).fill(Palette.background)
                    .overlay { RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(colorScheme == .dark ? 0.28 : 0.07)) }
            }
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.line.opacity(0.7)) }
            .accessibilityElement(children: .contain).accessibilityLabel("看板内容")
        }
    }
}
