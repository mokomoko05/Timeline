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

    func select(_ id: UUID) {
        guard selection != id else { return }
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
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(Palette.accent)
                Text("工作板").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { choosing.toggle() } label: { Label("切换", systemImage: "arrow.left.arrow.right") }
                    .popover(isPresented: $choosing) {
                        BoardChooser(store: store, navigation: navigation, close: { choosing = false })
                    }
                Button(action: close) { Image(systemName: "xmark") }.accessibilityLabel("关闭工作板")
            }
            .buttonStyle(HitAreaButtonStyle(compact: true))
            .font(.system(size: 12)).foregroundStyle(Palette.muted)
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            if !navigation.favoriteBoards(in: store).isEmpty {
                favoritesBar
                Divider()
            }
            if let board {
                BoardContentView(store: store, navigation: navigation, board: board).id(board.id)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "list.bullet.rectangle").font(.system(size: 34)).foregroundStyle(Palette.accent)
                    Text("把内容和资料放在眼前").font(.headline)
                    Text("选择一个待办或标签，整理议程、阅读目标与参考链接。")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                    Button("选择待办或标签") { choosing = true }.buttonStyle(.borderedProminent)
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = store.errorMessage {
                HStack {
                    Text(error).font(.caption).foregroundStyle(Palette.deadline).textSelection(.enabled)
                    Button("重试保存") { store.save() }
                }.padding(10)
            }
        }
        .background(Palette.background).foregroundStyle(Palette.ink).tint(Palette.accent)
        .ignoresSafeArea(.container, edges: .top)
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
        .frame(height: 38)
        .accessibilityLabel("常用工作板")
    }
}

private struct BoardChooser: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var navigation: BoardNavigation
    let close: () -> Void
    @State private var query = ""

    private func matches(_ title: String) -> Bool { query.isEmpty || title.localizedStandardContains(query) }
    private func select(_ owner: BoardOwner) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        store.save()
        guard let board = store.ensureBoard(for: owner) else { return }
        navigation.select(board.id)
        close()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("搜索待办、标签和工作板", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    let favorites = navigation.favoriteBoards(in: store).filter { matches(store.boardTitle($0)) }
                    if !favorites.isEmpty {
                        Text("常用工作板").font(.caption).foregroundStyle(Palette.muted)
                        ForEach(favorites) { board in boardRow(board) }
                        Divider()
                    }
                    let remaining = store.boards.filter { !navigation.isFavorite($0.id) && matches(store.boardTitle($0)) }
                    if !remaining.isEmpty {
                        Text("已有工作板").font(.caption).foregroundStyle(Palette.muted)
                        ForEach(remaining.sorted { $0.updatedAt > $1.updatedAt }) { board in boardRow(board) }
                        Divider()
                    }
                    Text("待办").font(.caption).foregroundStyle(Palette.muted)
                    ForEach(store.sortedTasks().filter { !$0.task.completed && matches($0.task.title) }) { task in
                        Button { select(.task(task.id)) } label: {
                            Label(String(TaskText.rendered(task.task.title).characters), systemImage: "circle").lineLimit(2)
                                .padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.disabled(store.isReadOnly && store.board(for: .task(task.id)) == nil)
                    }
                    Divider()
                    Text("标签").font(.caption).foregroundStyle(Palette.muted)
                    ForEach(store.allTags().filter { matches($0.name) }) { tag in
                        Button { select(.tag(tag.name)) } label: {
                            Label(tag.name, systemImage: "tag").padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.disabled(store.isReadOnly && store.board(for: .tag(tag.name)) == nil)
                    }
                }.buttonStyle(.plain)
            }.frame(height: 340)
        }.padding(14).frame(width: 310).foregroundStyle(Palette.ink).background(Palette.background)
    }

    private func boardRow(_ board: Board) -> some View {
        HStack(spacing: 8) {
            Button {
                NSApp.keyWindow?.makeFirstResponder(nil)
                store.save()
                navigation.select(board.id)
                close()
            } label: {
                HStack {
                    Image(systemName: store.isBoardArchived(board) ? "archivebox" : "list.bullet.rectangle")
                    Text(store.boardTitle(board)).lineLimit(2)
                    Spacer()
                    if navigation.selection == board.id { Image(systemName: "checkmark") }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            Button { navigation.toggleFavorite(board.id) } label: {
                Image(systemName: navigation.isFavorite(board.id) ? "star.fill" : "star")
                    .foregroundStyle(navigation.isFavorite(board.id) ? Palette.accent : Palette.muted)
                    .frame(width: 24, height: 24)
            }
            .help(navigation.isFavorite(board.id) ? "取消常用固定" : "固定到常用")
            .accessibilityLabel(navigation.isFavorite(board.id) ? "取消常用固定" : "固定到常用")
        }.padding(.vertical, 4)
    }
}

struct BoardContentView: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var navigation: BoardNavigation
    let board: Board
    @State private var editing: Bool
    @StateObject private var liveEditor: BoardLiveEditorSession

    init(store: JournalStore, navigation: BoardNavigation, board: Board) {
        self.store = store
        self.navigation = navigation
        self.board = board
        _editing = State(initialValue: false)
        _liveEditor = StateObject(wrappedValue: navigation.editorSession(for: board, store: store))
    }

    private var markdown: Binding<String> {
        Binding(get: { store.boards.first { $0.id == board.id }?.markdown ?? board.markdown },
                set: { store.setBoardMarkdown($0, for: board.id) })
    }

    private func setEditing(_ value: Bool) {
        editing = value
        liveEditor.setSourceMode(value)
    }

    private func insertTemplate(_ template: BoardMarkdownTemplate) {
        setEditing(true)
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(store.boardTitle(board)).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if case .task(let id) = board.owner, store.locate(id) != nil {
                        Button { AppRouter.openNotes(id) } label: { Image(systemName: "note.text") }
                            .help("笔记").accessibilityLabel("笔记")
                    }
                    Button { setEditing(!editing) } label: {
                        Image(systemName: editing ? "eye" : "chevron.left.forwardslash.chevron.right")
                    }
                    .help(editing ? "预览" : "编辑 Markdown 源码")
                    .accessibilityLabel(editing ? "预览" : "编辑 Markdown 源码")
                    .disabled(store.isReadOnly)
                    Button { navigation.toggleFavorite(board.id) } label: {
                        Image(systemName: navigation.isFavorite(board.id) ? "star.fill" : "star")
                            .foregroundStyle(navigation.isFavorite(board.id) ? Palette.accent : Palette.muted)
                    }
                    .help(navigation.isFavorite(board.id) ? "取消常用固定" : "固定到常用")
                    .accessibilityLabel(navigation.isFavorite(board.id) ? "取消常用固定" : "固定到常用")
                }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .buttonStyle(HitAreaButtonStyle(compact: true))
                if store.isBoardArchived(board) {
                    Label("已归档 · 内容保留", systemImage: "archivebox")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                } else if case .task(let id) = board.owner, store.locate(id)?.task.completed == true {
                    Label("任务已结束", systemImage: "checkmark.circle")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if liveEditor.error != nil {
                if editing {
                    BoardMarkdownEditor(text: markdown, preview: { setEditing(false) }).padding(10)
                } else {
                    ScrollView { BoardMarkdownPreview(store: store, board: board).padding(12) }
                }
            } else {
                BoardLiveEditor(session: liveEditor, sourceMode: editing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                relatedBoards.padding(.horizontal, 14)
                if let error = liveEditor.error {
                    Text(error).font(.caption).foregroundStyle(Palette.deadline).padding(8)
                }
            }
            Divider()
            HStack(spacing: 6) {
                if !store.isReadOnly {
                    templateButton("折叠内容", systemImage: "chevron.down.square", template: .disclosure)
                    templateButton("论文阅读", systemImage: "book.closed", template: .paper)
                    templateButton("会议议程", systemImage: "list.bullet", template: .meeting)
                } else {
                    Spacer()
                    Text("只读").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
            }.padding(.horizontal, 12).padding(.vertical, 8).background(Palette.card)
        }
        .onDisappear { liveEditor.flush() }
    }

    private func templateButton(_ title: LocalizedStringKey, systemImage: String,
                                template: BoardMarkdownTemplate) -> some View {
        Button { insertTemplate(template) } label: {
            ViewThatFits(in: .horizontal) {
                Label(title, systemImage: systemImage).fixedSize()
                Text(title).fixedSize()
            }
            .font(.system(size: 11, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 24)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(HitAreaButtonStyle(compact: true, pressedScale: 0.98))
        .foregroundStyle(Palette.muted)
        .background(Palette.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line.opacity(0.7), lineWidth: 0.5))
        .accessibilityLabel(title)
    }

    @ViewBuilder private var relatedBoards: some View {
        if case .tag(let tag) = board.owner, !board.archived {
            let taskIDs = Set(store.tasks(taggedWith: tag).map(\.id))
            let related = store.boards.filter { candidate in
                guard !candidate.archived, case .task(let id) = candidate.owner else { return false }
                return taskIDs.contains(id)
            }
            if !related.isEmpty {
                Divider().padding(.top, 12)
                Text("标签下的工作板").font(.caption).foregroundStyle(Palette.muted)
                ForEach(related) { candidate in
                    Button {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        navigation.select(candidate.id)
                    } label: {
                        Label(store.boardTitle(candidate), systemImage: "list.bullet.rectangle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }
            }
        }
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
