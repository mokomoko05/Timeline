import SwiftUI
import TimelineCore

/// 工作板列表：每个任务或标签一页 Markdown。
struct BoardsView: View {
    @ObservedObject var store: JournalStore

    private var boards: [Board] {
        store.boards.filter { !store.isBoardArchived($0) && $0.hasContent }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationStack {
            List(boards) { board in
                NavigationLink(value: board.id) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.boardTitle(board)).lineLimit(1)
                        Text(board.updatedAt.formatted(.relative(presentation: .named)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay { if boards.isEmpty { ContentUnavailableView("没有工作板", systemImage: "doc.text", description: Text("在待办详情里创建")) } }
            .navigationTitle("工作板")
            .navigationDestination(for: UUID.self) { BoardEditor(store: store, id: $0) }
        }
    }
}

/// 一页工作板：默认阅读（任务勾选可以直接点），切到编辑改 Markdown 源码。
struct BoardEditor: View {
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
                    .font(.system(.body, design: .monospaced))
                    .focused($focused)
                    .padding(.horizontal, 8)
                    .onChange(of: text) { _, value in store.setBoardMarkdown(value, for: id) }
            } else {
                ScrollView {
                    MarkdownBlocks(markdown: board?.markdown ?? "") { line in store.toggleBoardMarkdownTask(atLine: line, in: id) }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle(board.map(store.boardTitle) ?? "工作板")
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

/// 简单的块级 Markdown 显示：标题、任务勾选、列表、引用、代码块，行内格式交给系统。
struct MarkdownBlocks: View {
    let markdown: String
    let toggle: (Int) -> Void

    private enum Block: Identifiable {
        case heading(Int, Int, String), task(Int, Bool, String, Int), bullet(Int, String, Int), quote(Int, String), code(Int, String), text(Int, String), blank(Int)
        var id: Int {
            switch self {
            case .heading(let line, _, _), .task(let line, _, _, _), .bullet(let line, _, _), .quote(let line, _), .code(let line, _), .text(let line, _), .blank(let line): return line
            }
        }
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var code: (start: Int, lines: [String])?
        for (index, raw) in markdown.components(separatedBy: "\n").enumerated() {
            let line = index + 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let open = code { result.append(.code(open.start, open.lines.joined(separator: "\n"))); code = nil }
                else { code = (line, []) }
                continue
            }
            if code != nil { code!.lines.append(raw); continue }
            let indent = (raw.prefix { $0 == " " || $0 == "\t" }.count) / 2
            if trimmed.isEmpty { result.append(.blank(line)) }
            else if let level = trimmed.firstIndex(where: { $0 != "#" }).map({ trimmed.distance(from: trimmed.startIndex, to: $0) }),
                    (1...6).contains(level), trimmed.dropFirst(level).first == " " {
                result.append(.heading(line, level, String(trimmed.dropFirst(level + 1))))
            } else if let match = trimmed.wholeMatch(of: #/[-*+] \[([ xX])\] ?(.*)/#) {
                result.append(.task(line, match.1 != " ", String(match.2), indent))
            } else if let match = trimmed.wholeMatch(of: #/(?:[-*+]|\d+[.)]) (.*)/#) {
                result.append(.bullet(line, String(match.1), indent))
            } else if trimmed.hasPrefix(">") {
                result.append(.quote(line, String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                result.append(.text(line, trimmed))
            }
        }
        if let open = code { result.append(.code(open.start, open.lines.joined(separator: "\n"))) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks) { block in
                switch block {
                case .heading(_, let level, let text):
                    Text(MarkdownInline.render(text))
                        .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                        .padding(.top, level <= 2 ? 8 : 4)
                case .task(let line, let done, let text, let indent):
                    Button { toggle(line) } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: done ? "checkmark.square.fill" : "square")
                            Text(MarkdownInline.render(text)).strikethrough(done).foregroundStyle(done ? .secondary : .primary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, CGFloat(indent) * 18)
                case .bullet(_, let text, let indent):
                    HStack(alignment: .firstTextBaseline) { Text("•"); Text(MarkdownInline.render(text)) }
                        .padding(.leading, CGFloat(indent) * 18)
                case .quote(_, let text):
                    Text(MarkdownInline.render(text)).foregroundStyle(.secondary)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
                case .code(_, let text):
                    ScrollView(.horizontal) {
                        Text(text).font(.system(.callout, design: .monospaced)).padding(10)
                    }
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                case .text(_, let text):
                    Text(MarkdownInline.render(text))
                case .blank:
                    Spacer().frame(height: 4)
                }
            }
        }
        .textSelection(.enabled)
    }
}
