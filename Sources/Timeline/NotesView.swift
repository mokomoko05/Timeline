import AppKit
import SwiftUI
import TimelineCore

/// 笔记视图：每个 TODO 是一个主题，笔记按日期汇总；每个标签也是一个主题，汇总带这个标签的所有待办的笔记。
struct NotesView: View {
    @Environment(\.typography) private var typography
    @ObservedObject private var languages = LanguageStore.shared
    @ObservedObject var store: JournalStore
    let initialSelection: UUID?
    let initialTag: String?
    let close: () -> Void
    let reveal: (UUID) -> Void
    let openDay: (Date) -> Void
    /// 停在哪里（选中的任务 / 标签、搜索词、视图方式）：存进偏好，关掉再开回到原处。
    @ObservedObject var nav: NotesNavigation
    @ObservedObject private var themes = ThemeStore.shared
    @State private var creatingTag = false
    @State private var tagFocused = false
    @State private var editingNoteID: UUID?
    @State private var editingNoteDate: Date?
    @State private var noteEditText = ""
    @State private var noteEditFocused = false
    @State private var focused = false
    @State private var error: String?
    /// 标签的右键操作：改名 / 合并、删除（内容保留）。
    @State private var renamingTag: String?
    @State private var renameText = ""
    @State private var renameMessage: String?
    @State private var deletingTag: String?
    /// 标签页输入框里的 `@` 补全。
    @StateObject private var tagMention = MentionState()
    /// 任务页输入框里的 `#`（任务页的日志固定属于这个任务，只能选标签）。
    @StateObject private var taskMention = MentionState()

    private var selection: UUID? { get { nav.selection } nonmutating set { nav.selection = newValue } }
    private var tagSelection: String? { get { nav.tagSelection } nonmutating set { nav.tagSelection = newValue } }
    private var query: String { nav.query }
    private var chapterView: Bool { nav.chapterView }

    // 草稿按「当前任务 / 当前标签」分开存在 nav 里：切换、关窗口、失焦都不丢。
    private func taskDraftKey(_ id: UUID) -> String { NotesNavigation.draftKey(task: id) }
    private func tagDraftKey(_ tag: String) -> String { NotesNavigation.draftKey(tag: tag) }

    private func textBinding(_ key: String) -> Binding<String> {
        Binding(get: { nav.draft(key).text }, set: { value in nav.updateDraft(key) { $0.text = value } })
    }
    private func images(_ key: String) -> [String] { nav.draft(key).images }
    private func addImages(_ names: [String], to key: String) { nav.updateDraft(key) { $0.images += names } }
    private func removeImage(_ name: String, from key: String) { nav.updateDraft(key) { $0.images.removeAll { $0 == name } } }

    /// 明确指定了任务或标签（比如点了待办上的标签）就跳过去；否则保持 `nav` 里上次停留的位置。
    init(store: JournalStore, initialSelection: UUID? = nil, initialTag: String? = nil, nav: NotesNavigation? = nil,
         close: @escaping () -> Void = {}, reveal: @escaping (UUID) -> Void, openDay: @escaping (Date) -> Void) {
        self.store = store
        self.initialSelection = initialSelection
        self.initialTag = initialTag
        self.close = close
        self.reveal = reveal
        self.openDay = openDay
        let navigation = nav ?? NotesNavigation()
        self.nav = navigation
        // 共享导航已经被父视图观察：在 View.init 中发布会重新构造父视图，
        // 空笔记本尤其容易出现 nil → nil 的反复刷新。只初始化自己新建的状态。
        if nav == nil {
            if let initialTag { navigation.open(tag: initialTag) }
            else if let initialSelection { navigation.open(task: initialSelection) }
        }
    }

    /// 搜索词去掉开头的 `#`；以 `#` 开头（且不是 `#3` 这样的编号）表示只找标签。
    private var tagQuery: String? { TagText.searchTag(query) }
    private var plainQuery: String { query.hasPrefix("#") ? String(query.drop(while: { $0 == "#" })) : query }

    private var topics: [JournalStore.NoteTopic] {
        var all = store.noteTopics()
        // 从清单打开的任务还没有笔记：也放进列表最上面，让它是选中的那一项。
        if let id = selection, !all.contains(where: { $0.id == id }), let empty = store.noteTopic(for: id) { all.insert(empty, at: 0) }
        guard !query.isEmpty else { return all }
        if let tag = tagQuery { return all.filter { $0.tags.contains { TagText.matches($0, query: tag) } } }
        return all.filter {
            $0.title.localizedStandardContains(query) || ($0.number.map { "#\($0)" } ?? "").contains(query)
                || $0.tags.contains { $0.localizedStandardContains(plainQuery) }
        }
    }

    private var tagRows: [JournalStore.TagSummary] {
        let all = store.allTags()
        guard !plainQuery.isEmpty else { return all }
        return all.filter { $0.name.localizedStandardContains(plainQuery) }
    }

    private var current: JournalStore.NoteTopic? {
        let all = store.noteTopics()
        return all.first { $0.id == selection } ?? (selection == nil ? nil : nil)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 250)
            Divider()
            detail.frame(maxWidth: .infinity)
        }
        .id(themes.themeID + themes.appearance.rawValue)
        .frame(minWidth: 640, minHeight: 420)
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
        .alert("删除标签 #\(deletingTag ?? "")？", isPresented: Binding(get: { deletingTag != nil }, set: { if !$0 { deletingTag = nil } })) {
            Button("删除", role: .destructive) {
                guard let name = deletingTag else { return }
                let count = store.deleteTag(name)
                if tagSelection.map({ JournalStore.isTag($0, under: name) }) == true { tagSelection = nil; nav.validate(in: store) }
                error = "已从 \(count) 个待办和日志上去掉 #\(name)，内容都保留 · ⌘Z 撤销"
                deletingTag = nil
            }
            Button("取消", role: .cancel) { deletingTag = nil }
        } message: {
            Text("只去掉这个标签（连同子标签），待办和笔记本身都保留。可以 ⌘Z 撤销。")
        }
        .onAppear {
            if let initialTag { nav.open(tag: initialTag) }
            else if let initialSelection { nav.open(task: initialSelection) }
            nav.validate(in: store)
            configureMention()
        }
    }

    /// 输入框里 `@` / `#` 的候选：标签页里，正在写的标签名下的待办排前面；选中后记进对应输入框的草稿。
    private func configureMention() {
        let nav = nav, store = store
        func key() -> String? { nav.tagSelection.map { NotesNavigation.draftKey(tag: $0) } ?? nav.selection.map { NotesNavigation.draftKey(task: $0) } }
        func chosen() -> [String] { key().map { nav.draft($0).tags } ?? [] }
        tagMention.triggers = [.task, .tag]
        tagMention.provider = MentionProviders.make(store: store, contextTags: { nav.tagSelection.map { [$0] } ?? [] }, chosenTags: {
            chosen() + (nav.tagSelection.map { [$0] } ?? [])
        })
        tagMention.onPick = { item in
            guard let key = key() else { return }
            switch item {
            case .task(let task): nav.updateDraft(key) { $0.link = task.id; $0.unlinked = false }
            case .tag(let tag): nav.updateDraft(key) { $0.tags = TagText.merge($0.tags, [tag.name]) }
            }
        }
        taskMention.triggers = [.tag]
        taskMention.provider = MentionProviders.make(store: store, chosenTags: chosen)
        taskMention.onPick = { item in
            guard let key = key(), case .tag(let tag) = item else { return }
            nav.updateDraft(key) { $0.tags = TagText.merge($0.tags, [tag.name]) }
        }
    }

    // MARK: - 左侧：有笔记的任务

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "note.text").foregroundStyle(Palette.accent)
                Text("笔记").font(.system(size: 16, weight: .semibold))
                Spacer()
                let key = HotKeyStore.binding(for: .notes).label
                Text("\(key) 关闭").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField("搜索任务或标签（#标签）", text: $nav.query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 7))
            let list = topics
            let tagList = tagRows
            if list.isEmpty && tagList.isEmpty && !query.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "note.text").font(.system(size: 26, weight: .light)).foregroundStyle(Palette.muted.opacity(0.6))
                    Text("没有匹配的任务或标签").font(.system(size: 13, weight: .medium))
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        tagSectionHeader
                        if tagList.isEmpty {
                            Text("还没有标签")
                                .font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.horizontal, 10).padding(.bottom, 4)
                        }
                        ForEach(tagList) { tagRow($0) }
                        if !list.isEmpty {
                            sectionTitle("任务")
                            ForEach(list) { topic in topicRow(topic) }
                        }
                    }
                }
            }
        }
        .padding(16)
        // 弹窗挂在稳定的侧栏上，创建 / 筛选标签时不会替换其 LazyVStack 锚点。
        .popover(isPresented: $creatingTag, arrowEdge: .trailing) {
            CreateNotebookTagView(store: store, cancel: { creatingTag = false }, created: { name in
                creatingTag = false
                select(tag: name)
            })
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(LocalizedStringKey(text)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
            .padding(.horizontal, 10).padding(.top, 6)
    }

    /// 「标签」小标题，右边的 + 创建一个新标签（笔记本），可以先建空的、以后再写。
    private var tagSectionHeader: some View {
        HStack(spacing: 4) {
            sectionTitle("标签（笔记本）")
            Spacer(minLength: 0)
            Button { creatingTag = true } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Palette.accent).padding(.top, 6)
            .help("新建标签").accessibilityLabel("新建标签")
            .disabled(store.isReadOnly)
        }
    }

    private func select(task id: UUID) {
        selection = id
        tagSelection = nil
        error = nil
    }

    private func select(tag: String) {
        tagSelection = tag
        selection = nil
        error = nil
    }

    private func tagRow(_ summary: JournalStore.TagSummary) -> some View {
        let chosen = tagSelection.map { TagText.key($0) == TagText.key(summary.name) } == true
        return Button { select(tag: summary.name) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("#" + summary.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.accent).lineLimit(1)
                HStack(spacing: 8) {
                    if summary.taskCount == 0 && summary.noteCount == 0 {
                        Text("空标签")
                    } else {
                        Text("\(summary.taskCount) 个待办").monospacedDigit()
                        Text("\(summary.noteCount) 条笔记").monospacedDigit()
                    }
                    Spacer(minLength: 4)
                    if summary.lastActivity > .distantPast { Text(summary.lastActivity.relativeLabel) }
                }
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(chosen ? Palette.soft : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("标签 \(summary.name)，\(summary.taskCount) 个待办，\(summary.noteCount) 条笔记")
        .contextMenu {
            Button("重命名 / 合并…") { renameText = summary.name; renameMessage = nil; renamingTag = summary.name }
            if summary.taskCount == 0 && summary.noteCount == 0 {
                Button("删除这个空标签", role: .destructive) {
                    if store.removeEmptyTag(summary.name), tagSelection.map({ TagText.key($0) == summary.id }) == true { tagSelection = nil }
                }
            } else {
                Button("删除标签（内容保留）…", role: .destructive) { deletingTag = summary.name }
            }
        }
        .popover(isPresented: Binding(get: { renamingTag == summary.name }, set: { if !$0 { renamingTag = nil } }), arrowEdge: .trailing) {
            renamePopover(summary.name)
        }
    }

    /// 改名：子标签跟着改；新名字已经存在就是合并。
    private func renamePopover(_ old: String) -> some View {
        let target = TagText.normalize(renameText)
        let merging = target.map { name in TagText.key(name) != TagText.key(old) && store.allTags().contains { $0.id == TagText.key(name) } } ?? false
        return VStack(alignment: .leading, spacing: 10) {
            Text("重命名 #\(old)").font(.headline)
            TextField("新名字", text: $renameText).textFieldStyle(.roundedBorder).onSubmit { commitRename(old) }
            if let renameMessage { Text(LocalizedStringKey(renameMessage)).font(.caption).foregroundStyle(.orange) }
            Text(merging ? AppLocalizedFormat("#%@ 已经存在：会把两个标签合并，内容汇到一起。", target ?? "") : AppLocalizedFormat("所有待办、日志里的 #%@（包括它的子标签）都会改成新名字。可以 ⌘Z 撤销。", old))
                .font(.caption).foregroundStyle(merging ? Palette.accent : .secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { renamingTag = nil }.keyboardShortcut(.cancelAction)
                Button(merging ? "合并" : "重命名") { commitRename(old) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(target == nil || target == old)
            }
        }.padding(16).frame(width: 320)
    }

    private func commitRename(_ old: String) {
        guard let name = store.renameTag(old, to: renameText) else {
            renameMessage = "标签不能为空、含空格，或是纯数字"
            return
        }
        renamingTag = nil
        if tagSelection.map({ JournalStore.isTag($0, under: old) }) == true { select(tag: JournalStore.renamedTag(tagSelection!, from: old, to: name)) }
        error = "已重命名为 #\(name) · ⌘Z 撤销"
    }

    private func topicRow(_ topic: JournalStore.NoteTopic) -> some View {
        Button { select(task: topic.id) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if let number = topic.number {
                        Text("#\(number)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                    }
                    Text(topic.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if topic.dropped { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.muted) } else if topic.completed { Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.success) }
                }
                HStack(spacing: 8) {
                    Text(topic.count == 0 ? AppLocalized("还没有笔记") : AppLocalizedFormat("%lld 条", topic.count)).monospacedDigit()
                    if topic.imageCount > 0 { Label("\(topic.imageCount)", systemImage: "photo") }
                    if topic.deleted { Text("任务已删除") }
                    Spacer(minLength: 4)
                    if topic.count > 0 { Text(topic.lastActivity.relativeLabel) }
                }
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selection == topic.id ? Palette.soft : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(topic.number.map { "#\($0) " } ?? "")\(topic.title)，\(topic.count) 条笔记")
    }

    // MARK: - 右侧：这个任务名下的笔记

    @ViewBuilder
    private var detail: some View {
        if let tag = tagSelection {
            tagDetail(tag)
        } else if let id = selection, let topic = store.noteTopic(for: id) {
            let notes = store.notes(for: id)
            VStack(spacing: 0) {
                header(topic, notes: notes)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            BoardNotesSection(store: store, owner: .task(id)).id("board-start")
                            ForEach(Dictionary(grouping: notes, by: \.key).sorted { $0.key < $1.key }, id: \.key) { group in
                                dayHeader(group.key, date: group.value[0].date)
                                ForEach(group.value) { item in noteRow(item) }
                            }
                            Color.clear.frame(height: 1).id("end")
                        }.padding(20)
                    }
                    .contentShape(Rectangle())
                    .onAppear {
                        if store.board(for: .task(id))?.hasContent == true { proxy.scrollTo("board-start", anchor: .top) }
                        else { proxy.scrollTo("end", anchor: .bottom) }
                    }
                    .onChange(of: notes.count) { _ in withAnimation(Motion.quick) { proxy.scrollTo("end", anchor: .bottom) } }
                    .onChange(of: selection) { _ in
                        if store.board(for: .task(id))?.hasContent == true { proxy.scrollTo("board-start", anchor: .top) }
                        else { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
                Divider()
                composer(topic)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "text.book.closed").font(.system(size: 34, weight: .light)).foregroundStyle(Palette.muted.opacity(0.6))
                Text("从左侧选择一个任务或标签").font(.system(size: 14, weight: .medium))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ topic: JournalStore.NoteTopic, notes: [JournalStore.LoggedLog]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let number = topic.number {
                        Text("#\(number)").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.accent)
                    }
                    Text(topic.title).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                }
                HStack(spacing: 10) {
                    if topic.dropped { Label("已放弃", systemImage: "nosign").foregroundStyle(Palette.muted) } else if topic.completed { Label("已完成", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.success) }
                    if topic.deleted { Label("任务已删除", systemImage: "trash").foregroundStyle(Palette.deadline) }
                    if let due = topic.dueDate { Label("截止 \(due.relativeLabel)", systemImage: "clock") }
                    if topic.focusSeconds >= 1 { Label("已专注 \(FocusSession.brief(topic.focusSeconds))", systemImage: "hourglass") }
                    Text("\(topic.count) 条笔记")
                }
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
                if !topic.tags.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(topic.tags, id: \.self) { tag in
                            Button { select(tag: tag) } label: { TagChip(name: tag, size: 11) }
                                .buttonStyle(.plain).help("查看 #\(tag) 名下所有待办的笔记")
                        }
                    }
                }
            }
            Spacer()
            if let task = store.locate(topic.id), !store.isReadOnly {
                BoardOpenButton(store: store, owner: .task(task.id))
                // 和清单里的扇形菜单一致：完成、放弃、标签都能在笔记里直接做。
                Button { store.toggleTodo(task.id, on: task.date) } label: {
                    Label(task.task.isDone ? "取消完成" : "完成", systemImage: task.task.isDone ? "arrow.uturn.backward.circle" : "checkmark.circle")
                }
                .disabled(task.task.isDropped).help(task.task.isDone ? "标记为未完成" : "标记为已完成 · ⌘Z 撤销")
                if !task.task.isDone {
                    Button { store.dropTodo(task.id, on: task.date) } label: {
                        Label(task.task.isDropped ? "恢复" : "放弃", systemImage: task.task.isDropped ? "arrow.uturn.backward.circle" : "nosign")
                    }
                    .help(task.task.isDropped ? "恢复" : "放弃")
                }
                TagSelectionButton(store: store, tags: Binding(get: { store.locate(task.id)?.task.tags ?? [] }, set: { store.setTags(task.id, $0) }))
            }
            if !topic.deleted, !topic.completed {
                let pinned = store.pinnedTask?.id == topic.id
                Button { store.pinTask(pinned ? nil : topic.id) } label: {
                    Label(pinned ? "取消固定" : "固定", systemImage: pinned ? "pin.slash" : "pin")
                }
                .foregroundStyle(pinned ? Palette.accent : Palette.ink)
                .help(pinned ? "取消固定" : "固定为当前待办")
            }
            if !topic.deleted {
                Button { close(); reveal(topic.id) } label: { Label("在清单中显示", systemImage: "list.bullet") }
                    .help("在清单中显示")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.markdown(topic, notes: notes), forType: .string)
                error = "已复制为 Markdown"
            } label: { Label("复制为 Markdown", systemImage: "doc.on.doc") }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func dayHeader(_ key: String, date: Date) -> some View {
        Button { close(); openDay(date) } label: {
            HStack(spacing: 6) {
                Text(date.relativeLabel).font(.system(size: 12, weight: .semibold))
                Text(key).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                Rectangle().fill(Palette.line).frame(height: 1)
            }
        }
        .buttonStyle(.plain).foregroundStyle(Palette.accent)
        .padding(.top, 14).padding(.bottom, 4)
        .help("跳到这一天的日志")
    }

    private func noteRow(_ item: JournalStore.LoggedLog, showTask: Bool = false, showDate: Bool = false) -> some View {
        let log = item.log
        return HStack(alignment: .top, spacing: 10) {
            Text((showDate ? String(item.key.dropFirst(5)) + " " : "") + Self.time(log.createdAt)).font(.system(size: typography.pt(11), design: .monospaced)).foregroundStyle(Palette.muted).padding(.top, 2).fixedSize()
            LogEventBadge(log: log)
            VStack(alignment: .leading, spacing: 6) {
                if showTask, let label = Self.sourceLabel(log) {
                    Button { if let id = log.taskID, store.noteTopic(for: id) != nil { select(task: id) } } label: {
                        Text(label).font(.system(size: 11)).lineLimit(1)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Palette.soft, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.accent).help("查看这个待办的全部笔记")
                }
                if editingNoteID == log.id {
                    VStack(alignment: .leading, spacing: 4) {
                        TaskInput(text: $noteEditText, focused: $noteEditFocused, fontSize: 13,
                                  submit: { saveNoteEdit(item) }, cancel: cancelNoteEdit, minHeight: 24, maxLines: 12)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.accent.opacity(0.6)))
                            .onAppear { noteEditFocused = true }
                        Text("⌘Enter 保存 · Esc 取消").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                } else if !log.text.isEmpty {
                    TaskLinkText(source: LogEventStyle.body(log), completed: false, color: Palette.ink, fontSize: 13,
                                 edit: { guard !store.isReadOnly else { return }; beginNoteEdit(item) }, open: SafariLinks.open,
                                 maxLines: 0, markdown: true, compactLines: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !log.tags.isEmpty { TaskTagLine(tags: log.tags) }
                if !log.images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(log.images.enumerated()), id: \.element) { index, name in
                                Button { ImageViewerController.shared.show(store: store, around: log, index: index) } label: {
                                    ImageFit(url: store.imageURL(name), maxWidth: 440, maxHeight: 280)
                                }.buttonStyle(.plain).help("点击查看大图")
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                noteAction("doc.on.doc", log.copyText == nil ? "这条只有图片，没有文字可复制" : "复制这条的文字（不含图片）") { copy(log) }
                    .disabled(log.copyText == nil)
                if !store.isReadOnly {
                    noteAction("pencil", "编辑这条笔记") { beginNoteEdit(item) }
                    EntryMetadataButtons(store: store, log: log, date: item.date)
                    noteAction("trash", "删除这条笔记 · ⌘Z 撤销", destructive: true) { deleteNote(item) }
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 5)
    }

    private func noteAction(_ symbol: String, _ help: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(destructive ? Palette.deadline : Palette.muted)
        .help(LocalizedStringKey(help)).accessibilityLabel(LocalizedStringKey(help))
    }

    private func beginNoteEdit(_ item: JournalStore.LoggedLog) {
        guard editingNoteID == nil else { return }
        editingNoteID = item.log.id
        editingNoteDate = item.date
        noteEditText = item.log.text
        noteEditFocused = true
    }

    private func cancelNoteEdit() {
        editingNoteID = nil
        editingNoteDate = nil
        noteEditFocused = false
    }

    private func saveNoteEdit(_ item: JournalStore.LoggedLog) {
        guard editingNoteID == item.log.id else { return }
        editingNoteID = nil
        editingNoteDate = nil
        store.updateLog(item.log.id, text: noteEditText, on: item.date)
    }

    private func deleteNote(_ item: JournalStore.LoggedLog) {
        if editingNoteID == item.log.id { editingNoteID = nil; editingNoteDate = nil }
        store.deleteLog(item.log.id, on: item.date)
        error = "已删除这条笔记，⌘Z 可撤销"
    }

    private func copy(_ log: DailyLogEntry) {
        error = LogClipboard.copy(store: store, ids: [log.id]) > 0 ? "已复制这条笔记的文字" : "这条只有图片，没有文字可复制"
    }

    // MARK: - 右侧：一个标签名下所有待办的笔记

    private static func sourceLabel(_ log: DailyLogEntry) -> String? {
        guard let title = log.taskTitle else { return nil }
        return (log.taskNumber.map { "#\($0) " } ?? "") + title
    }

    /// 目录至少要有两章、窗口够宽才显示。
    private func showsOutline(chapters: [NotebookChapter], width: CGFloat) -> Bool {
        chapterView && nav.showOutline && chapters.count >= 2 && width >= 640
    }

    private func tagDetail(_ tag: String) -> some View {
        let tasks = store.tasks(taggedWith: tag)
        let notes = store.notes(forTag: tag)
        let chapters = chapterView ? store.chapters(notes: notes, tasks: tasks) : []
        let hasBoardContent = store.board(for: .tag(tag))?.hasContent == true
            || tasks.contains { store.board(for: .task($0.id))?.hasContent == true }
        return VStack(spacing: 0) {
            tagHeader(tag, tasks: tasks, notes: notes)
            Divider()
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    HStack(spacing: 0) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                Color.clear.frame(height: 1).id("board-start")
                                BoardNotesSection(store: store, owner: .tag(tag))
                                if notes.isEmpty && tasks.isEmpty {
                                    Text("还没有笔记")
                                        .font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.vertical, 12)
                                }
                                if chapterView { chapterList(tag, chapters) } else { dateList(notes) }
                                Color.clear.frame(height: 1).id("end")
                            }.padding(20)
                        }
                        .contentShape(Rectangle())
                        .onAppear { proxy.scrollTo(hasBoardContent ? "board-start" : "end", anchor: hasBoardContent ? .top : .bottom) }
                        .onChange(of: tagSelection) { _ in
                            proxy.scrollTo(hasBoardContent ? "board-start" : "end", anchor: hasBoardContent ? .top : .bottom)
                        }
                        .onChange(of: notes.count) { _ in withAnimation(Motion.quick) { proxy.scrollTo("end", anchor: .bottom) } }
                        if showsOutline(chapters: chapters, width: geometry.size.width) {
                            Divider()
                            outline(tag, chapters, proxy: proxy)
                        }
                    }
                }
            }
            Divider()
            tagComposer(tag)
        }
    }

    // MARK: - 标签页右侧的目录

    static func chapterAnchor(_ chapter: NotebookChapter) -> String { "chapter-" + chapter.id }

    /// 这个标签下的待办（章节）目录：点一项跳到那一章（折叠着就先展开）；内容很长时不用一路往下翻。
    private func outline(_ tag: String, _ chapters: [NotebookChapter], proxy: ScrollViewProxy) -> some View {
        let allCollapsed = chapters.allSatisfy { nav.isCollapsed(tag: tag, chapter: $0.id) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("目录").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                Text("\(chapters.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted)
                Spacer()
                Button(allCollapsed ? "全部展开" : "全部折叠") {
                    for chapter in chapters { nav.setCollapsed(!allCollapsed, tag: tag, chapter: chapter.id) }
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.accent)
                .help(allCollapsed ? "展开所有章节" : "折叠所有章节，只留标题")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(chapters) { chapter in outlineRow(tag, chapter, proxy: proxy) }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 12)
        .frame(width: 210)
        .background(Palette.background)
        .accessibilityElement(children: .contain).accessibilityLabel("章节目录")
    }

    private func outlineRow(_ tag: String, _ chapter: NotebookChapter, proxy: ScrollViewProxy) -> some View {
        let folded = nav.isCollapsed(tag: tag, chapter: chapter.id)
        return Button {
            if folded { nav.setCollapsed(false, tag: tag, chapter: chapter.id) }
            let anchor = Self.chapterAnchor(chapter)
            // 刚展开时先等布局更新，再滚过去。
            // 目录跳转是定位操作，直接落到目标位置，避免长列表滚动动画造成拖沓感。
            DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: chapter.taskID == nil ? "square.and.pencil" : (chapter.dropped ? "xmark.circle.fill" : (chapter.completed ? "checkmark.circle.fill" : "circle")))
                    .font(.system(size: 10)).foregroundStyle(chapter.completed && !chapter.dropped ? Palette.success : Palette.muted)
                if let number = chapter.number {
                    Text("#\(number)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                }
                Text(chapter.title).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading)
                    .foregroundStyle(folded ? Palette.muted : Palette.ink)
                Spacer(minLength: 2)
                Text("\(chapter.notes.count)").font(.system(size: 10)).monospacedDigit().foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("跳到这一章")
        .accessibilityLabel("\(chapter.number.map { "#\($0) " } ?? "")\(chapter.title)，\(chapter.notes.count) 条笔记")
    }

    /// 按待办（章节）：标签是笔记本，每个待办是里面的一章。
    @ViewBuilder
    private func chapterList(_ tag: String, _ chapters: [NotebookChapter]) -> some View {
        ForEach(chapters) { chapter in
            let folded = nav.isCollapsed(tag: tag, chapter: chapter.id)
            chapterHeader(tag, chapter, folded: folded).id(Self.chapterAnchor(chapter))
            if !folded {
                if let id = chapter.taskID { BoardNotesSection(store: store, owner: .task(id)) }
                if chapter.notes.isEmpty {
                    Text("还没有笔记").font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.leading, 4).padding(.bottom, 6)
                }
                ForEach(chapter.notes) { item in noteRow(item, showDate: true) }
            }
        }
    }

    private func chapterHeader(_ tag: String, _ chapter: NotebookChapter, folded: Bool) -> some View {
        let canOpen = chapter.taskID.map { id in store.noteTopic(for: id) != nil } ?? false
        return HStack(spacing: 6) {
            Button { nav.setCollapsed(!folded, tag: tag, chapter: chapter.id) } label: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(folded ? 0 : 90)).frame(width: 16, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Palette.muted)
            .help(folded ? "展开这一章" : "折叠这一章").accessibilityLabel(folded ? "展开章节" : "折叠章节")
            Button { if let id = chapter.taskID, canOpen { select(task: id) } } label: {
                HStack(spacing: 6) {
                    Image(systemName: chapter.taskID == nil ? "square.and.pencil" : (chapter.dropped ? "xmark.circle.fill" : (chapter.completed ? "checkmark.circle.fill" : "circle")))
                        .foregroundStyle(chapter.completed && !chapter.dropped ? Palette.success : Palette.muted).font(.system(size: 12))
                    if let number = chapter.number {
                        Text("#\(number)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                    }
                    Text(chapter.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(chapter.notes.count) 条").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
            .buttonStyle(.plain).foregroundStyle(Palette.accent)
            .help(canOpen ? "只看这个待办的全部笔记" : "")
            Rectangle().fill(Palette.line).frame(height: 1)
        }
        .padding(.top, 14).padding(.bottom, 4)
    }

    private func dateList(_ notes: [JournalStore.LoggedLog]) -> some View {
        ForEach(Dictionary(grouping: notes, by: \.key).sorted { $0.key < $1.key }, id: \.key) { group in
            dayHeader(group.key, date: group.value[0].date)
            ForEach(group.value) { item in noteRow(item, showTask: true) }
        }
    }

    private func tagHeader(_ tag: String, tasks: [ScheduledTask], notes: [JournalStore.LoggedLog]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("#" + tag).font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.accent).lineLimit(2)
                    Text("\(tasks.count) 个待办（\(tasks.filter { !$0.task.completed }.count) 个未完成） · \(notes.count) 条笔记")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Picker("", selection: $nav.chapterView) {
                    Text("按待办").tag(true)
                    Text("按日期").tag(false)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
                BoardOpenButton(store: store, owner: .tag(tag))
                if chapterView {
                    Button { nav.showOutline.toggle() } label: { Image(systemName: "sidebar.right") }
                        .foregroundStyle(nav.showOutline ? Palette.accent : Palette.muted)
                        .help(nav.showOutline ? "隐藏右侧的章节目录" : "显示右侧的章节目录").accessibilityLabel("章节目录")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.markdown(tag: tag, tasks: tasks, notes: notes), forType: .string)
                    error = "已复制为 Markdown"
                } label: { Label("复制为 Markdown", systemImage: "doc.on.doc") }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    /// 标签页底部：直接往这个笔记本里写，不需要关联待办；写 `@` 加几个字（或点上面的关联条）可以记在某个待办（章节）名下。
    private func tagComposer(_ tag: String) -> some View {
        let key = tagDraftKey(tag)
        let pending = images(key)
        let text = nav.draft(key).text
        let link = Binding<UUID?>(get: { nav.draft(key).link }, set: { value in nav.updateDraft(key) { $0.link = value } })
        let unlinked = Binding<Bool>(get: { nav.draft(key).unlinked }, set: { value in nav.updateDraft(key) { $0.unlinked = value } })
        let tags = Binding<[String]>(get: { nav.draft(key).tags }, set: { value in nav.updateDraft(key) { $0.tags = value } })
        return VStack(alignment: .leading, spacing: 6) {
            if !pending.isEmpty {
                PendingImagesStrip(store: store, names: pending,
                                   remove: { name in removeImage(name, from: key) },
                                   preview: { ImageViewerController.shared.show(store: store, names: pending, index: $0) })
            }
            MentionList(state: tagMention, store: store, contextTags: [tag])
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").foregroundStyle(Palette.accent)
                TaskInput(text: textBinding(key), focused: $tagFocused,
                          placeholder: AppLocalizedFormat("写进 #%@…", tag),
                          fontSize: 13, submit: { submitTag(tag) }, onPasteImages: { datas in
                    addImages(ImageTools.save(datas, in: store), to: key)
                    tagFocused = true
                }, minHeight: 24, maxLines: 10, mention: tagMention).disabled(store.isReadOnly)
                Button { submitTag(tag) } label: { Image(systemName: "arrow.turn.down.left") }
                    .buttonStyle(HitAreaButtonStyle())
                    .disabled(store.isReadOnly || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pending.isEmpty))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
            LogChipsBar(store: store, link: link, unlinked: unlinked, tags: tags, contextTags: [tag])
            if let error {
                Text(LocalizedStringKey(error)).font(.system(size: 11)).foregroundStyle(error.hasPrefix("已") ? Palette.success : Palette.deadline)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func submitTag(_ tag: String) {
        let key = tagDraftKey(tag)
        let draft = nav.draft(key)
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !draft.images.isEmpty else { return }
        do {
            let command = try store.quickLog(text, images: draft.images, taskID: draft.link, linkDefault: !draft.unlinked, tags: TagText.merge([tag], draft.tags), on: Date())
            guard case .entry = command else { error = AppLocalizedFormat("这里只能写笔记，不支持 %@ 这类命令。", text); return }
            nav.clearDraft(key)
            error = nil
            tagFocused = true
            ImageIndexer.run(store: store)
        } catch { self.error = AppErrorDescription(error) }
    }

    /// 标签的笔记导出为 Markdown：先列出待办，再按日期分组，每条标明来自哪个待办。
    static func markdown(tag: String, tasks: [ScheduledTask], notes: [JournalStore.LoggedLog]) -> String {
        var lines = ["# #\(tag)", ""]
        for item in tasks {
            lines.append("- [\(item.task.isDone ? "x" : (item.task.isDropped ? "-" : " "))] \(item.task.number.map { "#\($0) " } ?? "")\(String(TaskText.rendered(item.task.title).characters))")
        }
        if !tasks.isEmpty { lines.append("") }
        for group in Dictionary(grouping: notes, by: \.key).sorted(by: { $0.key < $1.key }) {
            lines.append("## \(group.key)")
            for item in group.value {
                let log = item.log
                let source = sourceLabel(log).map { "（\($0)）" } ?? ""
                var line = "- \(time(log.createdAt)) [\(log.focusMarker)] \(String(TaskText.rendered(log.copyText ?? log.text).characters).replacingOccurrences(of: "\n", with: "\n  "))\(source)"
                for name in log.images { line += "\n  ![](Images/\(name))" }
                lines.append(line)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func composer(_ topic: JournalStore.NoteTopic) -> some View {
        let key = taskDraftKey(topic.id)
        let pending = images(key)
        let text = nav.draft(key).text
        let tags = Binding<[String]>(get: { nav.draft(key).tags }, set: { value in nav.updateDraft(key) { $0.tags = value } })
        return VStack(alignment: .leading, spacing: 6) {
            if !pending.isEmpty {
                PendingImagesStrip(store: store, names: pending,
                                   remove: { name in removeImage(name, from: key) },
                                   preview: { ImageViewerController.shared.show(store: store, names: pending, index: $0) })
            }
            MentionList(state: taskMention, store: store)
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").foregroundStyle(Palette.accent)
                TaskInput(text: textBinding(key), focused: $focused,
                          placeholder: topic.deleted ? AppLocalized("任务已删除，无法追加笔记") : AppLocalized("追加笔记…"),
                          fontSize: 13, submit: { submit(topic) }, onPasteImages: { datas in
                    addImages(ImageTools.save(datas, in: store), to: key)
                    focused = true
                }, minHeight: 24, maxLines: 10, mention: taskMention).disabled(topic.deleted || store.isReadOnly)
                Button { submit(topic) } label: { Image(systemName: "arrow.turn.down.left") }
                    .buttonStyle(HitAreaButtonStyle())
                    .disabled(topic.deleted || store.isReadOnly || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pending.isEmpty))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
            LogChipsBar(store: store, link: .constant(nil), unlinked: .constant(false), tags: tags, showsLink: false)
            if let error {
                Text(LocalizedStringKey(error)).font(.system(size: 11)).foregroundStyle(error.hasPrefix("已") ? Palette.success : Palette.deadline)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func submit(_ topic: JournalStore.NoteTopic) {
        let key = taskDraftKey(topic.id)
        let draft = nav.draft(key)
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !draft.images.isEmpty else { return }
        do {
            let command = try store.quickLog(text, images: draft.images, taskID: topic.id, tags: draft.tags, on: Date())
            guard case .entry = command else { error = AppLocalizedFormat("这里只能写笔记，不支持 %@ 这类命令。", text); return }
            nav.clearDraft(key)
            error = nil
            focused = true
            ImageIndexer.run(store: store)
        } catch { self.error = AppErrorDescription(error) }
    }

    private static func time(_ date: Date) -> String {
        LogEventStyle.time(date)
    }

    /// 笔记导出为 Markdown：按日期分组，图片引用 Images 文件夹里的文件名。
    static func markdown(_ topic: JournalStore.NoteTopic, notes: [JournalStore.LoggedLog]) -> String {
        var lines = ["# \(topic.number.map { "#\($0) " } ?? "")\(topic.title)", ""]
        for group in Dictionary(grouping: notes, by: \.key).sorted(by: { $0.key < $1.key }) {
            lines.append("## \(group.key)")
            for item in group.value {
                let log = item.log
                var line = "- \(time(log.createdAt)) [\(log.focusMarker)] \(String(TaskText.rendered(log.copyText ?? log.text).characters).replacingOccurrences(of: "\n", with: "\n  "))"
                for name in log.images { line += "\n  ![](Images/\(name))" }
                lines.append(line)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

/// 创建流程与侧栏列表分开，提交时列表刷新不会销毁正在处理回车的输入框。
struct CreateNotebookTagView: View {
    @ObservedObject var store: JournalStore
    let cancel: () -> Void
    let created: (String) -> Void
    @State private var name = ""
    @State private var message: String?
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("新建标签").font(.headline)
            TextField("标签名称", text: $name).textFieldStyle(.roundedBorder).onSubmit(submit)
            if let message { Text(LocalizedStringKey(message)).font(.caption).foregroundStyle(.orange) }
            Text("用 / 分层").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("创建", action: submit).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(submitting || store.isReadOnly)
            }
        }.padding(16).frame(width: 300)
    }

    private func submit() {
        guard !submitting, !store.isReadOnly else { return }
        guard let normalized = TagText.normalize(name) else {
            message = "标签不能为空、含空格，或是纯数字（#3 表示任务编号）"
            return
        }
        submitting = true
        // 离开 NSTextField 的回车事件 / SwiftUI 按钮事务后再更新列表、保存并关闭弹窗。
        DispatchQueue.main.async {
            guard let tag = store.createTag(normalized) else { submitting = false; return }
            created(tag)
        }
    }
}
