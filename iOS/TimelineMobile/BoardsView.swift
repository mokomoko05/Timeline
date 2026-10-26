import SwiftUI
import TimelineCore

/// 工作板列表：每个任务或标签一页 Markdown，最近改过的在前。
struct BoardsView: View {
    @ObservedObject var store: JournalStore

    private var boards: [Board] {
        store.boards.filter { !store.isBoardArchived($0) && $0.hasContent }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationStack {
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

/// 一页工作板：阅读时标题可以收起（记住状态）、勾选可以直接点；右上角切到源码编辑。
struct BoardPage: View {
    @ObservedObject var store: JournalStore
    let id: UUID
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var board: Board? { store.boards.first { $0.id == id } }

    var body: some View {
        Group {
            if editing {
                TextEditor(text: $text)
                    .font(.system(.callout, design: .monospaced))
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .onChange(of: text) { _, value in store.setBoardMarkdown(value, for: id) }
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let board {
                            Text(store.boardTitle(board)).font(.title2.weight(.bold)).foregroundStyle(Palette.ink)
                            Text("更新于 " + board.updatedAt.formatted(.relative(presentation: .named)))
                                .font(.caption).foregroundStyle(Palette.muted)
                            Divider().overlay(Palette.line)
                            MarkdownView(source: board.markdown, foldScope: "board." + id.uuidString) { line in
                                store.toggleBoardMarkdownTask(atLine: line, in: id)
                                store.save()
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .markdownScrolling(proxy)
                }
            }
        }
        .background(Palette.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button(editing ? "完成" : "编辑") {
                if !editing { text = board?.markdown ?? "" }
                editing.toggle()
                focused = editing
                if !editing { store.save() }
            }
        }
        .onChange(of: board?.markdown) { _, value in
            // 另一台设备同步过来的修改：没在输入时跟着更新。
            if let value, !focused, value != text { text = value }
        }
        .onDisappear { store.save() }
    }
}
