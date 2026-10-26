import SwiftUI
import UIKit
import TimelineCore

/// 工作板列表：每个任务或标签一页 Markdown，最近改过的在前。
struct BoardsView: View {
    let store: JournalStore
    @ObservedObject var feed: TabFeed
    @State private var path: [UUID] = []

    private var boards: [Board] {
        store.boards.filter { !store.isBoardArchived($0) && $0.hasContent }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(boards) { board in
                        NavigationLink(value: board.id) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(store.boardTitle(board)).font(.body.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                                    Spacer()
                                    Text(board.updatedAt.formatted(.relative(presentation: .named)))
                                        .font(.caption).foregroundStyle(Palette.muted)
                                }
                                BoardOutline(markdown: board.markdown)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .card()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(Palette.background)
            .overlay { if boards.isEmpty { ContentUnavailableView("没有工作板", systemImage: "doc.text", description: Text("在待办页面创建")) } }
            .navigationTitle("工作板")
            .navigationDestination(for: UUID.self) { BoardPage(store: store, id: $0) }
            // 先在后台把编辑器网页加载好，点进工作板时不用等。
            .onAppear { BoardWebSession.preload() }
            .onReceive(NotificationCenter.default.publisher(for: PerfProbe.openEditor)) { note in
                if note.object as? String == "board", let first = boards.first { path = [first.id] }
            }
            .onReceive(NotificationCenter.default.publisher(for: PerfProbe.action)) { note in
                if note.object as? String == "openBoard", let first = boards.first { path = [first.id] }
            }
            .onReceive(Navigator.shared.$target) { _ in
                if let id = Navigator.shared.take({ if case .board(let id) = $0 { id } else { nil } }),
                   store.boards.contains(where: { $0.id == id }) { path = [id] }
            }
        }
    }
}

/// 列表里的摘要：前几个标题和未完成的勾选数。
private struct BoardOutline: View {
    let markdown: String

    var body: some View {
        let lines = markdown.components(separatedBy: .newlines)
        let headings = lines.filter { $0.hasPrefix("#") }.prefix(3).map { $0.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
        let open = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- [ ]") }.count
        let done = lines.filter { let line = $0.trimmingCharacters(in: .whitespaces); return line.hasPrefix("- [x]") || line.hasPrefix("- [X]") }.count
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(headings.enumerated()), id: \.offset) { _, heading in
                Text(heading).font(.subheadline).foregroundStyle(Palette.muted).lineLimit(1)
            }
            if open + done > 0 {
                Label("\(done)/\(open + done)", systemImage: "checklist").font(.caption).foregroundStyle(Palette.muted)
            }
        }
    }
}

/// 一页工作板：和 Mac 一样是渲染好的 Markdown，点到哪里就在哪里编辑，光标所在的元素才露出 Markdown 标记。
/// 右上角菜单里可以切到完整源码；编辑时右上角「完成」收起键盘并写回。
struct BoardPage: View {
    @ObservedObject var store: JournalStore
    let id: UUID
    /// 从搜索结果打开：跳到这一行（从 1 开始）并高亮 `query`。
    var revealLine: Int?
    var query = ""
    @StateObject private var session: BoardWebSession
    @State private var showingHistory = false
    @AppStorage("boardSourceMode") private var sourceMode = false
    @Environment(\.scenePhase) private var scenePhase

    init(store: JournalStore, id: UUID, revealLine: Int? = nil, query: String = "") {
        self.store = store
        self.id = id
        self.revealLine = revealLine
        self.query = query
        _session = StateObject(wrappedValue: BoardWebSession(store: store, boardID: id))
    }

    private var board: Board? { store.boards.first { $0.id == id } }

    var body: some View {
        BoardWebEditor(session: session, sourceMode: sourceMode)
            .background(Palette.background)
            .navigationTitle(board.map(store.boardTitle) ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if session.editing {
                    Button("完成") { session.endEditing() }
                } else {
                    Menu {
                        Toggle(isOn: $sourceMode) { Label("显示 Markdown 源码", systemImage: "chevron.left.forwardslash.chevron.right") }
                        Button { session.commit(); showingHistory = true } label: { Label("版本历史", systemImage: "clock.arrow.circlepath") }
                    } label: { Image(systemName: "ellipsis.circle") }
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
