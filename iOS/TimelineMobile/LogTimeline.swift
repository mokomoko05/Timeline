import SwiftUI
import TimelineCore
import UIKit

/// 日志时间线：每条记录一个节点，左边是时刻。专注从开始到结束的一轮用强调色连起来，开头是一张可以收起整轮的摘要卡。
/// `groupByDay` 时每天先有一个日期节点（笔记页用）；日记页只显示一天，不分组。
struct LogTimeline: View {
    @ObservedObject var store: JournalStore
    let logs: [JournalStore.LoggedLog]
    var groupByDay = false
    var showsTask = true
    var newestFirst = false
    @State private var collapsedRounds: Set<UUID> = []

    private enum Row: Identifiable {
        case day(String, Date, Int)
        case log(JournalStore.LoggedLog, inFocus: (before: Bool, after: Bool))
        case round(FocusRound)

        var id: String {
            switch self {
            case .day(let key, _, _): return "day-" + key
            case .log(let logged, _): return logged.id.uuidString
            case .round(let round): return "round-" + round.id.uuidString
            }
        }
    }

    /// 一轮专注：开始记录 + 中间的记录 + 结束记录。
    struct FocusRound {
        let id: UUID
        let start: DailyLogEntry
        var end: DailyLogEntry?
        var notes = 0
        var reviewed = false
    }

    private var rows: [Row] {
        var rows: [Row] = []
        let days = Dictionary(grouping: logs, by: \.key)
        let keys = days.keys.sorted(by: newestFirst ? (>) : (<))
        for key in keys {
            let dayLogs = days[key]!.sorted { $0.log.createdAt < $1.log.createdAt }
            if groupByDay, let first = dayLogs.first { rows.append(.day(key, first.date, dayLogs.count)) }
            var dayRows: [Row] = []
            var round: FocusRound?
            var roundRows: [Row] = []
            func closeRound() {
                guard let current = round else { return }
                dayRows.append(.round(current))
                if !collapsedRounds.contains(current.id) { dayRows += roundRows }
                round = nil
                roundRows = []
            }
            for logged in dayLogs {
                let marker = logged.log.focusMarker
                if marker == "FOCUS" {
                    closeRound()
                    round = FocusRound(id: logged.id, start: logged.log)
                    roundRows = [.log(logged, inFocus: (false, true))]
                } else if round != nil {
                    if marker == "END" {
                        round!.end = logged.log
                        roundRows.append(.log(logged, inFocus: (true, false)))
                        closeRound()
                    } else {
                        if marker == "REVIEW" { round!.reviewed = true } else { round!.notes += 1 }
                        roundRows.append(.log(logged, inFocus: (true, true)))
                    }
                } else {
                    dayRows.append(.log(logged, inFocus: (false, false)))
                }
            }
            closeRound()
            rows += newestFirst && !groupByDay ? dayRows.reversed() : dayRows
        }
        return rows
    }

    var body: some View {
        let rows = rows
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                switch row {
                case .day(_, let date, let count):
                    RailRow(label: "", hasPrevious: index > 0, hasNext: index < rows.count - 1, nodeY: 14) {
                        Dot(color: JournalDates.calendar.isDateInToday(date) ? Palette.accent : Palette.muted, size: 8, ring: true)
                    } content: {
                        HStack(spacing: 8) {
                            if let relative = DayText.relative(date) {
                                Text(relative).font(.headline).foregroundStyle(Palette.accent)
                            }
                            Text(date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))
                                .font(.subheadline.monospacedDigit()).foregroundStyle(Palette.muted)
                            Text("· \(count) 条").font(.subheadline).foregroundStyle(Palette.muted)
                        }
                        .padding(.top, 4).padding(.bottom, 12)
                    }
                    .padding(.top, index > 0 ? 10 : 0)
                case .log(let logged, let inFocus):
                    LogEntryRow(store: store, logged: logged, showsTask: showsTask,
                                hasPrevious: index > 0, hasNext: index < rows.count - 1, focus: inFocus)
                case .round(let round):
                    RailRow(hasPrevious: index > 0, hasNext: index < rows.count - 1, nodeY: 22) {
                        EmptyView()
                    } content: {
                        FocusRoundCard(round: round, collapsed: collapsedRounds.contains(round.id)) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if collapsedRounds.contains(round.id) { collapsedRounds.remove(round.id) } else { collapsedRounds.insert(round.id) }
                            }
                        }
                        .padding(.bottom, 12)
                    }
                }
            }
        }
    }
}

/// 一条日志：时刻、类型、关联的待办、标签，Markdown 正文和图片。
struct LogEntryRow: View {
    @ObservedObject var store: JournalStore
    let logged: JournalStore.LoggedLog
    var showsTask = true
    var hasPrevious = true
    var hasNext = true
    var focus: (before: Bool, after: Bool) = (false, false)

    private var log: DailyLogEntry { logged.log }

    var body: some View {
        RailRow(label: DayText.time(log.createdAt), hasPrevious: hasPrevious, hasNext: hasNext,
                lineColor: Palette.line, nodeY: 10) {
            node
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                header
                if let body = LogStyle.body(log).nilIfEmpty {
                    MarkdownView(source: body, foldScope: "log." + log.id.uuidString, size: 15)
                        .opacity(log.isFocusMarker && log.focusMarker != "REVIEW" ? 0.75 : 1)
                }
                if log.focusEvent == .start, let goal = log.focusGoal?.nilIfEmpty {
                    Label(goal, systemImage: "flag").font(.subheadline).foregroundStyle(Palette.ink)
                }
                if !log.images.isEmpty { ImageStrip(store: store, names: log.images) }
            }
            .padding(.bottom, 18)
        }
        .overlay(alignment: .topLeading) {
            // 专注中的那一段竖线用强调色。
            GeometryReader { geometry in
                Path { path in
                    let x = RailRow<EmptyView, EmptyView>.labelWidth + 6 + 10
                    if focus.before, hasPrevious { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: 10)) }
                    if focus.after, hasNext { path.move(to: CGPoint(x: x, y: 10)); path.addLine(to: CGPoint(x: x, y: geometry.size.height)) }
                }
                .stroke(Palette.accent.opacity(0.8), lineWidth: 2)
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var node: some View {
        if log.focusMarker == "END" {
            Image(systemName: log.focusMetMinimum == false ? "xmark.circle" : "checkmark.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LogStyle.color(log))
                .background(Circle().fill(Palette.background))
        } else if log.focusMarker == "FOCUS" || log.focusMarker == "REVIEW" {
            Dot(color: LogStyle.color(log), size: 7, ring: true)
        } else {
            Dot(color: LogStyle.color(log), size: 6)
        }
    }

    @ViewBuilder private var header: some View {
        let label = LogStyle.label(log)
        let task = showsTask ? log.taskID.flatMap(store.locate) : nil
        let taskTitle = task.map { String(TaskText.rendered($0.task.title).characters) } ?? (showsTask ? log.taskTitle : nil)
        if label != nil || taskTitle != nil || !log.tags.isEmpty {
            HStack(spacing: 6) {
                if let label { Text(label).fontWeight(.semibold).foregroundStyle(LogStyle.color(log)) }
                if let taskTitle {
                    Text(((task?.task.number ?? log.taskNumber).map { "#\($0) " } ?? "") + taskTitle)
                        .foregroundStyle(Palette.accent).lineLimit(1)
                }
                ForEach(log.tags, id: \.self) { Text("#" + $0).foregroundStyle(Palette.note) }
            }
            .font(.footnote)
        }
    }
}

/// 一轮专注的摘要：用时、起止时刻、笔记数、是否有反馈和目标，点一下收起或展开这一轮。
private struct FocusRoundCard: View {
    let round: LogTimeline.FocusRound
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: round.end == nil ? "timer" : (round.end?.focusMetMinimum == false ? "xmark.seal" : "checkmark.seal"))
                    .foregroundStyle(round.end.map(LogStyle.color) ?? Palette.accent)
                    .font(.body.weight(.semibold))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                        Text(span).font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
                    }
                    HStack(spacing: 8) {
                        if round.notes > 0 { Text("\(round.notes) 条笔记") }
                        if round.reviewed { Text("已反馈").foregroundStyle(Palette.done) }
                    }
                    .font(.caption).foregroundStyle(Palette.muted)
                    if let goal = round.start.focusGoal?.nilIfEmpty {
                        Label(goal, systemImage: "flag").font(.caption).foregroundStyle(Palette.muted).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(Palette.accent)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
            }
            .padding(12)
            .card(highlighted: true)
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        if let seconds = round.end?.focusElapsedSeconds { return "专注 " + Duration.brief(seconds) }
        if let end = round.end { return "专注 " + Duration.brief(end.createdAt.timeIntervalSince(round.start.createdAt)) }
        return "专注中"
    }

    private var span: String {
        DayText.time(round.start.createdAt) + (round.end.map { "–" + DayText.time($0.createdAt) } ?? "")
    }
}

/// 一排图片缩略图，点开全屏，可以左右翻、双指缩放。
struct ImageStrip: View {
    @ObservedObject var store: JournalStore
    let names: [String]
    @State private var shown: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(names, id: \.self) { name in
                    Thumbnail(url: store.imageURL(name))
                        .onTapGesture { shown = name }
                }
            }
        }
        .fullScreenCover(item: Binding(get: { shown.map(ShownImage.init) }, set: { shown = $0?.id })) { item in
            ImageViewer(store: store, names: names, selection: item.id)
        }
    }

    private struct ShownImage: Identifiable { let id: String }
}

private struct Thumbnail: View {
    let url: URL

    var body: some View {
        Group {
            if let image = ImageCache.thumbnail(url) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                // 还没从 iCloud 下载下来。
                Palette.line.opacity(0.4).overlay { Image(systemName: "icloud.and.arrow.down").foregroundStyle(Palette.muted) }
            }
        }
        .frame(width: 110, height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.line.opacity(0.6)))
    }
}

private struct ImageViewer: View {
    @ObservedObject var store: JournalStore
    let names: [String]
    @State var selection: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(names, id: \.self) { name in
                    ZoomableImage(url: store.imageURL(name)).tag(name)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: names.count > 1 ? .automatic : .never))
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title).symbolRenderingMode(.hierarchical).foregroundStyle(.white)
            }
            .padding()
        }
    }
}

private struct ZoomableImage: View {
    let url: URL
    @State private var scale: CGFloat = 1
    @State private var settled: CGFloat = 1

    var body: some View {
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(MagnificationGesture()
                    .onChanged { scale = max(1, settled * $0) }
                    .onEnded { _ in settled = scale })
                .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5; settled = scale } }
        } else {
            ProgressView().tint(.white)
        }
    }
}

/// 缩略图缓存：列表来回滚动时不重复解码大图。
enum ImageCache {
    private static let cache = NSCache<NSURL, UIImage>()

    static func thumbnail(_ url: URL) -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let side: CGFloat = 330
        let scale = side / min(image.size.width, image.size.height)
        let thumbnail = scale < 1 ? image.preparingThumbnail(of: CGSize(width: image.size.width * scale, height: image.size.height * scale)) ?? image : image
        cache.setObject(thumbnail, forKey: url as NSURL)
        return thumbnail
    }
}
