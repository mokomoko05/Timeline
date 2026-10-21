import AppKit
import SwiftUI
import TimelineCore
import UniformTypeIdentifiers

@MainActor
final class BoardNavigation: ObservableObject {
    private let defaults: UserDefaults
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
        panel?.makeFirstResponder(nil)
        self.store?.save()
        self.store = store
        if let owner, let board = store.ensureBoard(for: owner) { navigation.selection = board.id }
        if panel == nil {
            let panel = BoardPanel(contentRect: NSRect(x: 0, y: 0, width: 410, height: 560),
                                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
            panel.title = AppLocalized("工作板")
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
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
        panel.contentView = NSHostingView(rootView: LocalizedRoot {
            BoardWorkspaceView(store: store, navigation: self.navigation,
                               close: { [weak self] in self?.hide() })
        })
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
        store?.save()
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
    @State private var draggedFavorite: UUID?

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
            .buttonStyle(.plain).foregroundStyle(Palette.muted).padding(14)
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
    }

    private var favoritesBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(navigation.favoriteBoards(in: store)) { favorite in
                    Button {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        store.save()
                        navigation.selection = favorite.id
                    } label: {
                        Text(store.boardTitle(favorite))
                            .font(.system(size: 11, weight: navigation.selection == favorite.id ? .semibold : .regular))
                            .lineLimit(1).truncationMode(.tail).frame(maxWidth: 140)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .foregroundStyle(navigation.selection == favorite.id ? Palette.accent : Palette.muted)
                            .background(navigation.selection == favorite.id ? Palette.soft : Palette.card, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help(store.boardTitle(favorite) + " · " + AppLocalized("拖动调整顺序"))
                    .accessibilityAddTraits(navigation.selection == favorite.id ? .isSelected : [])
                    .onDrag {
                        draggedFavorite = favorite.id
                        return NSItemProvider(item: favorite.id.uuidString as NSString,
                                              typeIdentifier: "local.timeline.board-favorite")
                    }
                    .onDrop(of: [UTType(exportedAs: "local.timeline.board-favorite")], isTargeted: nil) { providers in
                        guard !providers.isEmpty, let draggedFavorite, draggedFavorite != favorite.id,
                              let destination = navigation.favoriteBoardIDs.firstIndex(of: favorite.id) else { return false }
                        navigation.moveFavorite(draggedFavorite, to: destination)
                        self.draggedFavorite = nil
                        return true
                    }
                    .contextMenu {
                        let index = navigation.favoriteBoardIDs.firstIndex(of: favorite.id) ?? 0
                        Button("向左移") { navigation.moveFavorite(favorite.id, to: index - 1) }
                            .disabled(index == 0)
                        Button("向右移") { navigation.moveFavorite(favorite.id, to: index + 1) }
                            .disabled(index == navigation.favoriteBoardIDs.count - 1)
                        Divider()
                        Button("取消常用固定") { navigation.toggleFavorite(favorite.id) }
                    }
                }
            }.padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(height: 46)
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
        navigation.selection = board.id
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
                navigation.selection = board.id
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
    @FocusState private var editorFocused: Bool

    init(store: JournalStore, navigation: BoardNavigation, board: Board) {
        self.store = store
        self.navigation = navigation
        self.board = board
        _editing = State(initialValue: board.markdown.isEmpty && !store.isReadOnly)
    }

    private var markdown: Binding<String> {
        Binding(get: { store.boards.first { $0.id == board.id }?.markdown ?? board.markdown },
                set: { store.setBoardMarkdown($0, for: board.id) })
    }

    private func setEditing(_ value: Bool) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        store.save()
        editing = value
        editorFocused = value
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text(store.boardTitle(board)).font(.system(size: 18, weight: .semibold))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button { navigation.toggleFavorite(board.id) } label: {
                        Image(systemName: navigation.isFavorite(board.id) ? "star.fill" : "star")
                            .foregroundStyle(navigation.isFavorite(board.id) ? Palette.accent : Palette.muted)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help(navigation.isFavorite(board.id) ? "取消常用固定" : "固定到常用")
                    .accessibilityLabel(navigation.isFavorite(board.id) ? "取消常用固定" : "固定到常用")
                }
                HStack {
                    if store.isBoardArchived(board) { Label("已归档 · 内容保留", systemImage: "archivebox") }
                    else if case .task(let id) = board.owner, store.locate(id)?.task.completed == true {
                        Label("任务已结束", systemImage: "checkmark.circle")
                    }
                    Text("Markdown").foregroundStyle(Palette.muted)
                    Spacer()
                    if case .task(let id) = board.owner, store.locate(id) != nil {
                        Button { AppRouter.openNotes(id) } label: { Label("笔记", systemImage: "note.text") }
                    }
                    Button { setEditing(!editing) } label: {
                        Label(editing ? "预览" : "编辑", systemImage: editing ? "eye" : "pencil")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.isReadOnly)
                }.font(.system(size: 11)).foregroundStyle(Palette.muted).buttonStyle(.plain)
            }.padding(16)
            Divider()
            if editing {
                TextEditor(text: markdown)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .focused($editorFocused)
                    .padding(10)
                    .accessibilityLabel("工作板 Markdown 内容")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if markdown.wrappedValue.isEmpty {
                            Text("暂无内容，点击编辑开始书写。")
                                .font(.system(size: 12)).foregroundStyle(Palette.muted)
                        } else {
                            BoardMarkdownPreview(store: store, board: board,
                                                 edit: { if !store.isReadOnly { setEditing(true) } })
                        }
                        relatedBoards
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                if editing && markdown.wrappedValue.isEmpty {
                    Menu("插入模板") {
                        Button("论文阅读") {
                            markdown.wrappedValue = "# 论文阅读\n\n- [ ] Intro & Abstract\n- [ ] Background\n- [ ] Design\n- [ ] Experiment\n\n## 阅读笔记\n\n"
                        }
                        Button("会议议程") {
                            markdown.wrappedValue = "# " + AppLocalized("会议议程") + "\n\n## " + AppLocalized("进展同步")
                                + "\n\n## " + AppLocalized("讨论事项") + "\n\n## " + AppLocalized("结论与后续行动") + "\n\n"
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                } else {
                    Text(editing ? "直接编辑 Markdown，⌘↩ 预览" : "⌘↩ 编辑 · 点击链接打开网页")
                }
                Spacer()
                Text(store.isReadOnly ? "只读" : "自动保存")
            }.font(.system(size: 10)).foregroundStyle(Palette.muted).padding(12)
        }
        .onDisappear { store.save() }
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
                        store.save()
                        navigation.selection = candidate.id
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

    var body: some View {
        TaskLinkText(source: board.markdown, completed: false, color: Palette.ink,
                     fontSize: 13, edit: edit, open: { NSWorkspace.shared.open($0) },
                     maxLines: 0, markdown: true,
                     toggleMarkdownTask: store.isReadOnly ? nil : { line in
                         store.toggleBoardMarkdownTask(atLine: line, in: board.id)
                     })
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
                BoardMarkdownPreview(store: store, board: board)
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
