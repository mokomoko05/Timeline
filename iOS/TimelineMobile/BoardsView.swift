import SwiftUI
import UIKit
import TimelineCore

/// 工作板列表：每个任务或标签一页 Markdown，最近改过的在前。
struct BoardsView: View {
    @ObservedObject var store: JournalStore
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
            .onReceive(NotificationCenter.default.publisher(for: PerfProbe.openEditor)) { note in
                if note.object as? String == "board", let first = boards.first { path = [first.id] }
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

/// 一页工作板：阅读时标题可以收起（记住状态）、勾选可以直接点；右上角切到源码编辑。
///
/// 编辑用原生的文本框，按键不经过 SwiftUI：工作板常有上万字，SwiftUI 的 `TextEditor` 每个字都要把全文复制、比较一遍，
/// 写进数据还会让所有页面重算。停顿半秒才写进数据；点「完成」、离开这一页、应用退到后台时立即写回。
struct BoardPage: View {
    @ObservedObject var store: JournalStore
    let id: UUID
    @State private var editing = false
    @State private var editor = SourceEditor.Handle()
    @State private var showingHistory = false
    @Environment(\.scenePhase) private var scenePhase

    private var board: Board? { store.boards.first { $0.id == id } }

    var body: some View {
        Group {
            if editing {
                SourceEditor(text: board?.markdown ?? "", handle: editor) { store.setBoardMarkdown($0, for: id) }
                    .padding(.horizontal, 8)
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let board {
                            Text(store.boardTitle(board)).font(.title2.weight(.bold)).foregroundStyle(Palette.ink)
                            Text(LF("更新于 %@", board.updatedAt.formatted(.relative(presentation: .named))))
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
            if !editing {
                Menu {
                    Button { flush(); showingHistory = true } label: { Label("版本历史", systemImage: "clock.arrow.circlepath") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
            Button(editing ? "完成" : "编辑") {
                if editing { flush() }
                editing.toggle()
            }
        }
        .sheet(isPresented: $showingHistory) { BoardHistoryView(store: store, boardID: id) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { flush() } }
        .onAppear { if PerfProbe.typing == "board" { editing = true } }
        .onDisappear { flush() }
    }

    private func flush() {
        if let text = editor.flush() { store.setBoardMarkdown(text, for: id) }
        store.save()
    }
}

/// 编辑 Markdown 源码的原生文本框：按键只在文本框里，停顿 `delay` 秒后才把全文交出去（`commit`）。
/// 外面的 `text` 变了（另一台设备同步过来）而这边没在输入、也没有没交出去的修改时，跟着换掉。
struct SourceEditor: UIViewRepresentable {
    let text: String
    let handle: Handle
    var delay: TimeInterval = 0.5
    let commit: (String) -> Void

    /// 页面用它在「完成」、离开、进后台时立即取回还没交出去的文字。
    @MainActor final class Handle {
        fileprivate weak var view: UITextView?
        fileprivate var pending: DispatchWorkItem?

        /// 有没交出去的修改就返回全文。
        func flush() -> String? {
            guard let pending else { return nil }
            pending.cancel()
            self.pending = nil
            return view?.text
        }
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = UIFontMetrics(forTextStyle: .callout).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textColor = UIColor(Palette.ink)
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.autocapitalizationType = .none
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.text = text
        view.delegate = context.coordinator
        handle.view = view
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if !view.isFirstResponder, handle.pending == nil, view.text != text { view.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SourceEditor

        init(parent: SourceEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            let handle = parent.handle
            handle.pending?.cancel()
            let work = DispatchWorkItem { [weak textView] in
                handle.pending = nil
                if let text = textView?.text { self.parent.commit(text) }
            }
            handle.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + parent.delay, execute: work)
        }
    }
}
