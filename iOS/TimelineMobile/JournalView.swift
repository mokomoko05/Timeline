import PhotosUI
import SwiftUI
import TimelineCore
import UIKit

/// 日记：只显示选中的那一天；左上角日历跳到任意一天，在内容上左右划动换到前后一天。
/// 只渲染当前这一天（不用分页视图一次挂上所有页面），前后两天的 Markdown 在后台预先解析，换天时不卡。
struct JournalView: View {
    let store: JournalStore
    @ObservedObject var feed: TabFeed
    let sync: SyncModel
    @State private var selection = JournalDates.key(Date())
    @State private var composing = false
    @State private var query = ""
    /// 要滚到的那条日志（从别处跳过来、截图检查）。
    @State private var jump: UUID?
    /// 现在页面顶上是哪一条（不订阅：只有右边的节奏条跟着变）。
    @State private var positions = LogPositions()
    /// 右下角跳到顶部 / 底部的按钮（不订阅：滚动时只刷新按钮）。
    @State private var edges = ScrollEdges()
    /// 左上角日历开没开（不订阅：开关日历不重算整页）。
    @State private var calendar = CalendarToggle()
    @State private var index = DayIndex()

    var body: some View {
        let (byDay, keys) = index.update(store.allLogs(includeFocus: true), tasks: store.tasks())
        NavigationStack {
            VStack(spacing: 0) {
                if query.isEmpty {
                    page(byDay[selection] ?? [], keys: keys)
                } else {
                    JournalSearchResults(store: store, query: query)
                }
            }
            .overlay {
                CalendarOverlay(toggle: calendar, days: keys, selection: selection,
                                prepare: { prewarm(keys: $0, byDay: byDay) },
                                pick: { key in jump(to: key, keys: keys, byDay: byDay) })
            }
            .background(Palette.background)
            .searchable(text: $query, prompt: "搜索日志")
            .notesDestinations(store)
            .logActionsHost(store)
            .navigationTitle("日记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SyncToolbarButton(sync: sync) }
                ToolbarItem(placement: .topBarLeading) {
                    Button { calendar.isOpen.toggle() } label: { Image(systemName: "calendar") }
                        .accessibilityLabel("日历")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if selection != JournalDates.key(Date()) {
                        Button("今天") { go(to: JournalDates.key(Date()), keys: keys) }
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if query.isEmpty { FloatingButtons(edges: edges) { composing = true } }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                FocusBar()
            }
            .onAppear { prewarm(around: selection, keys: keys, byDay: byDay) }
            .onChange(of: selection) { _, key in prewarm(around: key, keys: keys, byDay: byDay) }
            .onReceive(NotificationCenter.default.publisher(for: PerfProbe.openEditor)) { if $0.object as? String == "compose" { composing = true } }
            .onReceive(NotificationCenter.default.publisher(for: PerfProbe.action)) { note in
                if note.object as? String == "compose" { composing = true }
                if note.object as? String == "closeSheet" { composing = false }
                if note.object as? String == "flingJump", let view = edges.scrollView {
                    // 滚动动画还在走的时候点「跳到底部」/「回到顶部」：报落点和真正的底 / 顶差多少。
                    view.setContentOffset(CGPoint(x: 0, y: view.contentSize.height / 3), animated: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { edges.jump(.bottom) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        let bottom = view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom
                        print("[perf] 滑动中跳到底部：落点 \(Int(view.contentOffset.y)) · 底 \(Int(bottom)) · 差 \(Int(view.contentOffset.y - bottom))")
                        view.setContentOffset(CGPoint(x: 0, y: bottom / 2), animated: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { edges.jump(.top) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            print("[perf] 滑动中回到顶部：落点 \(Int(view.contentOffset.y)) · 顶 \(Int(-view.adjustedContentInset.top))")
                            print("[perf] 顶上这一条：\(positions.current.flatMap { id in (byDay[selection] ?? []).firstIndex { $0.log.id == id } }.map { "第 \($0 + 1) 条" } ?? "无")")
                        }
                    }
                }
            }
            .onReceive(QuickEntry.shared.$request) { _ in
                if QuickEntry.shared.take(.log) { selection = JournalDates.key(Date()); composing = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: PerfProbe.openCalendar)) { _ in calendar.isOpen = true }
            .onReceive(Navigator.shared.$target) { _ in
                if let key = Navigator.shared.take({ if case .day(let key) = $0 { key } else { nil } }) {
                    query = ""
                    selection = key
                } else if let id = Navigator.shared.take({ if case .log(let id) = $0 { id } else { nil } }),
                          let key = byDay.first(where: { $0.value.contains { $0.log.id == id } })?.key {
                    query = ""
                    selection = key
                    // 换天后滚动视图是新建的，等它出现再滚过去。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { jump = id }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: PerfProbe.revealLog)) { note in
                if let index = note.object as? Int, let logs = byDay[selection], logs.indices.contains(index) { jump = logs[index].log.id }
            }
            .onReceive(NotificationCenter.default.publisher(for: PerfProbe.previousDay)) { _ in
                if let target = neighbor(of: selection, in: keys, by: -1) { go(to: target, keys: keys) }
            }
        }
        .floatingEditor(isPresented: $composing) {
            ComposeSheet(store: store) { selection = JournalDates.key(Date()) }
        }
    }

    private func page(_ logs: [JournalStore.LoggedLog], keys: [String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).scrollEdgeMarker(.top)
                    VStack(alignment: .leading, spacing: 16) {
                        DayHeader(key: selection, logs: logs.map(\.log), focusSeconds: store.focusSeconds(on: JournalDates.date(for: selection) ?? Date()),
                                  previous: neighbor(of: selection, in: keys, by: -1), next: neighbor(of: selection, in: keys, by: 1)) {
                            go(to: $0, keys: keys)
                        }
                        DayContent(store: store, key: selection, summary: store.entry(for: JournalDates.date(for: selection) ?? Date()).summary, logs: logs)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, logs.isEmpty ? 16 : EntryRail.width + 8)
                    .padding(.bottom, 100)
                    Color.clear.frame(height: 0).scrollEdgeMarker(.bottom)
                }
                .coordinateSpace(name: LogPositions.space)
            }
            .markdownScrolling(proxy)
            .trackScrollEdges(edges, proxy: proxy)
            // 不显示滚动条：右边的节奏条代替它（长日志多时滚动条按估算高度走，位置不准）。
            .entryRail(DayRhythm.marks(logs.map(\.log)), spans: DayRhythm.spans(logs.map(\.log)),
                       ticks: [6, 12, 18].map { RailTick(position: CGFloat($0) / 24, text: "\($0)") },
                       positions: positions, edges: edges)
            .onChange(of: jump) { _, id in
                guard let id else { return }
                edges.reveal(id.uuidString)
                jump = nil
            }
            .refreshable { await sync.syncNow() }
            // 换一天就是一个新的滚动视图：从顶部开始，不沿用上一天的位置。
            .id(selection)
            .onAppear { PerfProbe.lap("这一天出现") }
            .simultaneousGesture(
                DragGesture(minimumDistance: 30, coordinateSpace: .global).onEnded { value in
                    let dx = value.translation.width, dy = value.translation.height
                    guard abs(dx) > 70, abs(dx) > abs(dy) * 1.8 else { return }
                    // 在能左右滑动的内容上（宽公式、代码、表格、图片）滑：那是在滑内容，不换天。
                    guard !HorizontalScrollers.contains(value.startLocation) else { return }
                    if let target = neighbor(of: selection, in: keys, by: dx < 0 ? 1 : -1) { go(to: target, keys: keys) }
                }
            )
        }
    }

    private func go(to key: String, keys: [String]) {
        guard key != selection else { return }
        selection = key
    }

    /// 从日历跳过去：先在后台把那天的正文解析好（打开日历时多半已经预读过），再换天，换的那一下不在主线程上解析。
    private func jump(to key: String, keys: [String], byDay: [String: [JournalStore.LoggedLog]]) {
        let logs = (byDay[key] ?? []).map(\.log)
        Task {
            await Task.detached(priority: .userInitiated) {
                for log in logs { let body = LogStyle.body(log); if !body.isEmpty { MarkdownBlock.warm(body) } }
            }.value
            go(to: key, keys: keys)
        }
    }

    private func neighbor(of key: String, in keys: [String], by offset: Int) -> String? {
        guard let index = keys.firstIndex(of: key), keys.indices.contains(index + offset) else { return nil }
        return keys[index + offset]
    }

    /// 前后两天的正文先在后台解析好。
    private func prewarm(around key: String, keys: [String], byDay: [String: [JournalStore.LoggedLog]]) {
        prewarm(keys: [-2, -1, 1, 2].compactMap { neighbor(of: key, in: keys, by: $0) }, byDay: byDay)
    }

    /// 正文的整理（去前缀、拼用时）也放到后台。
    private func prewarm(keys: [String], byDay: [String: [JournalStore.LoggedLog]]) {
        let logs = keys.flatMap { byDay[$0] ?? [] }.map(\.log)
        guard !logs.isEmpty else { return }
        Task.detached(priority: .utility) {
            for log in logs { let body = LogStyle.body(log); if !body.isEmpty { MarkdownBlock.warm(body) } }
        }
    }
}

/// 按天分好的日志。全部日志没变（数据层缓存的还是同一份）时直接用上次的结果：
/// 开关「记一笔」、换天这类只动页面状态的操作不用把几千条日志重新分组，下面的行也因为输入没变而不重算。
/// 待办变了（改名）也重新分一次：行里显示着关联待办的标题。
private final class DayIndex {
    /// 留着上次那两份（也让它们的存储不被释放、地址不会被新数组复用），比较是不是同一份。
    private var source: [JournalStore.LoggedLog]?
    private var tasks: [ScheduledTask]?
    private var today = ""
    private var result: ([String: [JournalStore.LoggedLog]], [String]) = ([:], [])

    func update(_ logs: [JournalStore.LoggedLog], tasks current: [ScheduledTask]) -> ([String: [JournalStore.LoggedLog]], [String]) {
        let now = JournalDates.key(Date())
        if let source, let tasks, now == today, same(source, logs), same(tasks, current) { return result }
        tasks = current
        let byDay = Dictionary(grouping: logs, by: \.key)
        result = (byDay, Set(byDay.keys).union([now]).sorted())
        source = logs
        today = now
        return result
    }

    private func same<T>(_ a: [T], _ b: [T]) -> Bool {
        a.count == b.count && a.withUnsafeBufferPointer { old in b.withUnsafeBufferPointer { $0.baseAddress == old.baseAddress } }
    }
}

/// 一天的标题：日期、星期、条数、专注时长，左右箭头翻到前后有记录的日子；下面是节奏条。
private struct DayHeader: View {
    let key: String
    let logs: [DailyLogEntry]
    let focusSeconds: TimeInterval
    let previous: String?
    let next: String?
    let go: (String) -> Void

    var body: some View {
        let date = JournalDates.date(for: key) ?? Date()
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(date.formatted(.dateTime.year().month(.defaultDigits).day()))
                    .font(.title.bold())
                    .foregroundStyle(Palette.ink)
                Spacer()
                arrow("chevron.left", previous)
                arrow("chevron.right", next)
            }
            HStack(spacing: 8) {
                if let relative = DayText.relative(date) { Chip(text: relative) }
                Text(DayText.weekday(date))
                Text("\(logs.count) 条日志")
                if focusSeconds >= 60 { Label(Duration.brief(focusSeconds), systemImage: "timer") }
            }
            .font(.subheadline)
            .foregroundStyle(Palette.muted)
        }
        .padding(.top, 12)
    }

    private func arrow(_ symbol: String, _ target: String?) -> some View {
        Button { if let target { go(target) } } label: {
            Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 36, height: 32)
        }
        .accessibilityLabel(symbol == "chevron.left" ? "前一天" : "后一天")
        .disabled(target == nil)
        .foregroundStyle(target == nil ? Palette.line : Palette.accent)
    }
}

/// 一天的内容：小结 + 日志时间线。
private struct DayContent: View {
    let store: JournalStore
    let key: String
    let summary: String
    let logs: [JournalStore.LoggedLog]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let summary = summary.nilIfEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("小结", systemImage: "text.quote").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                    MarkdownView(source: summary, foldScope: "summary." + key, size: 15)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            if logs.isEmpty {
                ContentUnavailableView("这天没有记录", systemImage: "book.closed", description: Text("点右下角写一条"))
                    .padding(.top, 40)
            } else {
                // 一天的日志不多，整列排出来：行高差很多（一篇长文顶几十条短日志）时懒加载按平均高度估算位置，
                // 跳到底部会落进空白、节奏条和滚动位置对不上。长文的排版有缓存，整列重排不贵。
                LogTimeline(store: store, logs: logs, lazy: false)
            }
        }
    }
}

/// 搜索结果：按天分组，新的在前。
private struct JournalSearchResults: View {
    @ObservedObject var store: JournalStore
    let query: String

    var body: some View {
        let matches = store.allLogs(includeFocus: true).filter {
            $0.log.searchableText.localizedStandardContains(query) || ($0.log.taskTitle ?? "").localizedStandardContains(query)
                || $0.log.tags.contains { $0.localizedStandardContains(query) }
        }
        ScrollViewReader { proxy in
            ScrollView {
                if matches.isEmpty {
                    ContentUnavailableView.search(text: query).padding(.top, 60)
                } else {
                    LogTimeline(store: store, logs: Array(matches.suffix(100)), groupByDay: true, newestFirst: true)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                }
            }
            .markdownScrolling(proxy)
        }
    }
}

final class CalendarToggle: ObservableObject {
    @Published var isOpen = false
}

/// 左上角日历弹出的面板：盖在日记上，点空白处收起。不用系统的日历控件（第一次建要一百多毫秒），也不走弹窗动画，点了就出来。
private struct CalendarOverlay: View {
    @ObservedObject var toggle: CalendarToggle
    let days: [String]
    let selection: String
    let prepare: ([String]) -> Void
    let pick: (String) -> Void

    var body: some View {
        if toggle.isOpen {
            ZStack(alignment: .top) {
                Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { toggle.isOpen = false }
                MonthCalendar(days: Set(days), selection: selection, prepare: prepare) { key in
                    toggle.isOpen = false
                    pick(key)
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .onAppear { PerfProbe.lap("日历出现") }
            }
        }
    }
}

/// 一个月的日历：有记录的日子下面一个点，点哪天直接跳过去；左右箭头或横划换月。
/// 点到没记录的日子：去最近的、更早的一天。
private struct MonthCalendar: View {
    let days: Set<String>
    let selection: String
    let prepare: ([String]) -> Void
    let pick: (String) -> Void
    @State private var month: Date

    private var calendar: Calendar { JournalDates.calendar }

    init(days: Set<String>, selection: String, prepare: @escaping ([String]) -> Void, pick: @escaping (String) -> Void) {
        self.days = days
        self.selection = selection
        self.prepare = prepare
        self.pick = pick
        let date = JournalDates.date(for: selection) ?? Date()
        _month = State(initialValue: JournalDates.calendar.dateInterval(of: .month, for: date)?.start ?? date)
    }

    var body: some View {
        let cells = self.cells
        VStack(spacing: 8) {
            HStack {
                step(-1, "chevron.left")
                Spacer()
                Text(month.formatted(.dateTime.year().month(.wide))).font(.headline).foregroundStyle(Palette.ink)
                Spacer()
                step(1, "chevron.right").disabled(month >= thisMonth)
            }
            HStack(spacing: 0) {
                ForEach(weekdays, id: \.self) { Text($0).frame(maxWidth: .infinity) }
            }
            .font(.caption)
            .foregroundStyle(Palette.muted)
            VStack(spacing: 2) {
                ForEach(0..<cells.count / 7, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { column in cell(cells[row * 7 + column]) }
                    }
                }
            }
        }
        .padding(12)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            let dx = value.translation.width
            guard abs(dx) > 50, abs(dx) > abs(value.translation.height) else { return }
            move(dx < 0 ? 1 : -1)
        })
        .onAppear { prepare(recorded(in: cells)) }
        .onChange(of: month) { prepare(recorded(in: self.cells)) }
        .onReceive(NotificationCenter.default.publisher(for: PerfProbe.pickDay)) { note in
            if let key = note.object as? String { choose(key) }
        }
    }

    private var thisMonth: Date { calendar.dateInterval(of: .month, for: Date())?.start ?? Date() }

    /// 这个月的格子，前面用 nil 补齐到一周的第一天，后面补齐整周。
    private var cells: [String?] {
        let count = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        var result: [String?] = Array(repeating: nil, count: lead)
        for day in 0..<count {
            result.append(calendar.date(byAdding: .day, value: day, to: month).map(JournalDates.key))
        }
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }

    private var weekdays: [String] {
        var calendar = calendar
        calendar.locale = AppLanguage.current.locale
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private func recorded(in cells: [String?]) -> [String] { cells.compactMap { $0 }.filter(days.contains) }

    @ViewBuilder
    private func cell(_ key: String?) -> some View {
        if let key {
            let today = JournalDates.key(Date())
            let selected = key == selection
            let future = key > today
            let recorded = days.contains(key)
            Button { choose(key) } label: {
                VStack(spacing: 2) {
                    Text(key.suffix(2).drop { $0 == "0" })
                        .font(.system(size: 16, weight: selected || key == today ? .bold : .regular).monospacedDigit())
                        .foregroundStyle(selected ? .white : (future ? Palette.line : (key == today ? Palette.accent : (recorded ? Palette.ink : Palette.muted))))
                        .frame(width: 34, height: 34)
                        .background(selected ? Palette.accent : .clear, in: Circle())
                    Circle().fill(recorded && !selected ? Palette.accent : .clear).frame(width: 4, height: 4)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(future)
            .accessibilityLabel(Text(JournalDates.date(for: key).map { DayText.relative($0) ?? DayText.short($0) } ?? key))
            .accessibilityValue(Text(recorded ? L("有日志") : ""))
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
        }
    }

    private func step(_ offset: Int, _ symbol: String) -> some View {
        Button { move(offset) } label: {
            Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 40, height: 32)
        }
        .accessibilityLabel(offset < 0 ? "上个月" : "下个月")
        .foregroundStyle(Palette.accent)
    }

    private func move(_ offset: Int) {
        guard let next = calendar.date(byAdding: .month, value: offset, to: month), next <= thisMonth else { return }
        month = next
    }

    private func choose(_ key: String) {
        pick(days.contains(key) ? key : (days.filter { $0 <= key }.max() ?? days.min() ?? key))
    }
}

/// 写一条日志：可关联待办、加 #标签、配图。
///
/// 打字时只有这一页跟着刷新，所以这一页的正文要便宜：可关联的待办在打开时整理一次，菜单放在单独的视图里。
/// 没保存就收起（点暗处、取消、切走应用）时留草稿，下次从同一个地方打开时接着写。
struct ComposeSheet: View {
    @ObservedObject var store: JournalStore
    var taskID: UUID?
    /// 固定加上的标签（在标签笔记本里写）。
    var tags: [String] = []
    var sent: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    /// 打开时恢复了草稿：显示一行提示，可以一键清空。
    @State private var restored: Bool
    /// 已经保存：收起时不再留草稿。
    @State private var finished = false
    @State private var linked: UUID?
    /// 关联的待办的标题：选的时候记一次，打字时不用每次去找。
    @State private var linkedTitle = ""
    /// 用 `@` / `#` 列表选的标签（正文里写的 #标签 发送时另外解析）。
    @State private var pickedTags: [String]
    /// 不订阅：只有列表订阅它，打字时这一页不会因为补全重算。
    @State private var mention = MentionModel()
    @State private var images: [String]
    @State private var picked: [PhotosPickerItem] = []
    @State private var takingPhoto = false
    @State private var error: String?
    @Environment(\.closeEditor) private var closeEditor

    init(store: JournalStore, taskID: UUID? = nil, tags: [String] = [], sent: @escaping () -> Void = {}) {
        self.store = store
        self.taskID = taskID
        self.tags = tags
        self.sent = sent
        // 正文在建视图时就放进去：输入框一出现就是草稿，不会先空一帧。
        let draft = ComposeDraft.load(ComposeDraft.key(taskID: taskID, tags: tags))
        _text = State(initialValue: draft?.text ?? "")
        _pickedTags = State(initialValue: draft?.tags ?? [])
        _images = State(initialValue: draft?.images ?? [])
        _restored = State(initialValue: draft != nil)
        _linked = State(initialValue: draft?.linked ?? taskID)
    }

    private var draftKey: String { ComposeDraft.key(taskID: taskID, tags: tags) }

    var body: some View {
        Group {
            if let close = closeEditor {
                VStack(alignment: .leading, spacing: 10) {
                    EditorCardHeader(title: "记一笔", confirm: "保存", canConfirm: canSend, cancel: close.close, action: send)
                    fields(maxLines: 8)
                }
            } else {
                sheet
            }
        }
        .onAppear(perform: load)
        .onChange(of: picked) { _, items in take(items) }
        // 草稿只在收起和退到后台时写一次，打字时不碰存储。
        .onChange(of: text) { if restored { restored = false } }
        .onDisappear { if !finished { saveDraft() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            if !finished { saveDraft() }
        }
    }

    private var sheet: some View {
        Group {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    fields(maxLines: 14)
                    Spacer()
                }
                .padding()
                .navigationTitle("记一笔")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存", action: send).disabled(!canSend) }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func saveDraft() {
        // 在待办里写时默认就关联着它，不算写了东西。
        ComposeDraft.save(ComposeDraft(text: text, linked: linked == taskID ? nil : linked, tags: pickedTags, images: images), key: draftKey)
    }

    private func clearDraft() {
        text = ""
        pickedTags = []
        images = []
        linked = nil
        if let taskID { link(taskID) }
        restored = false
        ComposeDraft.save(ComposeDraft(), key: draftKey)
    }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty }

    @ViewBuilder private func fields(maxLines: Int) -> some View {
        // 列表贴在输入框上面：卡片往上长，正在打字的那一行不动。
        MentionList(model: mention, store: store)
        AutoFocusTextView(text: $text, placeholder: L("写点什么… @ 关联待办 · # 标签"), minLines: 4, maxLines: maxLines, mention: mention)
        if linked != nil || !tags.isEmpty || !pickedTags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if linked != nil {
                        Button { linked = nil } label: { Chip(text: "@ " + linkedTitle + " ×", color: Palette.accent) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L("不关联"))
                    }
                    ForEach(tags, id: \.self) { Chip(text: "#" + $0, color: Palette.note) }
                    ForEach(pickedTags, id: \.self) { tag in
                        Button { pickedTags.removeAll { TagText.key($0) == TagText.key(tag) } } label: {
                            Chip(text: "#" + tag + " ×", color: Palette.note)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        if !images.isEmpty { ImageStrip(store: store, names: images) }
        if restored {
            HStack(spacing: 8) {
                Label("草稿已恢复", systemImage: "arrow.uturn.backward.circle").foregroundStyle(Palette.muted)
                Button("丢弃草稿", action: clearDraft).foregroundStyle(Palette.accent)
            }
            .font(.caption)
        }
        if let error { Text(error).font(.caption).foregroundStyle(Palette.danger) }
        HStack(spacing: 16) {
            // 两个按钮在光标处插入 `@` / `#`：弹出同一个列表，接着打字就是搜索。
            Button { mention.start(.task) } label: { Label("关联待办", systemImage: "at") }
            Button { mention.start(.tag) } label: { Label("标签", systemImage: "number") }
            PhotosPicker(selection: $picked, maxSelectionCount: 6, matching: .images, preferredItemEncoding: .current) {
                Label("图片", systemImage: "photo")
            }
            Spacer()
            // 直接拍照：拍好的照片放进这条日志。
            Button { takingPhoto = true } label: { Label("拍照", systemImage: "camera") }
                .disabled(!CameraPicker.available)
        }
        .font(.subheadline)
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { image in attach(photo: image) }.ignoresSafeArea()
        }
    }

    private func load() {
        if let linked { link(linked) }
        Task { await store.warmLinkMatching() }
        mention.provider = MentionProviders.make(store: store, chosenTags: { [tags, pickedTags = $pickedTags] in TagText.merge(tags, pickedTags.wrappedValue) })
        mention.onPick = { [link, pickedTags = $pickedTags] item in
            switch item {
            case .task(let task): link(task.id)
            case .tag(let tag): pickedTags.wrappedValue = TagText.merge(pickedTags.wrappedValue, [tag.name])
            }
        }
    }

    private func link(_ id: UUID) {
        linked = id
        let task = store.locate(id)?.task
        linkedTitle = (task?.number.map { "#\($0) " } ?? "") + (task.map { String(TaskText.rendered($0.title).characters) } ?? "")
    }

    private func take(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        picked = []
        Task { await attach(items) }
    }

    private func attach(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let name = try? await store.storeOriginalImage(data) else { continue }
            images.append(name)
        }
    }

    private func attach(photo: UIImage) {
        Task {
            let data = await Task.detached(priority: .userInitiated) { photo.pngData() }.value
            guard let data, let name = try? await store.storeOriginalImage(data) else { return }
            images.append(name)
        }
    }

    private func send() {
        let parsed = TagText.extract(from: text)
        do {
            try store.quickLog(parsed.title, images: images, taskID: linked, linkDefault: false, tags: TagText.merge(TagText.merge(tags, pickedTags), parsed.tags),
                               allowInlineTaskReference: linked == nil, on: Date())
            store.save()
            finished = true
            ComposeDraft.save(ComposeDraft(), key: draftKey)
            sent()
            if let closeEditor { closeEditor() } else { dismiss() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 记一笔的草稿：每个入口（日记、某个待办、某个标签笔记本）一份，只存在这台手机上，不同步。
struct ComposeDraft: Codable {
    var text = ""
    var linked: UUID?
    var tags: [String] = []
    var images: [String] = []

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && linked == nil && tags.isEmpty && images.isEmpty }

    static func key(taskID: UUID?, tags: [String]) -> String {
        "composeDraft." + (taskID.map { "task." + $0.uuidString } ?? tags.first.map { "tag." + TagText.key($0) } ?? "journal")
    }

    static func load(_ key: String) -> ComposeDraft? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(ComposeDraft.self, from: $0) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func save(_ draft: ComposeDraft, key: String) {
        if draft.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
        else if let data = try? JSONEncoder().encode(draft) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// 可以关联的待办：标题先排好版存成纯文字，菜单不用每次重算。
struct TaskChoice: Identifiable, Equatable {
    let id: UUID
    let title: String

    /// 未完成的待办（按截止日期），加上已经关联着的那个（哪怕它完成了）。
    @MainActor static func open(in store: JournalStore, including current: UUID? = nil, limit: Int = 60) -> [TaskChoice] {
        var items = Array(TaskSortMode.deadline.sorted(store.tasks().filter { !$0.task.completed }).prefix(limit))
        if let current, !items.contains(where: { $0.id == current }), let located = store.locate(current) { items.insert(located, at: 0) }
        return items.map { TaskChoice(id: $0.id, title: ($0.task.number.map { "#\($0) " } ?? "") + String(TaskText.rendered($0.task.title).characters)) }
    }
}

extension UIImage {
    /// 手机照片很大，长边缩到 2048 再存。
    func scaledForLog(maxSide: CGFloat = 2048) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let scale = maxSide / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}

/// 日记页的节奏条：从上到下是 0–24 点，每条日志按时刻放，专注的时段画成一段。
enum DayRhythm {
    static func marks(_ logs: [DailyLogEntry]) -> [RailMark] {
        logs.sorted { $0.createdAt < $1.createdAt }.map { log in
            RailMark(id: log.id, position: fraction(log.createdAt), color: LogStyle.color(log), emphasized: log.isFocusMarker,
                     label: DayText.time(log.createdAt), preview: RailMark.preview(log))
        }
    }

    static func spans(_ logs: [DailyLogEntry]) -> [ClosedRange<CGFloat>] {
        var result: [ClosedRange<CGFloat>] = []
        var open: Date?
        for log in logs.sorted(by: { $0.createdAt < $1.createdAt }) {
            if log.focusMarker == "FOCUS" { open = log.createdAt }
            if log.focusMarker == "END", let start = open {
                result.append(fraction(start)...max(fraction(start), fraction(log.createdAt)))
                open = nil
            }
        }
        return result
    }

    private static func fraction(_ date: Date) -> CGFloat {
        let start = JournalDates.calendar.startOfDay(for: date)
        return CGFloat(min(1, max(0, date.timeIntervalSince(start) / 86_400)))
    }
}

/// 屏幕上某一点下面有没有能左右滑动的内容（宽公式的滑动条、代码块、表格、图片条）。
@MainActor
enum HorizontalScrollers {
    static func contains(_ point: CGPoint) -> Bool {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first,
              var view = window.hitTest(window.convert(point, from: nil), with: nil) else { return false }
        while true {
            if let scroll = view as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1 || scroll.alwaysBounceHorizontal,
               scroll.contentSize.height <= scroll.bounds.height + 1 || scroll.alwaysBounceHorizontal {
                return true
            }
            guard let parent = view.superview else { return false }
            view = parent
        }
    }
}

/// 系统相机：拍一张，用这张就交回来，取消就收起。
struct CameraPicker: UIViewControllerRepresentable {
    static var available: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    let taken: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.taken(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
