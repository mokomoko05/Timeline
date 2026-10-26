import PhotosUI
import SwiftUI
import TimelineCore
import UIKit

/// 日记：一天一页，左右滑动翻页。顶部是日期和一天的节奏条，下面是当天的日志时间线。
struct JournalView: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var sync: SyncModel
    @State private var selection = JournalDates.key(Date())
    @State private var picking = false
    @State private var composing = false
    @State private var query = ""

    /// 有日志的日子，再加上今天。
    private var dayKeys: [String] {
        var keys = Set(store.allLogs(includeFocus: true).map(\.key))
        keys.insert(JournalDates.key(Date()))
        return keys.sorted()
    }

    var body: some View {
        NavigationStack {
            Group {
                if query.isEmpty {
                    pager
                } else {
                    JournalSearchResults(store: store, query: query)
                }
            }
            .background(Palette.background)
            .searchable(text: $query, prompt: "搜索日志")
            .navigationTitle("日记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { picking = true } label: { Image(systemName: "calendar") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if selection != JournalDates.key(Date()) {
                        Button("今天") { withAnimation { selection = JournalDates.key(Date()) } }
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if query.isEmpty {
                    Button { composing = true } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(Palette.accent, in: Circle())
                            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                    }
                    .padding(20)
                }
            }
            .sheet(isPresented: $composing) {
                ComposeSheet(store: store) { selection = JournalDates.key(Date()) }
            }
            .sheet(isPresented: $picking) {
                DayPicker(days: Set(dayKeys), selection: $selection)
            }
        }
    }

    private var pager: some View {
        let keys = dayKeys
        return TabView(selection: $selection) {
            ForEach(keys, id: \.self) { key in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        DayHeader(store: store, key: key, previous: neighbor(of: key, in: keys, by: -1), next: neighbor(of: key, in: keys, by: 1)) { target in
                            withAnimation { selection = target }
                        }
                        DayContent(store: store, key: key)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 100)
                }
                .refreshable { await sync.syncNow() }
                .tag(key)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private func neighbor(of key: String, in keys: [String], by offset: Int) -> String? {
        guard let index = keys.firstIndex(of: key), keys.indices.contains(index + offset) else { return nil }
        return keys[index + offset]
    }
}

/// 一天的标题：日期、星期、条数，左右箭头翻到前后有记录的日子；下面是节奏条。
private struct DayHeader: View {
    @ObservedObject var store: JournalStore
    let key: String
    let previous: String?
    let next: String?
    let go: (String) -> Void

    var body: some View {
        let date = JournalDates.date(for: key) ?? Date()
        let logs = store.entry(for: date).logs
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
            if !logs.isEmpty { RhythmStrip(logs: logs) }
        }
        .padding(.top, 8)
    }

    private func arrow(_ symbol: String, _ target: String?) -> some View {
        Button { if let target { go(target) } } label: {
            Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 36, height: 32)
        }
        .disabled(target == nil)
        .foregroundStyle(target == nil ? Palette.line : Palette.accent)
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

    var body: some View {
        let date = JournalDates.date(for: key) ?? Date()
        let logs = store.allLogs(includeFocus: true).filter { $0.key == key }
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
        ScrollView {
            if matches.isEmpty {
                ContentUnavailableView.search(text: query).padding(.top, 60)
            } else {
                LogTimeline(store: store, logs: Array(matches.suffix(200)), groupByDay: true, newestFirst: true)
                    .padding(.horizontal, 16).padding(.vertical, 12)
            }
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
struct ComposeSheet: View {
    @ObservedObject var store: JournalStore
    var taskID: UUID?
    var sent: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var linked: UUID?
    @State private var images: [String] = []
    @State private var picked: [PhotosPickerItem] = []
    @State private var error: String?
    @FocusState private var focused: Bool

    private var openTasks: [ScheduledTask] {
        TaskSortMode.deadline.sorted(store.tasks().filter { !$0.task.completed })
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("写点什么… 支持 Markdown 和 #标签", text: $text, axis: .vertical)
                    .lineLimit(4...14)
                    .focused($focused)
                    .font(.body)
                if !images.isEmpty { ImageStrip(store: store, names: images) }
                if let error { Text(error).font(.caption).foregroundStyle(Palette.danger) }
                HStack(spacing: 16) {
                    Menu {
                        Button("不关联") { linked = nil }
                        ForEach(openTasks.prefix(40)) { item in
                            Button((item.task.number.map { "#\($0) " } ?? "") + String(TaskText.rendered(item.task.title).characters)) { linked = item.id }
                        }
                    } label: {
                        Label(linkedTitle ?? "关联待办", systemImage: "at").lineLimit(1)
                    }
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
            .onAppear { linked = taskID; focused = true }
            .onChange(of: picked) { _, items in
                guard !items.isEmpty else { return }
                picked = []
                Task { await attach(items) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var linkedTitle: String? {
        linked.flatMap(store.locate).map { ($0.task.number.map { "#\($0) " } ?? "") + String(TaskText.rendered($0.task.title).characters) }
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
            try store.quickLog(parsed.title, images: images, taskID: linked, linkDefault: false, tags: parsed.tags,
                               allowInlineTaskReference: linked == nil, on: Date())
            store.save()
            sent()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
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
