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
    @Published var floating: Bool {
        didSet { defaults.set(floating, forKey: "board.floating") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: "board.selection").flatMap(UUID.init(uuidString:))
        floating = defaults.object(forKey: "board.floating") as? Bool ?? true
    }

    func collapsed(_ id: UUID) -> Bool { defaults.bool(forKey: "board.collapsed." + id.uuidString) }
    func toggleCollapsed(_ id: UUID) {
        objectWillChange.send()
        defaults.set(!collapsed(id), forKey: "board.collapsed." + id.uuidString)
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
                               close: { [weak self] in self?.hide() },
                               changeLevel: { [weak self] in self?.updateLevel() })
        })
        updateLevel()
        if Headless.active { panel.alphaValue = 0; panel.ignoresMouseEvents = true }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) { panel.center() }
        panel.makeKeyAndOrderFront(nil)
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

    private func updateLevel() { panel?.level = navigation.floating ? .floating : .normal }
}

struct BoardOpenButton: View {
    @ObservedObject var store: JournalStore
    let owner: BoardOwner

    var body: some View {
        Button { BoardWindowController.shared.show(store: store, owner: owner) } label: {
            if let board = store.board(for: owner), board.stepCount > 0 {
                Label("\(board.completedCount)/\(board.stepCount)", systemImage: "list.bullet.rectangle")
            } else {
                Label("工作板", systemImage: "list.bullet.rectangle")
            }
        }
        .help("打开工作板").accessibilityLabel("打开工作板")
    }
}

struct BoardWorkspaceView: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var navigation: BoardNavigation
    var close: () -> Void = {}
    var changeLevel: () -> Void = {}
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
                Button {
                    navigation.floating.toggle()
                    changeLevel()
                } label: { Image(systemName: navigation.floating ? "pin.fill" : "pin") }
                    .help(navigation.floating ? "取消置顶" : "窗口置顶")
                    .accessibilityLabel(navigation.floating ? "取消置顶" : "窗口置顶")
                Button(action: close) { Image(systemName: "xmark") }.accessibilityLabel("关闭工作板")
            }
            .buttonStyle(.plain).foregroundStyle(Palette.muted).padding(14)
            Divider()
            if let board {
                BoardContentView(store: store, navigation: navigation, board: board).id(board.id)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "list.bullet.rectangle").font(.system(size: 34)).foregroundStyle(Palette.accent)
                    Text("把步骤和资料放在眼前").font(.headline)
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
}

private struct BoardChooser: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var navigation: BoardNavigation
    let close: () -> Void
    @State private var query = ""

    private func matches(_ title: String) -> Bool { query.isEmpty || title.localizedStandardContains(query) }
    private func select(_ owner: BoardOwner) {
        guard let board = store.ensureBoard(for: owner) else { return }
        navigation.selection = board.id
        close()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("搜索待办、标签和工作板", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if !store.boards.isEmpty {
                        Text("已有工作板").font(.caption).foregroundStyle(Palette.muted)
                        ForEach(store.boards.filter { matches(store.boardTitle($0)) }.sorted { $0.updatedAt > $1.updatedAt }) { board in
                            Button {
                                navigation.selection = board.id
                                close()
                            } label: {
                                HStack {
                                    Image(systemName: store.isBoardArchived(board) ? "archivebox" : "list.bullet.rectangle")
                                    Text(store.boardTitle(board)).lineLimit(2)
                                    Spacer()
                                    Text("\(board.completedCount)/\(board.stepCount)").monospacedDigit()
                                    if navigation.selection == board.id { Image(systemName: "checkmark") }
                                }.padding(.vertical, 5).contentShape(Rectangle())
                            }
                        }
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
}

struct BoardContentView: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var navigation: BoardNavigation
    let board: Board
    @State private var editing: UUID?
    @State private var dragged: UUID?

    private func finishEditing() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        editing = nil
        store.save()
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(store.boardTitle(board)).font(.system(size: 18, weight: .semibold)).textSelection(.enabled)
                HStack {
                    if store.isBoardArchived(board) { Label("已归档 · 内容保留", systemImage: "archivebox") }
                    else if case .task(let id) = board.owner, store.locate(id)?.task.completed == true {
                        Label("任务已结束", systemImage: "checkmark.circle")
                    }
                    Text("\(board.completedCount) / \(board.stepCount)").monospacedDigit()
                    Spacer()
                    if case .task(let id) = board.owner, store.locate(id) != nil {
                        Button { AppRouter.openNotes(id) } label: { Label("笔记", systemImage: "note.text") }
                    }
                }.font(.system(size: 11)).foregroundStyle(Palette.muted).buttonStyle(.plain)
                if board.stepCount > 0 { ProgressView(value: Double(board.completedCount), total: Double(board.stepCount)).tint(Palette.accent) }
            }.padding(16)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    if board.items.isEmpty { emptyBoard }
                    ForEach(Array(board.items.enumerated()), id: \.element.id) { index, item in
                        itemView(item, index: index)
                            .onDrop(of: [UTType(exportedAs: "local.timeline.board-item")], isTargeted: nil) { providers in
                                guard !providers.isEmpty, !store.isReadOnly, let dragged, dragged != item.id else { return false }
                                store.moveBoardItem(dragged, in: board.id, to: index)
                                self.dragged = nil
                                return true
                            }
                    }
                    relatedBoards
                }.padding(.horizontal, 14).padding(.bottom, 14)
            }
            Divider()
            HStack {
                Button { add(.step) } label: { Label("添加步骤", systemImage: "plus.circle") }
                Button { add(.note) } label: { Label("添加资料", systemImage: "note.text.badge.plus") }
                Spacer()
                Text("自动保存").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }.font(.system(size: 12)).buttonStyle(.plain).padding(14).disabled(store.isReadOnly)
        }
        .onDisappear { store.save() }
    }

    private var emptyBoard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("从一个步骤开始，也可以使用模板。").font(.system(size: 12)).foregroundStyle(Palette.muted)
            HStack {
                Button("论文阅读") { store.applyBoardTemplate(["Intro & Abstract", "Background", "Design", "Experiment"], to: board.id) }
                Button("会议议程") { store.applyBoardTemplate([AppLocalized("进展同步"), AppLocalized("讨论事项"), AppLocalized("结论与后续行动")], to: board.id) }
            }.buttonStyle(.bordered).disabled(store.isReadOnly)
        }.padding(.vertical, 18)
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
                    Button { finishEditing(); navigation.selection = candidate.id } label: {
                        Label(store.boardTitle(candidate), systemImage: "list.bullet.rectangle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func add(_ kind: BoardItem.Kind) {
        finishEditing()
        if let id = store.addBoardItem(to: board.id, kind: kind) { editing = id }
    }

    private func binding(_ item: BoardItem, body: Bool) -> Binding<String> {
        Binding(get: {
            let current = store.boards.first { $0.id == board.id }?.items.first { $0.id == item.id } ?? item
            return body ? current.body : current.title
        }, set: { value in
            store.updateBoardItem(item.id, in: board.id, title: body ? nil : value, body: body ? value : nil)
        })
    }

    private func itemView(_ item: BoardItem, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if !store.isReadOnly {
                    Image(systemName: "line.3.horizontal").foregroundStyle(Palette.muted.opacity(0.5))
                        .help("拖动排序")
                        .onDrag {
                            finishEditing()
                            dragged = item.id
                            return NSItemProvider(item: item.id.uuidString as NSString, typeIdentifier: "local.timeline.board-item")
                        }
                }
                if item.kind == .step {
                    Button { store.updateBoardItem(item.id, in: board.id, completed: !item.completed) } label: {
                        Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 17)).foregroundStyle(item.completed ? Palette.success : Palette.muted)
                    }.accessibilityLabel(item.completed ? "标记未完成" : "标记完成")
                        .disabled(store.isReadOnly)
                } else { Image(systemName: "doc.text").foregroundStyle(Palette.accent) }
                if editing == item.id {
                    TextField("条目标题", text: binding(item, body: false)).textFieldStyle(.plain)
                        .onSubmit { finishEditing() }
                } else {
                    Text(item.title.isEmpty ? AppLocalized("未命名条目") : item.title)
                        .strikethrough(item.kind == .step && item.completed)
                        .foregroundStyle(item.completed ? Palette.muted : Palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onTapGesture(count: 2) { if !store.isReadOnly { editing = item.id } }
                }
                Spacer(minLength: 0)
                if !item.body.isEmpty && editing != item.id {
                    Button { navigation.toggleCollapsed(item.id) } label: {
                        Image(systemName: navigation.collapsed(item.id) ? "chevron.right" : "chevron.down")
                    }.accessibilityLabel("展开或折叠内容")
                }
                if !store.isReadOnly {
                    Button {
                        if editing == item.id { finishEditing() } else { finishEditing(); editing = item.id }
                    } label: { Image(systemName: editing == item.id ? "checkmark" : "pencil") }
                        .accessibilityLabel(editing == item.id ? "完成编辑" : "编辑条目")
                }
            }.buttonStyle(.plain).font(.system(size: 13, weight: .medium))
            if editing == item.id {
                Text("说明、要点与 Markdown 链接").font(.system(size: 10)).foregroundStyle(Palette.muted)
                TextEditor(text: binding(item, body: true))
                    .font(.system(size: 12)).scrollContentBackground(.hidden)
                    .frame(minHeight: 120).padding(5)
                    .background(Palette.background, in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Button("完成编辑") { finishEditing() }.keyboardShortcut(.return, modifiers: .command)
                    Spacer()
                    Text("自动保存").font(.caption).foregroundStyle(Palette.muted)
                }.font(.system(size: 11))
            } else if !item.body.isEmpty && !navigation.collapsed(item.id) {
                TaskLinkText(source: item.body, completed: false, color: Palette.ink, fontSize: 12,
                             edit: { if !store.isReadOnly { editing = item.id } },
                             open: { NSWorkspace.shared.open($0) }, maxLines: 0, markdown: true)
            }
        }
        .padding(12).background(Palette.card, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(editing == item.id ? Palette.accent.opacity(0.6) : Palette.line.opacity(0.5)))
        .contextMenu {
            if !store.isReadOnly {
                Button("编辑条目") { finishEditing(); editing = item.id }
                Button("上移") { store.moveBoardItem(item.id, in: board.id, to: index - 1) }.disabled(index == 0)
                Button("下移") { store.moveBoardItem(item.id, in: board.id, to: index + 1) }.disabled(index == board.items.count - 1)
                Divider()
                Button("删除条目", role: .destructive) { store.deleteBoardItem(item.id, in: board.id) }
            }
        }
    }
}
