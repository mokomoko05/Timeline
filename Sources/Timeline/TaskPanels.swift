import AppKit
import SwiftUI
import TimelineCore
import UniformTypeIdentifiers

struct TaskDetailsView: View {
    @ObservedObject var store: JournalStore
    let task: Todo
    /// 任务当前存放的日期（内部存储位置），保存时原样带回，不影响显示和截止日期。
    private let home: Date
    @EnvironmentObject private var reminders: ReminderScheduler
    @Environment(\.dismiss) private var dismiss
    @State private var hasDue: Bool
    @State private var timing: TaskTimeDraft
    @State private var reminder: Int
    @State private var recurrence: RepeatRule
    @State private var saving = false
    @State private var calendarName: String
    @State private var priority: TaskPriority

    init(store: JournalStore, task: Todo, date: Date) {
        self.store = store
        self.task = task
        self.home = date
        _hasDue = State(initialValue: task.dueDate != nil)
        _timing = State(initialValue: TaskTimeDraft(task: task))
        _reminder = State(initialValue: task.reminderMinutes ?? -1)
        _recurrence = State(initialValue: task.repeatRule)
        _calendarName = State(initialValue: task.calendarName)
        _priority = State(initialValue: task.priority)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(TaskText.rendered(task.title).characters)).font(.headline).lineLimit(3)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("优先级")
                        Spacer()
                        Picker("优先级", selection: $priority) {
                            ForEach(TaskPriority.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                        }.pickerStyle(.menu).labelsHidden().frame(width: 190)
                    }
                    HStack {
                        Text("月历短名称")
                        TextField("", text: $calendarName, prompt: Text("留空使用原标题")).textFieldStyle(.roundedBorder)
                    }
                    Divider()
                    Toggle("设置任务时间", isOn: $hasDue)
                    if hasDue {
                        TaskTimeSelectionView(timing: $timing).frame(maxWidth: .infinity)
                        HStack {
                            Text("提醒")
                            Spacer()
                            Picker("提醒", selection: $reminder) {
                                Text("不提醒").tag(-1)
                                Text(timing.mode == .interval ? "开始时" : (timing.hasTime ? "截止时" : "当天 09:00")).tag(0)
                                Text("提前 15 分钟").tag(15)
                                Text("提前 30 分钟").tag(30)
                                Text("提前 1 小时").tag(60)
                                Text("提前 1 天").tag(1440)
                            }.pickerStyle(.menu).labelsHidden().frame(width: 190)
                        }
                    }
                    HStack {
                        Text("重复")
                        Spacer()
                        Picker("重复", selection: $recurrence) {
                            ForEach(RepeatRule.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                        }.pickerStyle(.menu).labelsHidden().frame(width: 190)
                    }
                    if recurrence != .none { Text("完成后生成下一次").font(.caption).foregroundStyle(Palette.muted) }
                }
                .font(.system(size: 12)).padding(.trailing, 6).disabled(store.isReadOnly)
            }.frame(height: hasDue ? 540 : 150)
            if !reminders.status.isEmpty { Text(reminders.status).font(.caption).foregroundStyle(Palette.deadline) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    saving = true
                    Task { @MainActor in
                        if hasDue && reminder >= 0 { _ = await reminders.requestPermission() }
                        store.updateTodo(task.id, scheduledDate: home, dueDate: hasDue ? timing.end : nil,
                                         dueHasTime: timing.hasTime, reminderMinutes: reminder < 0 ? nil : reminder, repeatRule: recurrence,
                                         calendarName: calendarName, priority: priority, startDate: .some(hasDue ? timing.startDate : nil))
                        reminders.refresh()
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || store.isReadOnly || (hasDue && !timing.isValid))
            }
        }
        .padding(20).frame(width: 430).foregroundStyle(Palette.ink).background(Palette.background)
    }
}

struct AgendaView: View {
    @Environment(\.typography) private var typography
    @ObservedObject var store: JournalStore
    let navigate: (Date?, UUID?) -> Void
    /// 打开日记并定位到某条日志。没有时退回到只打开那一天。
    var openLog: ((Date, UUID) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State var filter: AgendaFilter
    @State private var query = ""
    @State private var requestedEdit: UUID?
    @State private var hits: [SearchHit] = []
    @State private var selection = 0
    @FocusState private var searching: Bool

    enum SearchHit: Identifiable {
        case task(ScheduledTask)
        case log(key: String, entry: DailyLogEntry)
        case summary(key: String, text: String)
        /// 工作板正文里的匹配：带上第一处命中的那一行。
        case board(Board, line: String)

        var id: String {
            switch self {
            case .task(let item): return "task-\(item.id)"
            case .log(_, let entry): return "log-\(entry.id)"
            case .summary(let key, _): return "summary-\(key)"
            case .board(let board, _): return "board-\(board.id)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField("搜索任务、日志、工作板…", text: $query).textFieldStyle(.plain).font(.system(size: typography.pt(15))).focused($searching)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted).accessibilityLabel("清除搜索词")
                }
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
            PillSegmentedControl(selection: $filter, segments: AgendaFilter.allCases.map { .init(value: $0, title: $0.title) },
                                 fillsWidth: true, height: 28)
                .accessibilityLabel("范围")
            HStack {
                Text(hits.isEmpty ? " " : AppLocalizedFormat("%lld 条结果", hits.count)).font(.caption).foregroundStyle(Palette.muted)
                Spacer()
                Text("↑ ↓ 选择 · 回车跳转 · Esc 关闭").font(.caption).foregroundStyle(Palette.muted)
            }
            if hits.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: query.isEmpty ? "tray" : "magnifyingglass").font(.system(size: typography.pt(28), weight: .light)).foregroundStyle(Palette.muted.opacity(0.6))
                    Text(query.isEmpty ? AppLocalized("暂无事项") : AppLocalizedFormat("没有找到「%@」", query)).font(.system(size: typography.pt(14), weight: .medium))
                    if !query.isEmpty, filter != .all {
                        Button("在全部事项中搜索") { filter = .all }.buttonStyle(HitAreaButtonStyle()).foregroundStyle(Palette.accent)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                                row(hit).padding(4)
                                    .background(index == selection ? Palette.soft : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                    .id(hit.id)
                            }
                        }
                    }
                    .onChange(of: selection) { index in
                        if hits.indices.contains(index) { proxy.scrollTo(hits[index].id) }
                    }
                }
            }
        }
        .padding(24).frame(minWidth: 700, minHeight: 540)
        .background(SearchKeyCatcher(move: moveSelection, activate: activate))
        .onAppear { searching = true; recompute() }
        .onChange(of: query) { _ in selection = 0; recompute() }
        .onChange(of: filter) { _ in selection = 0; recompute() }
        .onReceive(store.$days.debounce(for: .milliseconds(300), scheduler: RunLoop.main)) { _ in recompute() }
    }

    @ViewBuilder
    private func row(_ hit: SearchHit) -> some View {
        switch hit {
        case .task(let item):
            HStack(alignment: .top, spacing: 16) {
                Button { navigate(item.task.dueDate, item.id); dismiss() } label: {
                    Text(item.task.dueDate.map { $0.formatted(.dateTime.month().day().locale(AppLanguage.current.locale)) } ?? AppLocalized("未设日期")).font(.caption).frame(width: 70)
                }.buttonStyle(HitAreaButtonStyle()).foregroundStyle(Palette.accent)
                ManagedTaskRow(store: store, date: item.date, task: item.task, requestedEdit: $requestedEdit)
            }
        case .log(let key, let entry):
            // 日志结果也画在一根线上：珠子颜色表示类型，日期和时间是淡淡的说明行，正文高亮关键词。
            Button { open(key, log: entry.id) } label: {
                HStack(alignment: .top, spacing: 10) {
                    ZStack(alignment: .top) {
                        Rectangle().fill(Palette.line.opacity(0.6)).frame(width: 1).frame(maxHeight: .infinity)
                        Circle().fill(LogEventStyle.color(entry)).frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(Palette.background, lineWidth: 1.5))
                            .padding(.top, 4)
                    }
                    .frame(width: NoteThread.gutter)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text((JournalDates.date(for: key)?.relativeLabel ?? key) + " " + NoteThread.shortTime(entry.createdAt))
                            if let kind = NoteThread.kindLabel(entry) { Text(kind).foregroundStyle(LogEventStyle.color(entry)) }
                            if let title = entry.taskTitle { Text(title).foregroundStyle(Palette.accent).lineLimit(1) }
                        }
                        .font(.system(size: typography.pt(11))).monospacedDigit().foregroundStyle(Palette.muted)
                        Text(highlighted(String(TaskText.rendered(LogEventStyle.body(entry)).characters)))
                            .font(.system(size: typography.pt(13))).foregroundStyle(Palette.ink).lineLimit(3)
                        if let line = recognizedLine(entry) {
                            Text(highlighted(line)).font(.system(size: typography.pt(11))).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(HitAreaButtonStyle())
        case .board(let board, let line):
            Button { openBoard(board) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet.rectangle")
                        Text(store.boardTitle(board)).lineLimit(1)
                        Text("工作板").foregroundStyle(Palette.muted)
                    }
                    .font(.caption).foregroundStyle(Palette.accent)
                    Text(highlighted(line)).font(.system(size: typography.pt(13))).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(HitAreaButtonStyle())
        case .summary(let key, let text):
            Button { open(key) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(key) · 每日总结").font(.caption).foregroundStyle(Palette.accent)
                    Text(highlighted(text)).font(.system(size: typography.pt(13))).lineLimit(4)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(HitAreaButtonStyle())
        }
    }

    /// 关键词只出现在图片文字里时，显示命中的那一行，说明为什么搜到了它。
    private func recognizedLine(_ entry: DailyLogEntry) -> String? {
        guard !query.isEmpty, !entry.text.localizedStandardContains(query) else { return nil }
        return entry.recognizedText.components(separatedBy: .newlines).first { $0.localizedStandardContains(query) }.map { "图片中的文字：" + $0 }
    }

    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !query.isEmpty else { return attributed }
        var from = text.startIndex
        while from < text.endIndex, let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
            if let lower = AttributedString.Index(range.lowerBound, within: attributed),
               let upper = AttributedString.Index(range.upperBound, within: attributed) {
                attributed[lower..<upper].backgroundColor = Palette.accent.opacity(0.28)
            }
            from = range.upperBound
        }
        return attributed
    }

    private func recompute() {
        let result = Self.searchHits(store: store, query: query, filter: filter)
        hits = result
        selection = min(selection, max(0, result.count - 1))
    }

    /// 搜索结果：待办在前，然后是工作板正文、日志和每日总结。
    static func searchHits(store: JournalStore, query: String, filter: AgendaFilter) -> [SearchHit] {
        var result = store.tasks(matching: query, filter: filter).map(SearchHit.task)
        if let tag = TagText.searchTag(query) {
            // 「#标签」：带这个标签的待办，加上它们名下的日志（含待办已删除的）。
            result += store.logs(forTag: tag).map { SearchHit.log(key: $0.key, entry: $0.log) }
        } else if !query.isEmpty {
            for board in store.boards where !board.archived {
                guard let line = board.markdown.components(separatedBy: .newlines).first(where: { $0.localizedStandardContains(query) }) else { continue }
                result.append(.board(board, line: line.trimmingCharacters(in: .whitespaces)))
            }
            for key in store.days.keys.sorted() {
                guard let day = store.days[key] else { continue }
                for log in day.logs where log.searchableText.localizedStandardContains(query) || log.taskTitle?.localizedStandardContains(query) == true || log.taskTags.contains(where: { $0.localizedStandardContains(query) }) || log.tags.contains(where: { $0.localizedStandardContains(query) }) {
                    result.append(.log(key: key, entry: log))
                }
                if day.summary.localizedStandardContains(query) { result.append(.summary(key: key, text: day.summary)) }
                if result.count > 300 { break }
            }
        }
        return result
    }

    private func open(_ key: String, log: UUID? = nil) {
        guard let date = JournalDates.date(for: key) else { return }
        if let log, let openLog { openLog(date, log) } else { navigate(date, nil) }
        dismiss()
    }

    private func openBoard(_ board: Board) {
        dismiss()
        let line = board.markdown.components(separatedBy: .newlines).firstIndex { $0.localizedStandardContains(query) }
        BoardWindowController.shared.show(store: store, owner: board.owner, revealLine: line.map { $0 + 1 }, query: query)
    }

    private func moveSelection(_ amount: Int) {
        guard !hits.isEmpty else { return }
        selection = min(max(selection + amount, 0), hits.count - 1)
    }

    private func activate() {
        guard hits.indices.contains(selection) else { return }
        switch hits[selection] {
        case .task(let item): navigate(item.task.dueDate, item.id); dismiss()
        case .log(let key, let entry): open(key, log: entry.id)
        case .summary(let key, _): open(key, log: JournalDates.date(for: key).map(InlineMarkdownEditor.summaryID(for:)))
        case .board(let board, _): openBoard(board)
        }
    }
}

/// 搜索框里用方向键和回车操作结果列表；输入法组词时不拦截。
struct SearchKeyCatcher: NSViewRepresentable {
    let move: (Int) -> Void
    let activate: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.install()
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.move = move
        view.activate = activate
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) { view.remove() }

    final class CatcherView: NSView {
        var move: ((Int) -> Void)?
        var activate: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window, event.window === window, !isHiddenOrHasHiddenAncestor,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return event }
                switch event.keyCode {
                case 126: move?(-1)
                case 125: move?(1)
                case 36, 76: activate?()
                default: return event
                }
                return nil
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

struct BackupRestoreView: View {
    @ObservedObject var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var selected: URL?
    @State private var preview: BackupPreview?
    @State private var error: String?
    @State private var confirming = false
    @State private var importedImagesFolder: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("备份与恢复").font(.title2)
                Spacer()
                Button("导入备份…") { importing = true }.help("选择导出的备份文件夹，或单个 JSON 文件")
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("自动保留最近 30 天的每日快照。恢复前另存当前记录。").font(.caption).foregroundStyle(Palette.muted)
            List(store.backups()) { backup in
                Button { inspect(backup.url) } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(backup.url.lastPathComponent).lineLimit(1)
                            Text(backup.date, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        if selected == backup.url { Image(systemName: "checkmark") }
                    }
                }.buttonStyle(HitAreaButtonStyle())
            }
            if let preview {
                Text("\(preview.dayCount) 天 · \(preview.taskCount) 条事项 · \(preview.logCount) 条日志 · \(preview.summaryCount) 篇总结").font(.callout)
            }
            if let error { Text(error).font(.caption).foregroundStyle(Palette.danger) }
            HStack { Spacer(); Button("恢复所选备份") { confirming = true }.disabled(preview == nil) }
        }
        .padding(24).frame(width: 650, height: 500)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .folder]) { result in
            do {
                let picked = try result.get()
                let access = picked.startAccessingSecurityScopedResource()
                defer { if access { picked.stopAccessingSecurityScopedResource() } }
                // 导出的文件夹里是 journal.json 加 Images；也可以直接选单个 JSON。
                let isFolder = (try? picked.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                let url = isFolder ? picked.appendingPathComponent("journal.json") : picked
                _ = try store.inspectBackup(url)
                let local = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-import-\(UUID().uuidString).json")
                try Data(contentsOf: url).write(to: local, options: .atomic)
                importedImagesFolder = isFolder ? picked : nil
                inspect(local)
            } catch { self.error = error.localizedDescription }
        }
        .alert("恢复这份备份？", isPresented: $confirming) {
            Button("取消", role: .cancel) {}
            Button("恢复") {
                guard let selected else { return }
                do {
                    if let folder = importedImagesFolder { try store.importImages(from: folder) }
                    try store.restore(from: selected)
                    ImageIndexer.run(store: store)
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
        } message: { Text("当前记录将被替换，恢复前会自动另存一份备份。") }
    }

    private func inspect(_ url: URL) {
        if !url.lastPathComponent.hasPrefix("timeline-import-") { importedImagesFolder = nil }
        do { preview = try store.inspectBackup(url); selected = url; error = nil }
        catch { preview = nil; selected = nil; self.error = error.localizedDescription }
    }
}
