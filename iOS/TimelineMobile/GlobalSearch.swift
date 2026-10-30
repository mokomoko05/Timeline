import CoreSpotlight
import SwiftUI
import TimelineCore

/// 从别处跳进应用里的某一项：通知、Spotlight、搜索结果。目标页面还没建好（那个标签页没打开过）时先存着，页面出现时再取。
@MainActor
final class Navigator: ObservableObject {
    enum Target: Equatable {
        case task(UUID)
        case log(UUID)
        case board(UUID)
        /// 日记的某一天（每日小结）。
        case day(String)
    }

    static let shared = Navigator()
    @Published var target: Target?

    func open(_ target: Target) { self.target = target }

    /// 页面取走属于自己的目标。
    func take<Value>(_ extract: (Target) -> Value?) -> Value? {
        guard let target, let value = extract(target) else { return nil }
        self.target = nil
        return value
    }

    /// Spotlight 结果点进来。
    @discardableResult
    func open(_ activity: NSUserActivity) -> Bool {
        guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let (kind, id) = SpotlightItem.parse(identifier) else { return false }
        switch kind {
        case .task: open(.task(id))
        case .log: open(.log(id))
        case .board: open(.board(id))
        }
        return true
    }
}

/// 全局搜索：待办、工作板正文、日志与笔记、图片里的文字、每日小结一起搜，和 Mac 的全局搜索同一套规则。
/// 上面按范围筛（带各自的条数），命中的词高亮；点开就在搜索页里推进对应的页面并定位到那一行 / 那一条，返回还是这些结果。
private struct SearchRequest: Equatable { let query: String; let revision: Int }

struct GlobalSearchView: View {
    @ObservedObject var store: JournalStore
    @State private var query = ""
    @State private var scope = SearchScope.all
    @State private var results = SearchResults()
    @State private var path = NavigationPath()
    @State private var index = JournalSearchIndex()
    @State private var revision = 0

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if trimmed.isEmpty {
                    SearchHints()
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        scopes
                        hitList
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .background(Palette.background)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索待办、工作板、日志、图片里的文字")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SearchDestination.self) { destination in
                switch destination {
                case .task(let id): TaskPage(store: store, id: id)
                case .taskNote(let id, let reveal): TaskPage(store: store, id: id, reveal: reveal)
                case .board(let id, let line, let query): BoardPage(store: store, id: id, revealLine: line, query: query)
                case .day(let key, let reveal): DayPage(store: store, key: key, reveal: reveal)
                }
            }
            .notesDestinations(store)
            .task(id: SearchRequest(query: query, revision: revision)) {
                // 停顿一下再搜，打字时不每个字都扫一遍全部数据。
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                let requestQuery = query
                let snapshot = JournalSearchSnapshot(days: store.days, boards: store.boards)
                let matches: JournalSearchMatches
                do { matches = try await index.search(snapshot, query: requestQuery) } catch { return }
                guard !Task.isCancelled, requestQuery == query else { return }
                results = SearchResults(store: store, query: query, matches: matches)
                if PerfProbe.enabled { PerfProbe.lap("SEARCH_READY hits=\(results.hits.count) query=\(query)") }
                // 截图检查用：`-searchOpen board|log|image|summary|task` 搜完直接打开这一类的第一条。
                if let kind = UserDefaults.standard.string(forKey: "searchOpen"), path.isEmpty,
                   let hit = results.hits.first(where: { "\($0.kind)" == kind }) { open(hit) }
            }
            .onReceive(store.objectWillChange.debounce(for: .milliseconds(180), scheduler: RunLoop.main)) { revision &+= 1 }
            .onReceive(NotificationCenter.default.publisher(for: PerfProbe.action)) { note in
                if note.object as? String == "globalSearch" { query = "Record" }
                if note.object as? String == "globalSearchClear" { query = "" }
            }
            .onAppear {
                // 待办按拼音搜要先转写标题：一进搜索页就在后台转好。
                Task { await store.warmLinkMatching() }
                // 截图检查用：`-searchQuery 词` 打开时直接搜。
                if query.isEmpty, let start = UserDefaults.standard.string(forKey: "searchQuery") { query = start }
            }
        }
    }

    /// 范围：全部 / 待办 / 工作板 / 日志与笔记 / 图片文字，各带条数；没有结果的范围变淡。
    private var scopes: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchScope.allCases) { item in
                    let count = results.count(item)
                    let selected = scope == item
                    Button {
                        withAnimation(Motion.adapt(.snappy(duration: 0.2))) { scope = item }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: item.symbol).font(.caption.weight(.semibold))
                            Text(LocalizedStringKey(item.title))
                            Text("\(count)").monospacedDigit().foregroundStyle(selected ? Color.white.opacity(0.85) : Palette.muted)
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(selected ? Color.white : (count == 0 ? Palette.muted : Palette.ink))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(selected ? Palette.accent : Palette.card, in: Capsule())
                        .overlay(Capsule().stroke(selected ? .clear : Palette.line.opacity(0.6), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    @ViewBuilder private var hitList: some View {
        let hits = results.hits.filter { scope.includes($0.kind) }
        if hits.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 34, weight: .light)).foregroundStyle(Palette.muted.opacity(0.7))
                Text(LF("没有找到「%@」", trimmed)).font(.headline).foregroundStyle(Palette.ink)
                if scope != .all, results.count(.all) > 0 {
                    Button(LF("在全部结果中查看（%lld）", results.count(.all))) { withAnimation(Motion.adapt(.snappy(duration: 0.2))) { scope = .all } }
                        .font(.subheadline)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                    if index == 0 || hits[index - 1].kind != hit.kind {
                        Text(LocalizedStringKey(hit.kind.title))
                            .font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                            .padding(.top, index == 0 ? 0 : 10).padding(.leading, 4)
                    }
                    Button { open(hit) } label: { SearchHitRow(store: store, hit: hit, query: trimmed) }
                        .buttonStyle(.plain)
                }
                if hits.count >= SearchResults.limit {
                    Text("只列出前 \(SearchResults.limit) 条，再多打几个字缩小范围")
                        .font(.caption).foregroundStyle(Palette.muted).frame(maxWidth: .infinity).padding(.top, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
    }

    /// 有关联待办的日志在那个待办的笔记里打开，没有的打开那一天：都滚到这一条并闪一下。
    private func open(_ hit: SearchHit) {
        switch hit.target {
        case .task(let id): path.append(SearchDestination.task(id))
        case .board(let id, let line): path.append(SearchDestination.board(id, line: line, query: trimmed))
        case .log(let key, let id, let taskID):
            if let taskID, store.locate(taskID) != nil { path.append(SearchDestination.taskNote(taskID, reveal: id)) }
            else { path.append(SearchDestination.day(key, reveal: id)) }
        case .summary(let key): path.append(SearchDestination.day(key, reveal: nil))
        }
    }
}

enum SearchDestination: Hashable {
    case task(UUID)
    case taskNote(UUID, reveal: UUID)
    case board(UUID, line: Int, query: String)
    case day(String, reveal: UUID?)
}

/// 还没输入时：说明能搜什么。
private struct SearchHints: View {

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                hint("checklist", Palette.accent, "待办的标题、标签")
                hint("list.bullet.rectangle", Palette.attention, "工作板正文，点开跳到那一行")
                hint("text.bubble", Palette.note, "日志与笔记，点开定位到那一条")
                hint("text.viewfinder", Palette.success, "截图、照片里的文字")
                hint("number", Palette.muted, "输入 #标签 只看带这个标签的")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func hint(_ symbol: String, _ tint: Color, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            SearchBadge(symbol: symbol, tint: tint)
            Text(text).font(.subheadline).foregroundStyle(Palette.ink)
        }
    }
}

/// 结果左边的小方块图标，颜色区分种类（和 Mac 一样）。
private struct SearchBadge: View {
    let symbol: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(tint.opacity(0.16))
            .overlay(Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint))
            .frame(width: 30, height: 30)
    }
}

private struct SearchHitRow: View {
    let store: JournalStore
    let hit: SearchHit
    let query: String
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            SearchBadge(symbol: hit.symbol, tint: hit.kind.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(highlighted(hit.title.isEmpty ? " " : hit.title))
                    .font(.body)
                    .foregroundStyle(hit.completed ? Palette.muted : Palette.ink)
                    .strikethrough(hit.completed, color: Palette.muted)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Text(hit.detail).font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .card()
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .task(id: hit.image) {
            guard let name = hit.image else { return }
            let url = store.imageURL(name)
            thumbnail = ImageCache.cached(url)
            if thumbnail == nil { thumbnail = await Task.detached(priority: .userInitiated) { ImageCache.thumbnail(url) }.value }
        }
    }

    /// 命中的词加底色、加粗。
    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        let needle = TagText.searchTag(query) == nil ? query : ""
        guard !needle.isEmpty else { return attributed }
        var from = text.startIndex
        while from < text.endIndex, let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
            if let lower = AttributedString.Index(range.lowerBound, within: attributed),
               let upper = AttributedString.Index(range.upperBound, within: attributed) {
                attributed[lower..<upper].backgroundColor = Palette.accent.opacity(0.22)
                attributed[lower..<upper].font = .body.weight(.semibold)
            }
            from = range.upperBound
        }
        return attributed
    }
}

/// 一天的日志（从搜索结果打开没有关联待办的日志、或每日小结）：上面是小结，下面是这一天的时间线，滚到那一条并闪一下。
struct DayPage: View {
    @ObservedObject var store: JournalStore
    let key: String
    var reveal: UUID?

    var body: some View {
        let logs = store.logs(on: key)
        let date = JournalDates.date(for: key)
        let summary = store.days[key]?.summary.nilIfEmpty
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(date.map { $0.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) } ?? key)
                            .font(.title2.weight(.bold)).foregroundStyle(Palette.ink)
                        Text(LF("%@ · %lld 条", date.map { DayText.relative($0) ?? $0.formatted(.dateTime.weekday(.wide)) } ?? "", logs.count))
                            .font(.subheadline).foregroundStyle(Palette.muted)
                    }
                    .padding(.top, 8)
                    if let summary {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("每日小结", systemImage: "sun.max").font(.caption.weight(.semibold)).foregroundStyle(Palette.deadline)
                            MarkdownView(source: summary, foldScope: "summary." + key, size: 15)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                    }
                    if logs.isEmpty {
                        ContentUnavailableView("这一天没有日志", systemImage: "book").padding(.top, 20)
                    } else {
                        LogTimeline(store: store, logs: logs, reveal: reveal, lazy: false)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 60)
            }
            .markdownScrolling(proxy)
            .revealing(reveal, proxy: proxy)
        }
        .background(Palette.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if let reveal { Navigator.shared.open(.log(reveal)) } else { Navigator.shared.open(.day(key)) }
                } label: { Image(systemName: "book") }
                .accessibilityLabel("在日记中打开")
            }
        }
        .logActionsHost(store)
    }
}

/// 一条结果：是什么、在哪，点开跳到哪（具体到那一行 / 那一条）。
struct SearchHit: Identifiable {
    enum Kind: Equatable {
        case task, board, log, image, summary

        var title: String {
            switch self {
            case .task: return "待办"
            case .board: return "工作板"
            case .log: return "日志与笔记"
            case .image: return "图片里的文字"
            case .summary: return "每日小结"
            }
        }

        var tint: Color {
            switch self {
            case .task: return Palette.accent
            case .board: return Palette.attention
            case .log: return Palette.note
            case .image: return Palette.success
            case .summary: return Palette.deadline
            }
        }
    }

    enum Target {
        case task(UUID)
        /// 工作板里的第几行（从 1 开始）。
        case board(UUID, line: Int)
        case log(key: String, id: UUID, taskID: UUID?)
        case summary(String)
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let target: Target
    var completed = false
    /// 文字在图片里时，命中的那张图。
    var image: String?

    var symbol: String {
        switch kind {
        case .task: return completed ? "checkmark.circle" : "circle"
        case .board: return "list.bullet.rectangle"
        case .log: return "text.bubble"
        case .image: return "text.viewfinder"
        case .summary: return "sun.max"
        }
    }
}

enum SearchScope: String, CaseIterable, Identifiable {
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

    func includes(_ kind: SearchHit.Kind) -> Bool {
        switch self {
        case .all: return true
        case .tasks: return kind == .task
        case .boards: return kind == .board
        case .logs: return kind == .log || kind == .summary
        case .images: return kind == .image
        }
    }
}

/// 一次搜索的全部结果，和 Mac 的全局搜索同一套规则：待办在前，然后是工作板的命中行（每页最多 4 行）、
/// 日志（新的在前；文字只在图片里的单列成「图片里的文字」）、每日小结。`#标签` 只看带这个标签的。
struct SearchResults {
    static let boardLinesPerBoard = 4
    static let limit = 300

    var hits: [SearchHit] = []

    func count(_ scope: SearchScope) -> Int { scope == .all ? hits.count : hits.filter { scope.includes($0.kind) }.count }

    init() {}

    @MainActor
    init(store: JournalStore, query raw: String, matches: JournalSearchMatches? = nil) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let tag = TagText.searchTag(query)
        // 多个词各自出现即可；待办还能按拼音、拼音首字母找。
        let terms = tag == nil ? LinkMatcher.terms(query) : []
        let tasks = matches?.tasks ?? (tag == nil ? LinkMatcher.searchTasks(store.tasks(), terms: terms) : LinkMatcher.searchTasks(store.tasks(matching: query), terms: []))
        hits = tasks.prefix(80).map { item in
            var parts: [String] = []
            if let number = item.task.number { parts.append("#\(number)") }
            parts.append(item.task.dueDate.map { LF("截止 %@", DayText.relative($0) ?? DayText.short($0)) } ?? L("未设日期"))
            if !item.task.tags.isEmpty { parts.append(item.task.tags.map { "#" + $0 }.joined(separator: " ")) }
            return SearchHit(id: "task-\(item.id)", kind: .task, title: String(TaskText.rendered(item.task.title).characters),
                             detail: parts.joined(separator: " · "), target: .task(item.id), completed: item.task.completed)
        }
        if let tag {
            for item in matches?.locatedLogs ?? Array(store.logs(forTag: tag).reversed()) { hits.append(Self.logHit(item, store: store, terms: [])) }
            hits = Array(hits.prefix(Self.limit))
            return
        }
        for board in store.boards where !store.isBoardArchived(board) {
            if let matches, matches.boardLines[board.id] == nil { continue }
            var found = 0
            let matching: [(Int, String)]
            if let matches { matching = (matches.boardText[board.id] ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }
            else { matching = board.markdown.components(separatedBy: .newlines).enumerated().filter { LinkMatcher.containsAll($0.element, terms) }.map { ($0.offset, $0.element) } }
            for (index, line) in matching {
                hits.append(SearchHit(id: "board-\(board.id)-\(index)", kind: .board, title: Self.readable(line),
                                      detail: LF("%@ · 第 %lld 行", store.boardTitle(board), index + 1), target: .board(board.id, line: index + 1)))
                found += 1
                if found == Self.boardLinesPerBoard { break }
            }
        }
        for item in matches?.locatedLogs ?? Array(store.allLogs(includeFocus: true).reversed()) {
            let log = item.log
            if let matches, !matches.logs.contains(log.id) && !matches.images.contains(log.id) { continue }
            let text = ([log.text, log.focusGoal ?? "", log.taskTitle ?? ""] + log.tags + log.taskTags).joined(separator: "\n")
            if matches.map({ $0.logs.contains(log.id) }) ?? LinkMatcher.containsAll(text, terms) {
                hits.append(Self.logHit(item, store: store, terms: terms))
            } else if !log.images.isEmpty, matches.map({ $0.images.contains(log.id) }) ?? LinkMatcher.containsAll(log.recognizedText, terms) {
                hits.append(Self.imageHit(item, store: store, terms: terms))
            }
            if hits.count > Self.limit { break }
        }
        for key in (matches?.summaries ?? Set(store.days.keys)).sorted(by: >) {
            guard let summary = store.days[key]?.summary, !summary.isEmpty, matches.map({ $0.summaries.contains(key) }) ?? LinkMatcher.containsAll(summary, terms), let date = JournalDates.date(for: key) else { continue }
            let line = Self.bestLine(summary.components(separatedBy: .newlines), terms: terms) ?? summary
            hits.append(SearchHit(id: "summary-\(key)", kind: .summary, title: Self.readable(line),
                                  detail: LF("%@ · 每日小结", DayText.relative(date) ?? DayText.short(date)), target: .summary(key)))
        }
        hits = Array(hits.prefix(Self.limit))
    }

    private static func detail(_ item: JournalStore.LoggedLog) -> String {
        var detail = (DayText.relative(item.date) ?? DayText.short(item.date)) + " " + DayText.time(item.log.createdAt)
        if let title = item.log.taskTitle { detail += " · " + title }
        return detail
    }

    @MainActor private static func target(_ item: JournalStore.LoggedLog, store: JournalStore) -> SearchHit.Target {
        .log(key: item.key, id: item.log.id, taskID: item.log.taskID.flatMap { store.locate($0) == nil ? nil : $0 })
    }

    /// 多行正文只显示命中的那一行（没有就第一行非空的），去掉 Markdown 记号。
    @MainActor private static func logHit(_ item: JournalStore.LoggedLog, store: JournalStore, terms: [String]) -> SearchHit {
        let lines = LogStyle.body(item.log).components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let line = bestLine(lines, terms: terms) ?? lines.first ?? ""
        let title = String(TaskText.rendered(readable(line)).characters)
        return SearchHit(id: "log-\(item.log.id)", kind: .log, title: title.isEmpty ? (item.log.focusGoal ?? L("图片")) : title,
                         detail: detail(item), target: target(item, store: store), image: item.log.images.first)
    }

    /// 文字只在图片里：标题换成图片里命中的那一行，带上那张图。
    @MainActor private static func imageHit(_ item: JournalStore.LoggedLog, store: JournalStore, terms: [String]) -> SearchHit {
        let log = item.log
        let image = log.images.first { log.imageText[$0].map { LinkMatcher.containsAll($0, terms) } == true }
            ?? log.images.first { name in terms.contains { log.imageText[name]?.localizedStandardContains($0) == true } }
        let line = image.flatMap { log.imageText[$0] }.flatMap { bestLine($0.components(separatedBy: .newlines), terms: terms) } ?? ""
        return SearchHit(id: "image-\(log.id)", kind: .image, title: line.trimmingCharacters(in: .whitespaces),
                         detail: LF("图片中的文字 · %@", detail(item)), target: target(item, store: store), image: image)
    }

    /// 命中的那一行：所有词都在的行优先，其次是有任意一个词的行。
    private static func bestLine(_ lines: [String], terms: [String]) -> String? {
        guard !terms.isEmpty else { return nil }
        return lines.first { LinkMatcher.containsAll($0, terms) } ?? lines.first { line in terms.contains { line.localizedStandardContains($0) } }
    }

    /// 去掉缩进和行首的 Markdown 记号，读起来像正文。
    static func readable(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        for pattern in [#"^#{1,6}\s+"#, #"^>\s*"#, #"^[-+*]\s+\[[ xX]\]\s+"#, #"^[-+*]\s+"#, #"^\d+[.)]\s+"#] {
            if let range = text.range(of: pattern, options: .regularExpression) { text.removeSubrange(range); break }
        }
        return text.replacingOccurrences(of: #"</?(summary|details)[^>]*>"#, with: "", options: .regularExpression)
    }
}
