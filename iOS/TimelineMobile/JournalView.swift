import PhotosUI
import SwiftUI
import TimelineCore

/// 日记：按天倒序列出日志和专注记录，底部随手记一条（可关联待办、加标签和图片）。
struct JournalView: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var sync: SyncModel
    @State private var visibleDays = 14
    @State private var query = ""

    private struct Day: Identifiable {
        let id: String
        let date: Date
        let logs: [JournalStore.LoggedLog]
    }

    private var days: [Day] {
        let all = store.allLogs(includeFocus: true)
        let matching = query.isEmpty ? all : all.filter { $0.log.searchableText.localizedStandardContains(query) || ($0.log.taskTitle ?? "").localizedStandardContains(query) }
        return Dictionary(grouping: matching, by: \.key)
            .map { Day(id: $0.key, date: $0.value[0].date, logs: $0.value.reversed()) }
            .sorted { $0.id > $1.id }
    }

    var body: some View {
        NavigationStack {
            let days = days
            List {
                ForEach(days.prefix(visibleDays)) { day in
                    Section {
                        if let summary = store.entry(for: day.date).summary.nilIfEmpty {
                            Text(summary).font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(day.logs) { LogRow(store: store, logged: $0, showsTask: true) }
                            .onDelete { offsets in
                                store.deleteLogs(Set(offsets.map { day.logs[$0].id }))
                            }
                    } header: {
                        Text(day.date.formatted(.dateTime.year().month().day().weekday(.wide)))
                    }
                }
                if days.count > visibleDays {
                    Button("显示更早的记录") { visibleDays += 14 }
                }
            }
            .overlay { if days.isEmpty { ContentUnavailableView("还没有记录", systemImage: "book") } }
            .searchable(text: $query, prompt: "搜索日志")
            .navigationTitle("日记")
            .safeAreaInset(edge: .bottom) { LogComposer(store: store) }
            .syncOnRefresh(sync)
        }
    }
}

struct LogRow: View {
    @ObservedObject var store: JournalStore
    let logged: JournalStore.LoggedLog
    let showsTask: Bool

    private var log: DailyLogEntry { logged.log }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(log.createdAt.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                if log.isFocusMarker { Image(systemName: "timer") }
                if showsTask, let title = log.taskTitle {
                    Text((log.taskNumber.map { "#\($0) " } ?? "") + title).lineLimit(1)
                }
                ForEach(log.tags, id: \.self) { Text("#" + $0).foregroundStyle(Color.accentColor) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let text = focusText ?? log.text.nilIfEmpty {
                Text(MarkdownInline.render(text))
                    .foregroundStyle(log.isFocusMarker ? .secondary : .primary)
            }
            if !log.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(log.images, id: \.self) { LogImage(url: store.imageURL($0)) }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// 专注记录：开始时显示目标，结束时显示用时。
    private var focusText: String? {
        switch log.focusMarker {
        case "FOCUS": return "开始专注" + (log.focusGoal.flatMap(\.nilIfEmpty).map { "：\($0)" } ?? "")
        case "END":
            let minutes = Int((log.focusElapsedSeconds ?? 0) / 60)
            return "专注 \(minutes) 分钟" + (log.text.nilIfEmpty.map { " · \($0)" } ?? "")
        default: return nil
        }
    }
}

struct LogImage: View {
    let url: URL
    @State private var expanded = false

    var body: some View {
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture { expanded = true }
                .fullScreenCover(isPresented: $expanded) {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                    .onTapGesture { expanded = false }
                }
        } else {
            // 还没从 iCloud 下载下来。
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                .frame(width: 96, height: 96)
                .overlay { Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary) }
        }
    }
}

/// 日记底部的输入栏。
struct LogComposer: View {
    @ObservedObject var store: JournalStore
    @State private var text = ""
    @State private var taskID: UUID?
    @State private var images: [String] = []
    @State private var picked: [PhotosPickerItem] = []
    @State private var error: String?
    @FocusState private var focused: Bool

    private var openTasks: [ScheduledTask] {
        TaskSortMode.deadline.sorted(store.tasks().filter { !$0.task.completed })
    }

    var body: some View {
        VStack(spacing: 6) {
            if let taskID, let task = store.locate(taskID) {
                HStack {
                    Label((task.task.number.map { "#\($0) " } ?? "") + String(TaskText.rendered(task.task.title).characters), systemImage: "link")
                        .lineLimit(1)
                    Spacer()
                    Button { self.taskID = nil } label: { Image(systemName: "xmark.circle.fill") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(images, id: \.self) { LogImage(url: store.imageURL($0)) } }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button("不关联") { taskID = nil }
                    ForEach(openTasks.prefix(30)) { item in
                        Button((item.task.number.map { "#\($0) " } ?? "") + String(TaskText.rendered(item.task.title).characters)) { taskID = item.id }
                    }
                } label: { Image(systemName: "at").font(.title3) }
                PhotosPicker(selection: $picked, maxSelectionCount: 6, matching: .images) {
                    Image(systemName: "photo").font(.title3)
                }
                TextField("记一笔… #标签", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.background, in: RoundedRectangle(cornerRadius: 18))
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task { await attach(items) }
        }
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
            try store.quickLog(parsed.title, images: images, taskID: taskID, linkDefault: false, tags: parsed.tags, on: Date())
            text = ""
            images = []
            error = nil
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

extension String {
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

enum MarkdownInline {
    /// 行内 Markdown（粗体、链接、代码），保留换行。
    static func render(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
