import AppKit
import SwiftUI
import TimelineCore

/// 切换工作板列表里的一项：已有的工作板，或者还没有工作板的待办 / 标签（选中时再创建）。
struct BoardSwitcherItem: Identifiable, Equatable {
    enum Section: Int, CaseIterable {
        case favorites, recent, tasks, tags
        var title: String {
            switch self {
            case .favorites: return "常用工作板"
            case .recent: return "最近的工作板"
            case .tasks: return "待办"
            case .tags: return "标签"
            }
        }
    }

    let id: String
    let section: Section
    let title: String
    let symbol: String
    let boardID: UUID?
    let owner: BoardOwner
    var archived = false

    /// 常用 → 最近编辑过的工作板 → 还没有工作板的未完成待办 → 还没有工作板的标签。每个对象只出现一次。
    @MainActor
    static func items(store: JournalStore, favorites: [UUID], query: String) -> [BoardSwitcherItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        func matches(_ title: String) -> Bool { query.isEmpty || title.localizedStandardContains(query) }
        var result: [BoardSwitcherItem] = []
        var owners = Set<String>()
        func key(_ owner: BoardOwner) -> String {
            switch owner {
            case .task(let id): return "task:" + id.uuidString
            case .tag(let name): return "tag:" + TagText.key(name)
            }
        }
        func symbol(_ owner: BoardOwner) -> String {
            if case .tag = owner { return "number" }
            return "list.bullet.rectangle"
        }
        for id in favorites {
            guard let board = store.board(id: id) else { continue }
            owners.insert(key(board.owner))
            let title = store.boardTitle(board)
            guard matches(title) else { continue }
            result.append(BoardSwitcherItem(id: "board:" + id.uuidString, section: .favorites, title: title, symbol: symbol(board.owner),
                                            boardID: id, owner: board.owner, archived: store.isBoardArchived(board)))
        }
        for board in store.boards.sorted(by: { $0.updatedAt > $1.updatedAt }) where board.mergedInto == nil && !owners.contains(key(board.owner)) {
            owners.insert(key(board.owner))
            let title = store.boardTitle(board)
            guard matches(title) else { continue }
            result.append(BoardSwitcherItem(id: "board:" + board.id.uuidString, section: .recent, title: title, symbol: symbol(board.owner),
                                            boardID: board.id, owner: board.owner, archived: store.isBoardArchived(board)))
        }
        guard !store.isReadOnly else { return result }
        for task in store.sortedTasks() where !task.task.completed && !owners.contains(key(.task(task.id))) {
            let title = String(TaskText.rendered(task.task.title).characters)
            guard matches(title) else { continue }
            result.append(BoardSwitcherItem(id: "task:" + task.id.uuidString, section: .tasks, title: title, symbol: "circle",
                                            boardID: nil, owner: .task(task.id)))
        }
        for tag in store.allTags() where !owners.contains(key(.tag(tag.name))) {
            guard matches("#" + tag.name) else { continue }
            result.append(BoardSwitcherItem(id: "tag:" + tag.id, section: .tags, title: "#" + tag.name, symbol: "number",
                                            boardID: nil, owner: .tag(tag.name)))
        }
        return result
    }
}

/// 工作板里的切换器：直接盖在面板顶部，不再开系统弹窗。打开就能输入搜索，↑↓ 选择，回车打开，Esc 关闭。
struct BoardSwitcher: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var navigation: BoardNavigation
    let close: () -> Void
    @State private var query = ""
    @State private var highlighted = 0

    private var items: [BoardSwitcherItem] {
        BoardSwitcherItem.items(store: store, favorites: navigation.favoriteBoardIDs, query: query)
    }

    var body: some View {
        let items = items
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Palette.muted)
                BoardSwitcherField(text: $query, placeholder: AppLocalized("搜索工作板、待办和标签"),
                                   move: { delta in
                                       guard !items.isEmpty else { return }
                                       highlighted = min(max(highlighted + delta, 0), items.count - 1)
                                   },
                                   submit: { if items.indices.contains(highlighted) { open(items[highlighted]) } },
                                   cancel: close)
                Text("Esc").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.line, lineWidth: Metrics.hairline))
            }
            .padding(.horizontal, 12).frame(height: 38)
            Divider()
            if items.isEmpty {
                Text(query.isEmpty ? "还没有可以打开的工作板" : "没有匹配的结果")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity).padding(.vertical, 22)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // 列表只排可见的几行：打开切换器不用一次排完全部待办和标签。
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                if index == 0 || items[index - 1].section != item.section {
                                    Text(LocalizedStringKey(item.section.title))
                                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
                                        .padding(.horizontal, 14).padding(.top, index == 0 ? 8 : 12).padding(.bottom, 3)
                                }
                                row(item, index: index).id(item.id)
                            }
                        }
                        .padding(.bottom, 6)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: highlighted) { index in
                        guard items.indices.contains(index) else { return }
                        proxy.scrollTo(items[index].id)
                    }
                }
            }
        }
        .floatingPanelSurface()
        .onChange(of: query) { _ in highlighted = 0 }
        .accessibilityElement(children: .contain).accessibilityLabel("切换工作板")
    }

    private func row(_ item: BoardSwitcherItem, index: Int) -> some View {
        let current = item.boardID != nil && item.boardID == navigation.selection
        let active = index == highlighted
        return HStack(spacing: 8) {
            Image(systemName: item.archived ? "archivebox" : item.symbol)
                .font(.system(size: 11)).foregroundStyle(item.boardID == nil ? Palette.muted : Palette.accent)
                .frame(width: 16)
            Text(item.title).font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(item.archived ? Palette.muted : Palette.ink)
            Spacer(minLength: 4)
            if current { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.accent) }
            if item.boardID == nil {
                Text("新建").font(.system(size: 10)).foregroundStyle(Palette.muted).opacity(active ? 1 : 0)
            } else if let id = item.boardID {
                Button { navigation.toggleFavorite(id) } label: {
                    Image(systemName: navigation.isFavorite(id) ? "star.fill" : "star").font(.system(size: 10))
                        .foregroundStyle(navigation.isFavorite(id) ? Palette.accent : Palette.muted)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(active || navigation.isFavorite(id) ? 1 : 0)
                .help(navigation.isFavorite(id) ? "取消常用固定" : "固定到常用")
                .accessibilityLabel(navigation.isFavorite(id) ? "取消常用固定" : "固定到常用")
            }
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(active ? Palette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { if $0 { highlighted = index } }
        .onTapGesture { open(item) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(verbatim: item.title))
    }

    private func open(_ item: BoardSwitcherItem) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        if let id = item.boardID {
            navigation.select(id)
        } else if let board = store.ensureBoard(for: item.owner) {
            navigation.select(board.id)
        }
        close()
    }
}

/// 切换器的搜索框：出现时自动获得焦点，把 ↑↓、回车、Esc 交给切换器。
private struct BoardSwitcherField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.cell?.lineBreakMode = .byTruncatingTail
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: BoardSwitcherField
        init(_ parent: BoardSwitcherField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }
}
