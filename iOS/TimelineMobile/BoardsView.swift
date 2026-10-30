import Combine
import SwiftUI
import UIKit
import TimelineCore

@MainActor
final class BoardCatalog: ObservableObject {
    @Published private(set) var entries: [BoardListEntry] = []
    @Published private(set) var favorites: [UUID] = []
    private var preparing: Task<Void, Never>?
    private var snapshot: [Board] = []
    private var titles: [String] = []

    func reload(_ store: JournalStore) {
        if favorites != store.favoriteBoardIDs { favorites = store.favoriteBoardIDs }
        let boards = store.boards.filter { !store.isBoardArchived($0) }
        let names = boards.map(store.boardTitle)
        guard boards != snapshot || names != titles else { return }
        snapshot = boards
        titles = names
        preparing?.cancel()
        preparing = Task {
            let result = await Task.detached(priority: .userInitiated) {
                zip(boards, names).map { BoardListEntry(board: $0, title: $1) }.sorted {
                    ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString)
                }
            }.value
            guard !Task.isCancelled else { return }
            entries = result
        }
    }
}

struct BoardsView: View {
    let store: JournalStore
    @ObservedObject var feed: TabFeed
    let sync: SyncModel
    @State private var path: [UUID] = []
    @State private var managingFavorites = false
    @StateObject private var catalog = BoardCatalog()

    var body: some View {
        NavigationStack(path: $path) {
            BoardListView(store: store, catalog: catalog, manageFavorites: { managingFavorites = true })
                .navigationTitle("工作板")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: UUID.self) { BoardPage(store: store, id: $0, sync: sync) }
                .toolbar {
                    SyncToolbarItems(sync: sync)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { managingFavorites = true } label: { Image(systemName: "star.circle") }
                            .accessibilityLabel("收藏与排序")
                    }
                }
                .sheet(isPresented: $managingFavorites) { BoardFavoritesSheet(store: store) }
                .syncOnRefresh(sync)
                .onAppear { catalog.reload(store); BoardWebSession.preload() }
                .onReceive(feed.objectWillChange) { _ in
                    Task { @MainActor in catalog.reload(store) }
                }
                .onReceive(NotificationCenter.default.publisher(for: PerfProbe.openEditor)) { note in
                    if note.object as? String == "board", let first = catalog.entries.first { path = [first.id] }
                }
                .onReceive(NotificationCenter.default.publisher(for: PerfProbe.action)) { note in
                    switch note.object as? String {
                    case "openBoard": if let first = catalog.entries.first { path = [first.id] }
                    case "boardBack": path = []
                    case "boardFavorites": managingFavorites = true
                    case "boardFavoritesClose": managingFavorites = false
                    default: break
                    }
                }
                .onReceive(Navigator.shared.$target) { _ in
                    if let id = Navigator.shared.take({ if case .board(let id) = $0 { id } else { nil } }),
                       store.boards.contains(where: { $0.id == id }) { path = [id] }
                }
        }
    }
}

private struct BoardListView: View {
    let store: JournalStore
    @ObservedObject var catalog: BoardCatalog
    let manageFavorites: () -> Void
    @State private var query = ""
    @State private var searchPresented = false

    private var matches: [BoardListEntry] { catalog.entries.filter { $0.matches(query) } }

    var body: some View {
        let results = matches
        let lookup = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        let favorites = catalog.favorites.compactMap { lookup[$0] }
        let recent = results.filter { !catalog.favorites.contains($0.id) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if !favorites.isEmpty {
                    Text("收藏工作板").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.muted)
                    ForEach(favorites) { row($0, favorite: true) }
                }
                if !recent.isEmpty {
                    if !favorites.isEmpty { Text("其他工作板").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.muted).padding(.top, 8) }
                    ForEach(recent) { row($0, favorite: false) }
                }
            }.padding(16)
        }
        .background(Palette.background)
        .searchable(text: $query, isPresented: $searchPresented, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索工作板标题或正文")
        .overlay {
            if results.isEmpty {
                ContentUnavailableView(query.isEmpty ? "没有工作板" : "没有匹配的工作板", systemImage: "doc.text",
                                       description: Text(query.isEmpty ? "在待办页面创建" : "试试其他标题、标签或正文关键词"))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PerfProbe.action)) { note in
            if note.object as? String == "boardSearch" { query = "计划" }
            if note.object as? String == "boardSearchClear" { query = "" }
        }
        .onReceive(NotificationCenter.default.publisher(for: PerfProbe.openEditor)) { note in
            if note.object as? String == "boardSearch" { searchPresented = true }
        }
    }

    private func row(_ entry: BoardListEntry, favorite: Bool) -> some View {
        NavigationLink(value: entry.id) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(Palette.accent) }
                    Text(entry.title).font(.body.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                    Spacer()
                    Text(entry.updatedAt.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(Palette.muted)
                }
                ForEach(Array(entry.headings.enumerated()), id: \.offset) { _, heading in
                    Text(heading).font(.subheadline).foregroundStyle(Palette.muted).lineLimit(1)
                }
                if entry.openTasks + entry.doneTasks > 0 {
                    Label("\(entry.doneTasks)/\(entry.openTasks + entry.doneTasks)", systemImage: "checklist")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).card()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { store.toggleBoardFavorite(entry.id) } label: {
                Label(favorite ? "取消收藏" : "收藏工作板", systemImage: favorite ? "star.slash" : "star")
            }.disabled(store.isReadOnly)
            Button(action: manageFavorites) { Label("收藏与排序", systemImage: "arrow.up.arrow.down") }
        }
        .accessibilityIdentifier("board-row-" + entry.id.uuidString)
    }
}

private struct BoardFavoritesSheet: View {
    @ObservedObject var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    private var favorites: [Board] { store.favoriteBoardIDs.compactMap { id in store.board(id: id) } }
    private var others: [Board] {
        store.boards.filter { !store.isBoardArchived($0) && !store.favoriteBoardIDs.contains($0.id) }
            .sorted { store.boardTitle($0).localizedStandardCompare(store.boardTitle($1)) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(favorites) { board in
                        favoriteRow(board, selected: true)
                    }
                    .onMove(perform: moveFavorites)
                    if favorites.isEmpty { Text("还没有收藏工作板").foregroundStyle(Palette.muted) }
                } header: { Text("收藏工作板") } footer: { Text("拖动右侧手柄调整顺序，Mac 快捷栏将同步此顺序。") }
                Section("其他工作板") { ForEach(others) { favoriteRow($0, selected: false) } }
            }
            .environment(\.editMode, .constant(store.isReadOnly ? .inactive : .active))
            .navigationTitle("收藏与排序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onReceive(NotificationCenter.default.publisher(for: PerfProbe.action)) { note in
                switch note.object as? String {
                case "boardFavoriteToggle":
                    if let board = store.boards.first { store.toggleBoardFavorite(board.id) }
                case "boardFavoriteMove":
                    if let id = store.favoriteBoardIDs.first {
                        moveFavorites(from: IndexSet(integer: 0), to: favorites.count)
                        if PerfProbe.enabled { print("[perf] BOARD_FAVORITE_MOVE \(store.favoriteBoardIDs.last == id && store.favoriteBoardIDs.count > 1 ? "PASS" : "FAIL")") }
                    }
                default: break
                }
            }
        }
    }

    private func moveFavorites(from source: IndexSet, to destination: Int) {
        var order = favorites.map(\.id)
        order.move(fromOffsets: source, toOffset: destination)
        store.setBoardFavoriteOrder(order + store.favoriteBoardIDs.filter { !order.contains($0) })
    }

    private func favoriteRow(_ board: Board, selected: Bool) -> some View {
        HStack {
            Text(store.boardTitle(board)).lineLimit(2)
            Spacer()
            Button { store.toggleBoardFavorite(board.id) } label: {
                Image(systemName: selected ? "star.fill" : "star").frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless).foregroundStyle(Palette.accent).disabled(store.isReadOnly)
            .accessibilityLabel(selected ? "取消收藏" : "收藏工作板")
        }
    }
}

/// 一页工作板：和 Mac 一样是渲染好的 Markdown，点到哪里就在哪里编辑，光标所在的元素才露出 Markdown 标记。
/// 右上角菜单里可以切到完整源码；编辑时右上角「完成」收起键盘并写回。
struct BoardPage: View {
    @ObservedObject var store: JournalStore
    let id: UUID
    let sync: SyncModel
    /// 从搜索结果打开：跳到这一行（从 1 开始）并高亮 `query`。
    var revealLine: Int?
    var query = ""
    @StateObject private var session: BoardWebSession
    @State private var showingHistory = false
    @AppStorage("boardSourceMode") private var sourceMode = false
    @Environment(\.scenePhase) private var scenePhase

    init(store: JournalStore, id: UUID, revealLine: Int? = nil, query: String = "", sync: SyncModel? = nil) {
        self.store = store
        self.id = id
        self.sync = sync ?? AppServices.shared.sync
        self.revealLine = revealLine
        self.query = query
        _session = StateObject(wrappedValue: BoardWebSession(store: store, boardID: id))
    }

    private var board: Board? { store.board(id: id) }

    var body: some View {
        BoardWebEditor(session: session, sourceMode: sourceMode)
            .background(Palette.background)
            .navigationTitle(board.map(store.boardTitle) ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                SyncToolbarItems(sync: sync)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if session.editing {
                        Button("完成") { session.endEditing() }
                    } else {
                        Menu {
                            Toggle(isOn: $sourceMode) { Label("显示 Markdown 源码", systemImage: "chevron.left.forwardslash.chevron.right") }
                            Button { session.commit { showingHistory = true } } label: { Label("版本历史", systemImage: "clock.arrow.circlepath") }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("更多")
                    }
                }
            }
            .sheet(isPresented: $showingHistory) { BoardHistoryView(store: store, boardID: id) }
            .onChange(of: scenePhase) { _, phase in if phase != .active { session.commit() } }
            .onAppear {
                if let revealLine { session.reveal(line: revealLine, query: query) }
                if PerfProbe.typing == "board" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { session.runTypingTest(PerfProbe.typingText) }
                }
            }
            .onDisappear { session.commit() }
    }
}
