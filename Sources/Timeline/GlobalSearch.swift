import AppKit
import Combine
import SwiftUI
import TimelineCore

/// 全局搜索的一条结果：说清楚是什么、在哪，以及点开后跳到哪里（具体到那一行 / 那一条）。
struct GlobalSearchHit: Identifiable, Equatable {
    enum Kind: Equatable { case task, board, log, image, summary }

    enum Target: Equatable {
        case task(UUID)
        /// 工作板里的第几行（从 1 开始）。
        case board(BoardOwner, line: Int)
        /// 有关联待办的日志在笔记里打开（定位到这一条）；没有的在日记里打开。
        case log(date: Date, id: UUID, taskID: UUID?)
        case summary(Date)
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let target: Target
    var completed = false
    /// 文字在图片里时，命中的那张图。
    var image: URL?
}

enum GlobalSearchScope: String, CaseIterable, Identifiable {
    case all, tasks, boards, logs, images
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .tasks: return "待办"
        case .boards: return "工作板"
        case .logs: return "日志与笔记"
        case .images: return "图片文字"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .tasks: return "checklist"
        case .boards: return "list.bullet.rectangle"
        case .logs: return "text.bubble"
        case .images: return "text.viewfinder"
        }
    }

    func includes(_ kind: GlobalSearchHit.Kind) -> Bool {
        switch self {
        case .all: return true
        case .tasks: return kind == .task
        case .boards: return kind == .board
        case .logs: return kind == .log || kind == .summary
        case .images: return kind == .image
        }
    }
}

@MainActor
enum GlobalSearch {
    static let boardLinesPerBoard = 4
    static let limit = 300

    /// 待办在前，然后是工作板的命中行、日志（新的在前，文字在图片里的单列）、每日总结。
    static func hits(store: JournalStore, query raw: String) -> [GlobalSearchHit] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var result: [GlobalSearchHit] = store.tasks(matching: query).sorted { lhs, rhs in
            lhs.task.completed != rhs.task.completed ? !lhs.task.completed : (lhs.task.dueDate ?? .distantFuture) < (rhs.task.dueDate ?? .distantFuture)
        }.prefix(80).map { item in
            var detail = item.task.dueDate.map { AppLocalizedFormat("截止 %@", $0.relativeLabel) } ?? AppLocalized("未设日期")
            if !item.task.tags.isEmpty { detail += " · " + item.task.tags.map { "#" + $0 }.joined(separator: " ") }
            return GlobalSearchHit(id: "task-\(item.id)", kind: .task, title: String(TaskText.rendered(item.task.title).characters),
                                   detail: detail, target: .task(item.id), completed: item.task.completed)
        }
        if let tag = TagText.searchTag(query) {
            for item in store.logs(forTag: tag).reversed() { result.append(logHit(item.log, key: item.key, store: store, query: nil)) }
            return Array(result.prefix(limit))
        }
        for board in store.boards where !board.archived {
            var found = 0
            for (index, line) in board.markdown.components(separatedBy: .newlines).enumerated() where line.localizedStandardContains(query) {
                result.append(GlobalSearchHit(id: "board-\(board.id)-\(index)", kind: .board, title: readable(line),
                                              detail: AppLocalizedFormat("%@ · 第 %lld 行", store.boardTitle(board), index + 1),
                                              target: .board(board.owner, line: index + 1)))
                found += 1
                if found == boardLinesPerBoard { break }
            }
        }
        var summaries: [GlobalSearchHit] = []
        for key in store.days.keys.sorted(by: >) {
            guard let day = store.days[key] else { continue }
            for log in day.logs.sorted(by: { $0.createdAt > $1.createdAt }) {
                let inText = [log.text, log.focusGoal ?? "", log.taskTitle ?? ""].contains { $0.localizedStandardContains(query) }
                    || log.tags.contains { $0.localizedStandardContains(query) } || log.taskTags.contains { $0.localizedStandardContains(query) }
                if inText {
                    result.append(logHit(log, key: key, store: store, query: nil, matchQuery: query))
                } else if log.recognizedText.localizedStandardContains(query) {
                    result.append(logHit(log, key: key, store: store, query: query))
                }
            }
            if let date = JournalDates.date(for: key), day.summary.localizedStandardContains(query) {
                let line = day.summary.components(separatedBy: .newlines).first { $0.localizedStandardContains(query) } ?? day.summary
                summaries.append(GlobalSearchHit(id: "summary-\(key)", kind: .summary, title: readable(line),
                                                 detail: AppLocalizedFormat("%@ · 每日总结", date.relativeLabel), target: .summary(date)))
            }
            if result.count > limit { break }
        }
        return Array((result + summaries).prefix(limit))
    }

    /// `query` 不为空：文字只在图片里，标题换成图片中命中的那一行，并带上那张图。
    private static func logHit(_ log: DailyLogEntry, key: String, store: JournalStore, query: String?, matchQuery: String? = nil) -> GlobalSearchHit {
        let date = JournalDates.date(for: key) ?? log.createdAt
        var detail = date.relativeLabel + " " + NoteThread.shortTime(log.createdAt)
        if let title = log.taskTitle { detail += " · " + title }
        let target = GlobalSearchHit.Target.log(date: date, id: log.id, taskID: log.taskID.flatMap { store.locate($0) == nil ? nil : $0 })
        if let query {
            let image = log.images.first { log.imageText[$0]?.localizedStandardContains(query) == true }
            let line = image.flatMap { log.imageText[$0] }?.components(separatedBy: .newlines).first { $0.localizedStandardContains(query) } ?? ""
            return GlobalSearchHit(id: "image-\(log.id)", kind: .image, title: line.trimmingCharacters(in: .whitespaces),
                                   detail: detail, target: target, image: image.map(store.imageURL))
        }
        return GlobalSearchHit(id: "log-\(log.id)", kind: .log, title: excerpt(LogEventStyle.body(log), query: matchQuery),
                               detail: detail, target: target)
    }

    /// 多行正文只显示命中的那一行（没有就第一行非空的），去掉 Markdown 记号。
    static func excerpt(_ text: String, query: String?) -> String {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let line = query.flatMap { query in lines.first { $0.localizedStandardContains(query) } } ?? lines.first ?? ""
        let readable = String(TaskText.rendered(readable(line)).characters)
        return readable.isEmpty ? AppLocalized("图片") : readable
    }

    /// 工作板的一行：去掉缩进和 Markdown 的行首记号，读起来像正文。
    static func readable(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        for pattern in [#"^#{1,6}\s+"#, #"^>\s*"#, #"^[-+*]\s+\[[ xX]\]\s+"#, #"^[-+*]\s+"#, #"^\d+[.)]\s+"#] {
            if let range = text.range(of: pattern, options: .regularExpression) { text.removeSubrange(range); break }
        }
        return text.replacingOccurrences(of: #"</?(summary|details)[^>]*>"#, with: "", options: .regularExpression)
    }
}

@MainActor
final class GlobalSearchModel: ObservableObject {
    @Published var query = ""
    @Published var scope: GlobalSearchScope = .all
    @Published private(set) var allHits: [GlobalSearchHit] = []
    @Published var selection = 0
    /// 每次呼出加一：视图据此把光标放回输入框、播放出现动画。
    @Published private(set) var presentation = 0
    weak var store: JournalStore? { didSet { if store !== oldValue { observe() } } }
    private var cancellables: Set<AnyCancellable> = []
    private var storeChanges: AnyCancellable?

    init() {
        $query.removeDuplicates().debounce(for: .milliseconds(90), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.recompute(resetSelection: true) }.store(in: &cancellables)
        $scope.dropFirst().sink { [weak self] _ in self?.selection = 0 }.store(in: &cancellables)
    }

    var hits: [GlobalSearchHit] { scope == .all ? allHits : allHits.filter { scope.includes($0.kind) } }

    func count(_ scope: GlobalSearchScope) -> Int { scope == .all ? allHits.count : allHits.filter { scope.includes($0.kind) }.count }

    func presented() { presentation += 1 }

    func recompute(resetSelection: Bool = false) {
        guard let store else { allHits = []; return }
        allHits = GlobalSearch.hits(store: store, query: query)
        if resetSelection { selection = 0 } else { selection = min(selection, max(0, hits.count - 1)) }
    }

    func move(_ amount: Int) {
        let count = hits.count
        guard count > 0 else { return }
        selection = min(max(selection + amount, 0), count - 1)
    }

    func cycleScope(_ amount: Int) {
        let all = GlobalSearchScope.allCases
        let index = all.firstIndex(of: scope) ?? 0
        withAnimation(Motion.reduced ? nil : .spring(response: 0.3, dampingFraction: 0.82)) {
            scope = all[(index + amount + all.count) % all.count]
        }
    }

    /// 面板开着时数据变了（别处改了、图片文字识别好了）也跟着刷新。
    private func observe() {
        storeChanges = store?.objectWillChange.debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.query.isEmpty, GlobalSearchController.shared.isVisible else { return }
                self.recompute()
            }
    }
}

// MARK: - 面板

private final class GlobalSearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// 全局搜索：像 Spotlight 一样浮在屏幕上方，不用先打开主窗口。菜单栏、全局快捷键和 ⌘F 都打开它。
@MainActor
final class GlobalSearchController: NSObject, NSWindowDelegate {
    static let shared = GlobalSearchController()
    let model = GlobalSearchModel()
    private var panel: GlobalSearchPanel?
    private weak var store: JournalStore?
    static let width: CGFloat = 660
    static let compactHeight: CGFloat = 132
    static let expandedHeight: CGFloat = 520

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(store: JournalStore) {
        if isVisible { close() } else { show(store: store) }
    }

    func show(store: JournalStore) {
        self.store = store
        model.store = store
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.recompute()
        let height = model.query.isEmpty ? Self.compactHeight : Self.expandedHeight
        panel.setFrame(frame(height: height, screen: NSScreen.main), display: false)
        model.presented()
        if Headless.active { panel.alphaValue = 0; panel.ignoresMouseEvents = true }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func makePanel() -> GlobalSearchPanel {
        let view = GlobalSearchView(model: model, open: { [weak self] in self?.open($0) }, close: { [weak self] in self?.close() },
                                    resize: { [weak self] expanded in self?.resize(expanded: expanded) })
        let host = NSHostingView(rootView: LocalizedRoot { view })
        host.sizingOptions = []
        let panel = GlobalSearchPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.compactHeight),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        return panel
    }

    /// 屏幕上方偏中的位置，和 Spotlight 差不多；顶边固定，结果多了向下展开。
    private func frame(height: CGFloat, screen: NSScreen?) -> NSRect {
        let visible = (screen ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let top = visible.maxY - visible.height * 0.18
        return NSRect(x: visible.midX - Self.width / 2, y: top - height, width: Self.width, height: height)
    }

    private func resize(expanded: Bool) {
        guard let panel else { return }
        let height = expanded ? Self.expandedHeight : Self.compactHeight
        guard abs(panel.frame.height - height) > 0.5 else { return }
        var target = panel.frame
        target.origin.y += target.height - height
        target.size.height = height
        if Motion.reduced || Headless.active || !panel.isVisible {
            panel.setFrame(target, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        }
    }

    /// 点到别处就收起，和 Spotlight 一样。
    func windowDidResignKey(_ notification: Notification) {
        guard !Headless.active else { return }
        close()
    }

    func open(_ hit: GlobalSearchHit) {
        guard let store else { return }
        close()
        switch hit.target {
        case .task(let id):
            AppRouter.presentMain()
            NotificationCenter.default.post(name: .timelineReveal, object: id)
        case .board(let owner, let line):
            BoardWindowController.shared.show(store: store, owner: owner, revealLine: line, query: model.query)
        case .log(let date, let id, let taskID):
            if let taskID {
                NotesWindowController.shared.nav.revealNote = id
                AppRouter.openNotes(taskID)
            } else {
                AppRouter.openLog(date, id)
            }
        case .summary(let date):
            AppRouter.openJournal(date)
        }
    }
}

// MARK: - 界面

struct GlobalSearchView: View {
    @ObservedObject var model: GlobalSearchModel
    let open: (GlobalSearchHit) -> Void
    let close: () -> Void
    let resize: (Bool) -> Void
    @FocusState private var focused: Bool
    @Namespace private var selectionSpace
    @State private var appeared = false
    @Environment(\.colorScheme) private var scheme

    private var expanded: Bool { !model.query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(spacing: 0) {
            field
            scopes
            if expanded {
                Divider().overlay(Palette.line.opacity(0.4)).padding(.horizontal, 14)
                results
                footer
            } else {
                hint
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SearchGlass(radius: 16))
        .clipShape(shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.3 : 0.9), Palette.line.opacity(0.45)],
                                                   startPoint: .top, endPoint: .bottom), lineWidth: Metrics.hairline)
            .allowsHitTesting(false))
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .scaleEffect(appeared ? 1 : 0.97, anchor: .top)
        .opacity(appeared ? 1 : 0)
        .background(SearchPanelKeys(move: model.move, activate: activateSelection, cycle: model.cycleScope))
        .onChange(of: expanded) { resize($0) }
        .onChange(of: model.presentation) { _ in present() }
        .onAppear { present() }
    }

    private func present() {
        appeared = false
        withAnimation(Motion.reduced ? nil : .spring(response: 0.28, dampingFraction: 0.86)) { appeared = true }
        focused = true
        // 复用的面板里焦点状态可能没变：下一轮把光标放回输入框，并全选上次的搜索词，直接打字就是新的搜索。
        DispatchQueue.main.async {
            focused = true
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }

    private func activateSelection() {
        let hits = model.hits
        guard hits.indices.contains(model.selection) else { return }
        open(hits[model.selection])
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.accent)
            TextField("搜索待办、工作板、日志、图片里的文字…", text: $model.query)
                .textFieldStyle(.plain).font(.system(size: 18, weight: .regular)).focused($focused)
            if !model.query.isEmpty {
                Button { model.query = ""; focused = true } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(Palette.muted)
                }
                .buttonStyle(PressScaleStyle(scale: 0.88)).help("清除搜索词").accessibilityLabel("清除搜索词")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            KeyCap("esc")
        }
        .padding(.horizontal, 18).frame(height: 54)
        .animation(Motion.quick, value: model.query.isEmpty)
    }

    private var scopes: some View {
        PillSegmentedControl(selection: $model.scope, segments: GlobalSearchScope.allCases.map { scope in
            .init(value: scope, title: scope.title, symbol: scope.symbol, count: expanded ? model.count(scope) : nil)
        }, height: 28, fontSize: 11.5, onGlass: true)
        .padding(.horizontal, 14).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hint: some View {
        HStack(spacing: 14) {
            Label("#标签 只找这个标签", systemImage: "number")
            Label("截图里的字也能搜到", systemImage: "text.viewfinder")
            Spacer()
            Text("⇥ 切换范围")
        }
        .font(.system(size: 11)).foregroundStyle(Palette.muted)
        .padding(.horizontal, 18).padding(.bottom, 12)
    }

    private var results: some View {
        let hits = model.hits
        return Group {
            if hits.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 28, weight: .light)).foregroundStyle(Palette.muted.opacity(0.7))
                    Text(AppLocalizedFormat("没有找到「%@」", model.query)).font(.system(size: 14, weight: .medium))
                    if model.scope != .all, model.count(.all) > 0 {
                        Button(AppLocalizedFormat("在全部结果中查看（%lld）", model.count(.all))) { model.scope = .all }
                            .buttonStyle(HitAreaButtonStyle()).foregroundStyle(Palette.accent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                                if index == 0 || hits[index - 1].kind != hit.kind { sectionHeader(hit.kind, first: index == 0) }
                                GlobalSearchRow(hit: hit, query: model.query, selected: index == model.selection, namespace: selectionSpace)
                                    .id(hit.id)
                                    .onTapGesture { open(hit) }
                                    .onHover { if $0 { model.selection = index } }
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                    .onChange(of: model.selection) { index in
                        guard hits.indices.contains(index) else { return }
                        proxy.scrollTo(hits[index].id)
                    }
                    .onChange(of: model.scope) { _ in if let first = model.hits.first { proxy.scrollTo(first.id, anchor: .top) } }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func sectionHeader(_ kind: GlobalSearchHit.Kind, first: Bool) -> some View {
        let title: String = {
            switch kind {
            case .task: return "待办"
            case .board: return "工作板"
            case .log: return "日志与笔记"
            case .image: return "图片里的文字"
            case .summary: return "每日总结"
            }
        }()
        return Text(LocalizedStringKey(title)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.muted)
            .textCase(.uppercase).tracking(0.4)
            .padding(.horizontal, 10).padding(.top, first ? 2 : 10).padding(.bottom, 3)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) { KeyCap("↑"); KeyCap("↓"); Text("选择") }
            HStack(spacing: 4) { KeyCap("↩"); Text("打开并定位") }
            HStack(spacing: 4) { KeyCap("⇥"); Text("切换范围") }
            Spacer()
            Text(AppLocalizedFormat("%lld 条结果", model.hits.count)).monospacedDigit()
        }
        .font(.system(size: 11)).foregroundStyle(Palette.muted)
        .padding(.horizontal, 16).frame(height: 34)
        .background(Palette.background.opacity(scheme == .dark ? 0.18 : 0.22))
        .overlay(alignment: .top) { Rectangle().fill(Palette.line.opacity(0.35)).frame(height: Metrics.hairline) }
    }
}

private struct GlobalSearchRow: View {
    let hit: GlobalSearchHit
    let query: String
    let selected: Bool
    let namespace: Namespace.ID
    @State private var thumbnail: NSImage?
    @Environment(\.colorScheme) private var scheme

    private var tint: Color {
        switch hit.kind {
        case .task: return Palette.accent
        case .board: return Palette.attention
        case .log: return Palette.note
        case .image: return Palette.success
        case .summary: return Palette.deadline
        }
    }

    private var symbol: String {
        switch hit.kind {
        case .task: return hit.completed ? "checkmark.circle" : "circle"
        case .board: return "list.bullet.rectangle"
        case .log: return "text.bubble"
        case .image: return "photo"
        case .summary: return "sun.max"
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.18)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: Metrics.hairline))
                .overlay(Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint))
                .frame(width: 28, height: 28)
                .shadow(color: tint.opacity(selected ? 0.35 : 0), radius: 4, y: 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlighted(hit.title.isEmpty ? " " : hit.title))
                    .font(.system(size: 13.5, weight: .medium)).lineLimit(2)
                    .strikethrough(hit.completed, color: Palette.muted)
                    .foregroundStyle(hit.completed ? Palette.muted : Palette.ink)
                Text(hit.kind == .image ? AppLocalizedFormat("图片中的文字 · %@", hit.detail) : hit.detail)
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.line.opacity(0.6), lineWidth: Metrics.hairline))
            }
            if selected {
                Image(systemName: "return").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accent)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background {
            if selected {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                shape.fill(Palette.accent.opacity(scheme == .dark ? 0.2 : 0.14))
                    .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.06 : 0.35), .clear], startPoint: .top, endPoint: .bottom)))
                    .overlay(shape.strokeBorder(Palette.accent.opacity(0.35), lineWidth: Metrics.hairline))
                    .shadow(color: Palette.accent.opacity(scheme == .dark ? 0.25 : 0.18), radius: 6, y: 2)
                    .matchedGeometryEffect(id: "selection", in: namespace)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .animation(Motion.reduced ? nil : .spring(response: 0.26, dampingFraction: 0.86), value: selected)
        .onAppear(perform: loadThumbnail)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func loadThumbnail() {
        guard thumbnail == nil, let url = hit.image else { return }
        ImageTools.loadThumbnail(url, maxPixel: 96) { thumbnail = $0 }
    }

    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return attributed }
        var from = text.startIndex
        while from < text.endIndex, let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
            if let lower = AttributedString.Index(range.lowerBound, within: attributed),
               let upper = AttributedString.Index(range.upperBound, within: attributed) {
                attributed[lower..<upper].backgroundColor = Palette.accent.opacity(0.3)
                attributed[lower..<upper].font = .system(size: 13.5, weight: .semibold)
            }
            from = range.upperBound
        }
        return attributed
    }
}

/// 键帽样式的小提示。
struct KeyCap: View {
    let label: String
    init(_ label: String) { self.label = label }
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(label).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(Palette.muted)
            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 17)
            .background {
                let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
                shape.fill(Palette.background.opacity(scheme == .dark ? 0.45 : 0.6))
                    .overlay(shape.strokeBorder(Palette.line.opacity(0.8), lineWidth: Metrics.hairline))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.1), radius: 0, y: 1)
            }
    }
}

/// 搜索面板的玻璃：比专注面板略不透明。窗口后面轻微模糊一层，再铺一层主题底色和顶部微光，任何桌面上结果都看得清。
private struct SearchGlass: View {
    var radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            BehindWindowBlur(radius: radius).opacity(0.85)
            shape.fill(Palette.background.opacity(scheme == .dark ? 0.42 : 0.5))
            shape.fill(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.06 : 0.3), .clear], startPoint: .top, endPoint: .center))
        }
    }
}

/// 窗口后面的模糊（系统合成）。圆角用遮罩图，SwiftUI 的裁切管不到窗口服务器画的模糊。
private struct BehindWindowBlur: NSViewRepresentable {
    var radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .active
        view.maskImage = Self.mask(radius: radius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    private static func mask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// 面板里的按键：↑↓ 选择、回车打开、Tab / ⇧Tab 切换范围、Esc 关闭。输入法组词时不拦截。
private struct SearchPanelKeys: NSViewRepresentable {
    let move: (Int) -> Void
    let activate: () -> Void
    let cycle: (Int) -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.install()
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.move = move
        view.activate = activate
        view.cycle = cycle
    }

    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.remove() }

    final class KeyView: NSView {
        var move: ((Int) -> Void)?
        var activate: (() -> Void)?
        var cycle: ((Int) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window, event.window === window,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return event }
                switch event.keyCode {
                case 126: move?(-1)
                case 125: move?(1)
                case 36, 76: activate?()
                case 48: cycle?(event.modifierFlags.contains(.shift) ? -1 : 1)
                case 53: window.cancelOperation(nil)
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
