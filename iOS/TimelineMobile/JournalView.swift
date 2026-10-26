import PhotosUI
import SwiftUI
import TimelineCore
import UIKit

/// 日记：顶部是可以横向滑动的日期条，下面只显示选中的那一天；在内容上左右划动换到前后一天。
/// 只渲染当前这一天（不用分页视图一次挂上所有页面），前后两天的 Markdown 在后台预先解析，换天时不卡。
struct JournalView: View {
    @ObservedObject var store: JournalStore
    let sync: SyncModel
    @State private var selection = JournalDates.key(Date())
    @State private var picking = false
    @State private var composing = false
    @State private var query = ""
    @State private var direction: Edge = .trailing
    /// 在底部节奏条上点了某个时刻：滚到那条日志。
    @State private var jump: UUID?
    /// 右下角跳到顶部 / 底部的按钮（不订阅：滚动时只刷新按钮）。
    @State private var edges = ScrollEdges()

    var body: some View {
        let byDay = Dictionary(grouping: store.allLogs(includeFocus: true), by: \.key)
        let keys = Set(byDay.keys).union([JournalDates.key(Date())]).sorted()
        NavigationStack {
            VStack(spacing: 0) {
                if query.isEmpty {
                    DateStrip(keys: keys, counts: byDay.mapValues(\.count), selection: selection) { go(to: $0, keys: keys) }
                    Divider().overlay(Palette.line.opacity(0.6))
                    page(byDay[selection] ?? [], keys: keys)
                } else {
                    JournalSearchResults(store: store, query: query)
                }
            }
            .background(Palette.background)
            .searchable(text: $query, prompt: "搜索日志")
            .notesDestinations(store)
            .logActionsHost(store)
            .navigationTitle("日记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { picking = true } label: { Image(systemName: "calendar") }
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
                VStack(spacing: 0) {
                    FocusBar()
                    if query.isEmpty, let logs = byDay[selection], !logs.isEmpty {
                        RhythmBar(logs: logs.map(\.log)) { jump = $0 }
                    }
                }
            }
            .sheet(isPresented: $composing) {
                ComposeSheet(store: store) { selection = JournalDates.key(Date()) }
            }
            .sheet(isPresented: $picking) {
                DayPicker(days: Set(keys), selection: Binding(get: { selection }, set: { go(to: $0, keys: keys) }))
            }
            .onAppear { prewarm(around: selection, keys: keys, byDay: byDay) }
            .onChange(of: selection) { _, key in prewarm(around: key, keys: keys, byDay: byDay) }
            .onReceive(NotificationCenter.default.publisher(for: PerfProbe.openEditor)) { if $0.object as? String == "compose" { composing = true } }
            .onReceive(NotificationCenter.default.publisher(for: PerfProbe.previousDay)) { _ in
                if let target = neighbor(of: selection, in: keys, by: -1) { go(to: target, keys: keys) }
            }
        }
    }

    private func page(_ logs: [JournalStore.LoggedLog], keys: [String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).scrollEdgeMarker(.top)
                    VStack(alignment: .leading, spacing: 16) {
                        DayHeader(store: store, key: selection, logs: logs.map(\.log),
                                  previous: neighbor(of: selection, in: keys, by: -1), next: neighbor(of: selection, in: keys, by: 1)) {
                            go(to: $0, keys: keys)
                        }
                        DayContent(store: store, key: selection, logs: logs)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 100)
                    Color.clear.frame(height: 0).scrollEdgeMarker(.bottom)
                }
            }
            .markdownScrolling(proxy)
            .trackScrollEdges(edges, proxy: proxy)
            .onChange(of: jump) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id.uuidString, anchor: .top) }
                jump = nil
            }
            .refreshable { await sync.syncNow() }
            // 换一天就是一个新的滚动视图：从顶部开始，不沿用上一天的位置。
            .id(selection)
            .transition(.asymmetric(insertion: .move(edge: direction).combined(with: .opacity), removal: .opacity))
            .simultaneousGesture(
                DragGesture(minimumDistance: 30).onEnded { value in
                    let dx = value.translation.width, dy = value.translation.height
                    guard abs(dx) > 70, abs(dx) > abs(dy) * 1.8 else { return }
                    if let target = neighbor(of: selection, in: keys, by: dx < 0 ? 1 : -1) { go(to: target, keys: keys) }
                }
            )
        }
    }

    private func go(to key: String, keys: [String]) {
        guard key != selection else { return }
        direction = key > selection ? .trailing : .leading
        withAnimation(.easeOut(duration: 0.18)) { selection = key }
    }

    private func neighbor(of key: String, in keys: [String], by offset: Int) -> String? {
        guard let index = keys.firstIndex(of: key), keys.indices.contains(index + offset) else { return nil }
        return keys[index + offset]
    }

    /// 前后两天的正文先在后台解析好。
    private func prewarm(around key: String, keys: [String], byDay: [String: [JournalStore.LoggedLog]]) {
        let near = [-2, -1, 1, 2].compactMap { neighbor(of: key, in: keys, by: $0) }
        MarkdownBlock.prewarm(near.flatMap { byDay[$0] ?? [] }.map { LogStyle.body($0.log) }.filter { !$0.isEmpty })
    }
}

/// 日期条：有记录的日子排成一行，可以横向滑动，点一下跳过去；圆点多少表示那天记了多少。
private struct DateStrip: View {
    let keys: [String]
    let counts: [String: Int]
    let selection: String
    let select: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(keys, id: \.self) { key in
                        cell(key).id(key).onTapGesture { select(key) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, key in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(key, anchor: .center) } }
        }
        .frame(height: 76)
    }

    private func cell(_ key: String) -> some View {
        let date = JournalDates.date(for: key) ?? Date()
        let selected = key == selection
        let today = JournalDates.calendar.isDateInToday(date)
        let day = JournalDates.calendar.component(.day, from: date)
        let count = counts[key] ?? 0
        return VStack(spacing: 3) {
            Text(day == 1 || key == keys.first ? date.formatted(.dateTime.month(.abbreviated)) : date.formatted(.dateTime.weekday(.narrow)))
                .font(.caption2)
                .foregroundStyle(selected ? .white.opacity(0.85) : Palette.muted)
            Text("\(day)")
                .font(.system(size: 17, weight: selected || today ? .bold : .medium).monospacedDigit())
                .foregroundStyle(selected ? .white : (today ? Palette.accent : Palette.ink))
            HStack(spacing: 2) {
                ForEach(0..<min(3, (count + 4) / 5), id: \.self) { _ in
                    Circle().fill(selected ? .white : Palette.accent.opacity(0.7)).frame(width: 4, height: 4)
                }
            }
            .frame(height: 4)
        }
        .frame(width: 42, height: 58)
        .background(selected ? Palette.accent : (today ? Palette.soft : .clear), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// 一天的标题：日期、星期、条数、专注时长，左右箭头翻到前后有记录的日子；下面是节奏条。
private struct DayHeader: View {
    @ObservedObject var store: JournalStore
    let key: String
    let logs: [DailyLogEntry]
    let previous: String?
    let next: String?
    let go: (String) -> Void

    var body: some View {
        let date = JournalDates.date(for: key) ?? Date()
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(date.formatted(.dateTime.year().month(.defaultDigits).day()))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                arrow("chevron.left", previous)
                arrow("chevron.right", next)
            }
            HStack(spacing: 8) {
                if let relative = DayText.relative(date) { Chip(text: relative) }
                Text(DayText.weekday(date))
                Text("\(logs.count) 条日志")
                let focus = store.focusSeconds(on: date)
                if focus >= 60 { Label(Duration.brief(focus), systemImage: "timer") }
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
        .disabled(target == nil)
        .foregroundStyle(target == nil ? Palette.line : Palette.accent)
    }
}

/// 贴在日记页底部的节奏条：一直看得到这一天的节奏，点一下（或按住滑动）跳到那个时刻的日志。
private struct RhythmBar: View {
    let logs: [DailyLogEntry]
    let select: (UUID) -> Void
    @State private var picked: UUID?

    var body: some View {
        GeometryReader { geometry in
            RhythmStrip(logs: logs)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    pick(at: value.location.x / max(1, geometry.size.width))
                })
        }
        .frame(height: 36)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .sensoryFeedback(.selection, trigger: picked)
    }

    /// 离手指最近的一条日志。
    private func pick(at fraction: CGFloat) {
        guard let first = logs.first else { return }
        let start = JournalDates.calendar.startOfDay(for: first.createdAt)
        let time = start.addingTimeInterval(Double(min(1, max(0, fraction))) * 86_400)
        guard let nearest = logs.min(by: { abs($0.createdAt.timeIntervalSince(time)) < abs($1.createdAt.timeIntervalSince(time)) }),
              nearest.id != picked else { return }
        picked = nearest.id
        select(nearest.id)
    }
}

/// 一天的节奏：0–24 点的横条，每条记录一道刻度，专注的时段画成一段。
struct RhythmStrip: View {
    let logs: [DailyLogEntry]

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.line.opacity(0.5)).frame(height: 4)
                    ForEach(spans, id: \.start) { span in
                        Capsule().fill(Palette.accent.opacity(0.35))
                            .frame(width: max(3, width * (span.end - span.start)), height: 8)
                            .offset(x: width * span.start)
                    }
                    ForEach(logs) { log in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(LogStyle.color(log))
                            .frame(width: 2.5, height: log.isFocusMarker ? 14 : 10)
                            .offset(x: width * fraction(log.createdAt) - 1)
                    }
                }
                .frame(height: 16)
            }
            .frame(height: 16)
            HStack {
                ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                    Text("\(hour)").frame(maxWidth: .infinity, alignment: hour == 0 ? .leading : (hour == 24 ? .trailing : .center))
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(Palette.muted)
        }
        .padding(.vertical, 4)
    }

    private func fraction(_ date: Date) -> CGFloat {
        let start = JournalDates.calendar.startOfDay(for: date)
        return CGFloat(min(1, max(0, date.timeIntervalSince(start) / 86_400)))
    }

    private var spans: [(start: CGFloat, end: CGFloat)] {
        var result: [(CGFloat, CGFloat)] = []
        var open: Date?
        for log in logs.sorted(by: { $0.createdAt < $1.createdAt }) {
            if log.focusMarker == "FOCUS" { open = log.createdAt }
            if log.focusMarker == "END", let start = open { result.append((fraction(start), fraction(log.createdAt))); open = nil }
        }
        return result
    }
}

/// 一天的内容：小结 + 日志时间线。
private struct DayContent: View {
    @ObservedObject var store: JournalStore
    let key: String
    let logs: [JournalStore.LoggedLog]

    var body: some View {
        let date = JournalDates.date(for: key) ?? Date()
        VStack(alignment: .leading, spacing: 14) {
            if let summary = store.entry(for: date).summary.nilIfEmpty {
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
                LogTimeline(store: store, logs: logs)
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

/// 跳到某一天：日历上有记录的日子可选。
private struct DayPicker: View {
    let days: Set<String>
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            DatePicker("日期", selection: $date, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("跳到日期")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("前往") {
                            let key = JournalDates.key(date)
                            // 没记录的日子：去最近的、更早的一天。
                            selection = days.contains(key) ? key : (days.filter { $0 <= key }.max() ?? days.min() ?? key)
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                }
                .onAppear { date = JournalDates.date(for: selection) ?? Date() }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 写一条日志：可关联待办、加 #标签、配图。
///
/// 打字时只有这一页跟着刷新，所以这一页的正文要便宜：可关联的待办在打开时整理一次，菜单放在单独的视图里。
struct ComposeSheet: View {
    @ObservedObject var store: JournalStore
    var taskID: UUID?
    /// 固定加上的标签（在标签笔记本里写）。
    var tags: [String] = []
    var sent: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var linked: UUID?
    @State private var choices: [TaskChoice] = []
    /// 用 # 按钮加上的标签（正文里写的 #标签 发送时另外解析）。
    @State private var pickedTags: [String] = []
    @State private var tagChoices: [String] = []
    @State private var images: [String] = []
    @State private var picked: [PhotosPickerItem] = []
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("写点什么… 支持 Markdown 和 #标签", text: $text, axis: .vertical)
                    .lineLimit(4...14)
                    .focused($focused)
                    .font(.body)
                if !tags.isEmpty || !pickedTags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
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
                if let error { Text(error).font(.caption).foregroundStyle(Palette.danger) }
                HStack(spacing: 16) {
                    TaskChoiceMenu(choices: choices, linked: $linked)
                    TagChoiceMenu(choices: tagChoices, fixed: tags, picked: $pickedTags)
                    PhotosPicker(selection: $picked, maxSelectionCount: 6, matching: .images) {
                        Label("图片", systemImage: "photo")
                    }
                    Spacer()
                }
                .font(.subheadline)
                Spacer()
            }
            .padding()
            .navigationTitle("记一笔")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: send).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty)
                }
            }
            .onAppear {
                linked = taskID
                focused = true
                choices = TaskChoice.open(in: store, including: taskID)
                tagChoices = store.allTags().map(\.name)
            }
            .onChange(of: picked) { _, items in
                guard !items.isEmpty else { return }
                picked = []
                Task { await attach(items) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func attach(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                  let jpeg = image.scaledForLog().jpegData(compressionQuality: 0.85),
                  let name = try? store.storeImage(jpeg, fileExtension: "jpg") else { continue }
            images.append(name)
        }
    }

    private func send() {
        let parsed = TagText.extract(from: text)
        do {
            try store.quickLog(parsed.title, images: images, taskID: linked, linkDefault: false, tags: TagText.merge(TagText.merge(tags, pickedTags), parsed.tags),
                               allowInlineTaskReference: linked == nil, on: Date())
            store.save()
            sent()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
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

/// 「关联待办」菜单：单独一个视图，输入文字时不重建。
private struct TaskChoiceMenu: View {
    let choices: [TaskChoice]
    @Binding var linked: UUID?

    var body: some View {
        Menu {
            Button("不关联") { linked = nil }
            ForEach(choices) { choice in Button(choice.title) { linked = choice.id } }
        } label: {
            Label(choices.first { $0.id == linked }?.title ?? L("关联待办"), systemImage: "at").lineLimit(1)
        }
    }
}

/// 「加标签」菜单：已有的标签点一下加上 / 去掉，也可以输入新标签。单独一个视图，输入文字时不重建。
private struct TagChoiceMenu: View {
    let choices: [String]
    /// 标签笔记本里固定带上的，不在菜单里。
    let fixed: [String]
    @Binding var picked: [String]
    @State private var naming = false
    @State private var newTag = ""

    var body: some View {
        Menu {
            Button { naming = true } label: { Label("新标签…", systemImage: "plus") }
            ForEach(choices.filter { tag in !fixed.contains { TagText.key($0) == TagText.key(tag) } }, id: \.self) { tag in
                Button { toggle(tag) } label: {
                    if picked.contains(where: { TagText.key($0) == TagText.key(tag) }) { Label("#" + tag, systemImage: "checkmark") } else { Text("#" + tag) }
                }
            }
        } label: {
            Label(picked.isEmpty ? L("标签") : picked.map { "#" + $0 }.joined(separator: " "), systemImage: "number").lineLimit(1)
        }
        .alert("新标签", isPresented: $naming) {
            TextField("标签名", text: $newTag).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("取消", role: .cancel) { newTag = "" }
            Button("添加") {
                if let name = TagText.normalize(newTag), !picked.contains(where: { TagText.key($0) == TagText.key(name) }) { picked.append(name) }
                newTag = ""
            }
        }
    }

    private func toggle(_ tag: String) {
        if let index = picked.firstIndex(where: { TagText.key($0) == TagText.key(tag) }) { picked.remove(at: index) } else { picked.append(tag) }
    }
}

private extension UIImage {
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
