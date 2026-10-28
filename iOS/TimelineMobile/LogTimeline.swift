import SwiftUI
import TimelineCore
import UIKit

/// 日志时间线：每条记录一个节点，左边是时刻。专注从开始到结束的一轮用强调色连起来，开头是一张可以收起整轮的摘要卡。
/// `groupByDay` 时每天先有一个日期节点（笔记页用）；日记页只显示一天，不分组。
///
/// 不订阅数据：日志由外面传进来，没变就不重算；每一行也只在自己的内容变了时重算。
struct LogTimeline: View {
    let store: JournalStore
    let logs: [JournalStore.LoggedLog]
    var groupByDay = false
    var showsTask = true
    var newestFirst = false
    /// 打开时要滚到并闪一下的那条（从日记里点标签过来）：先把它前面的行都排上。
    var reveal: UUID?
    /// 很多天的日志（笔记页）只排看得到的行；一天的（日记页）整列排，位置准确。
    var lazy = true
    @State private var collapsedRounds: Set<UUID> = []
    @State private var flash: UUID?

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

    /// `newestFirst` 时日期和一天里的时刻都是新的在上；一轮专注整体倒过来，摘要卡仍在这一轮最上面。
    private var rows: [Row] {
        var rows: [Row] = []
        let days = Dictionary(grouping: logs, by: \.key)
        let keys = days.keys.sorted(by: newestFirst ? (>) : (<))
        for key in keys {
            let dayLogs = days[key]!.sorted { $0.log.createdAt < $1.log.createdAt }
            if groupByDay, let first = dayLogs.first { rows.append(.day(key, first.date, dayLogs.count)) }
            // 一段是一条单独的日志，或者一轮专注（摘要卡 + 这一轮的记录）。
            var segments: [[Row]] = []
            var round: FocusRound?
            var roundRows: [(JournalStore.LoggedLog, (before: Bool, after: Bool))] = []
            func closeRound() {
                guard let current = round else { return }
                var segment: [Row] = [.round(current)]
                if !collapsedRounds.contains(current.id) {
                    let ordered = newestFirst ? roundRows.reversed().map { ($0.0, (before: $0.1.after, after: $0.1.before)) } : roundRows
                    segment += ordered.map { Row.log($0.0, inFocus: $0.1) }
                }
                segments.append(segment)
                round = nil
                roundRows = []
            }
            for logged in dayLogs {
                let marker = logged.log.focusMarker
                if marker == "FOCUS" {
                    closeRound()
                    round = FocusRound(id: logged.id, start: logged.log)
                    roundRows = [(logged, (false, true))]
                } else if round != nil {
                    if marker == "END" {
                        round!.end = logged.log
                        roundRows.append((logged, (true, false)))
                        closeRound()
                    } else {
                        if marker == "REVIEW" { round!.reviewed = true } else { round!.notes += 1 }
                        roundRows.append((logged, (true, true)))
                    }
                } else {
                    segments.append([.log(logged, inFocus: (false, false))])
                }
            }
            closeRound()
            rows += (newestFirst ? segments.reversed() : segments).flatMap { $0 }
        }
        return rows
    }

    var body: some View {
        let rows = rows
        // 很多天的日志用 LazyVStack，只排屏幕上看得到的几行；代价是行高差别大时滚动条按估算高度走，会有点跳。
        Stack(lazy: lazy) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                switch row {
                case .day(_, let date, let count):
                    // 和上一天之间的空隙放在行里面，竖线画过去不断开。
                    RailRow(label: "", hasPrevious: index > 0, hasNext: index < rows.count - 1, nodeY: index > 0 ? 24 : 14) {
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
                        .padding(.top, 4 + (index > 0 ? 10 : 0)).padding(.bottom, 12)
                    }
                case .log(let logged, let inFocus):
                    LogEntryRow(store: store, logged: logged, showsTask: showsTask, task: showsTask ? logged.log.taskID.flatMap(store.locate) : nil,
                                hasPrevious: index > 0, hasNext: index < rows.count - 1, focus: inFocus, highlighted: flash == logged.id)
                        .equatable()
                case .round(let round):
                    RailRow(hasPrevious: index > 0, hasNext: index < rows.count - 1, nodeY: 22) {
                        EmptyView()
                    } content: {
                        FocusRoundCard(round: round, collapsed: collapsedRounds.contains(round.id)) {
                            if collapsedRounds.contains(round.id) { collapsedRounds.remove(round.id) } else { collapsedRounds.insert(round.id) }
                        }
                        // 专注小结卡往左伸，盖过竖线（这一行没有节点）。
                        .padding(.leading, -(RailRow<EmptyView, EmptyView>.railWidth + 12))
                        .padding(.bottom, 12)
                    }
                }
            }
        }
        .onAppear {
            guard let reveal, rows.contains(where: { $0.id == reveal.uuidString }) else { return }
            flash = reveal
        }
        .task(id: flash) {
            guard flash != nil else { return }
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(Motion.fading(.easeOut(duration: 0.5))) { flash = nil }
        }
    }
}

/// 竖排的一列：`lazy` 时只排看得到的行。
private struct Stack<Content: View>: View {
    let lazy: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: 0, content: content)
        } else {
            VStack(alignment: .leading, spacing: 0, content: content)
        }
    }
}

/// 一条日志：时刻、类型、关联的待办、标签，Markdown 正文和图片。
struct LogEntryRow: View, Equatable {
    let store: JournalStore
    let logged: JournalStore.LoggedLog
    var showsTask = true
    /// 关联的待办（`showsTask` 时由外面查好传进来）。
    var task: ScheduledTask?
    var hasPrevious = true
    var hasNext = true
    var focus: (before: Bool, after: Bool) = (false, false)
    var highlighted = false
    @Environment(\.logActions) private var actions
    @Environment(\.logPositions) private var positions

    private var log: DailyLogEntry { logged.log }

    static func == (a: LogEntryRow, b: LogEntryRow) -> Bool {
        a.logged.log == b.logged.log && a.logged.key == b.logged.key && a.showsTask == b.showsTask && a.task == b.task
            && a.hasPrevious == b.hasPrevious && a.hasNext == b.hasNext && a.focus == b.focus && a.highlighted == b.highlighted
    }

    var body: some View {
        let _ = PerfProbe.renderedFocusNote(log)
        RailRow(label: DayText.time(log.createdAt), hasPrevious: hasPrevious, hasNext: hasNext,
                lineColor: Palette.line, nodeY: 10, accent: focusSegment) {
            node
        } content: {
            let body = LogStyle.body(log).nilIfEmpty
            let hasText = body != nil || hasHeader || (log.focusEvent == .start && log.focusGoal?.nilIfEmpty != nil)
            VStack(alignment: .leading, spacing: 6) {
                if hasText {
                    // 文字部分长按浮起来、弹出菜单；图片有自己的菜单。
                    VStack(alignment: .leading, spacing: 6) {
                        header
                        if let body {
                            MarkdownView(source: body, foldScope: "log." + log.id.uuidString, size: 15)
                                .opacity(log.isFocusMarker && log.focusMarker != "REVIEW" ? 0.75 : 1)
                                // 点一下正文就编辑（和工作板一样所见即所得），不用先找「编辑」。链接、折叠按钮照常响应自己的点按。
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard let actions, !store.isReadOnly, log.hasEditableText else { return }
                                    actions.editing = logged
                                }
                        }
                        if log.focusEvent == .start, let goal = log.focusGoal?.nilIfEmpty {
                            Label(goal, systemImage: "flag").font(.subheadline).foregroundStyle(Palette.ink)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .logContextMenu(store: store, logged: logged, actions: actions)
                }
                if !log.images.isEmpty {
                    ImageStrip(store: store, names: log.images, texts: log.imageText, logged: hasText ? nil : logged)
                }
            }
            .padding(.bottom, 18)
            .background {
                if highlighted {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.accent.opacity(0.12)).padding(-6).padding(.bottom, 12)
                }
            }
        }
        .recordsLogPosition(log.id, in: positions)
    }

    /// 专注中的那一段竖线用强调色：画在节点下面，节点盖住线。
    private var focusSegment: (top: CGFloat, bottom: CGFloat?)? {
        let top: CGFloat = focus.before && hasPrevious ? 0 : 10
        let bottom: CGFloat? = focus.after && hasNext ? nil : 10
        return top < 10 || bottom == nil ? (top, bottom) : nil
    }

    @ViewBuilder private var node: some View {
        if log.focusMarker == "END" {
            Image(systemName: log.focusMetMinimum == false ? "xmark.circle" : "checkmark.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LogStyle.color(log))
                // 底色缩进圆圈的描边里：线接到圆圈上，不留白缝。
                .background(Circle().fill(Palette.background).padding(2))
        } else if log.focusMarker == "FOCUS" || log.focusMarker == "REVIEW" {
            Dot(color: LogStyle.color(log), size: 7, ring: true)
        } else {
            Dot(color: LogStyle.color(log), size: 6)
        }
    }

    private var hasHeader: Bool {
        LogStyle.label(log) != nil || (showsTask && log.showsTimelineContext && (log.taskID != nil || log.taskTitle != nil))
            || (log.showsTimelineTags && !log.tags.isEmpty)
    }

    @ViewBuilder private var header: some View {
        let label = LogStyle.label(log)
        let taskTitle = showsTask && log.showsTimelineContext
            ? task.map { String(TaskText.rendered($0.task.title).characters) } ?? log.taskTitle : nil
        let tags = log.showsTimelineTags ? log.tags : []
        if label != nil || taskTitle != nil || !tags.isEmpty {
            HStack(spacing: 6) {
                if let label { Text(label).fontWeight(.semibold).foregroundStyle(LogStyle.color(log)) }
                if let taskTitle {
                    let text = Text(((task?.task.number ?? log.taskNumber).map { "#\($0) " } ?? "") + taskTitle)
                        .foregroundStyle(Palette.accent).lineLimit(1)
                    // 点关联的待办：打开它的笔记本，停在这一条。
                    if let id = task?.id {
                        NavigationLink(value: NotesView.Destination.task(id, reveal: log.id)) {
                            text.padding(.vertical, 4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        text
                    }
                }
                // 点标签：打开这个标签的笔记本，停在这一条。
                ForEach(tags, id: \.self) { tag in
                    NavigationLink(value: NotesView.Destination.tag(tag, reveal: log.id)) {
                        Text("#" + tag).foregroundStyle(Palette.note)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
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
                    .animation(Motion.adapt(.easeOut(duration: 0.15)), value: collapsed)
            }
            .padding(12)
            .card(highlighted: true)
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        if let seconds = round.end?.focusElapsedSeconds { return LF("专注 %@", Duration.brief(seconds)) }
        if let end = round.end { return LF("专注 %@", Duration.brief(end.createdAt.timeIntervalSince(round.start.createdAt))) }
        return L("专注中")
    }

    private var span: String {
        DayText.time(round.start.createdAt) + (round.end.map { "–" + DayText.time($0.createdAt) } ?? "")
    }
}

/// 一排图片缩略图，点开全屏，可以左右翻、双指缩放。
struct ImageStrip: View {
    let store: JournalStore
    let names: [String]
    /// 图片里识别出的文字（来自 Mac 端），有的话可以直接复制。
    var texts: [String: String] = [:]
    /// 只有图片、没有文字的日志：日志自己的操作（编辑、标签、删除…）也放进图片的长按菜单。
    var logged: JournalStore.LoggedLog?
    @State private var shown: String?
    @StateObject private var toast = Toast()
    @Environment(\.logActions) private var actions

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(names, id: \.self) { name in
                    Button { shown = name } label: { Thumbnail(url: store.imageURL(name)) }
                        .buttonStyle(PressableStyle())
                        .contextMenu {
                            ImageActionButtons(url: store.imageURL(name), text: texts[name], toast: toast)
                            if let logged, let actions {
                                Section { LogMenuItems(store: store, logged: logged, actions: actions) }
                            }
                        } preview: {
                            ImagePreview(url: store.imageURL(name))
                        }
                }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: shown) { _, new in new != nil }
        .overlay(alignment: .bottom) { ToastView(toast: toast) }
        .fullScreenCover(item: Binding(get: { shown.map(ShownImage.init) }, set: { shown = $0?.id })) { item in
            ImageViewer(store: store, names: names, texts: texts, selection: item.id)
        }
    }

    private struct ShownImage: Identifiable { let id: String }
}

private struct Thumbnail: View {
    let url: URL
    @State private var image: UIImage?
    @State private var missing = false

    var body: some View {
        Group {
            if let image = image ?? ImageCache.cached(url) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if missing {
                // 还没从 iCloud 下载下来。
                Palette.line.opacity(0.4).overlay { Image(systemName: "icloud.and.arrow.down").foregroundStyle(Palette.muted) }
            } else {
                Palette.line.opacity(0.25)
            }
        }
        .task(id: url) {
            guard ImageCache.cached(url) == nil else { return }
            // 解码大图放到后台：在主线程上一张照片要几十毫秒，一天几张就是明显的卡顿。
            let loaded = await Task.detached(priority: .userInitiated) { [url] in ImageCache.thumbnail(url) }.value
            image = loaded
            missing = loaded == nil
        }
        .frame(width: 110, height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.line.opacity(0.6)))
    }
}

/// 按下时缩一点、变暗一点：点缩略图有手感。
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(Motion.adapt(.spring(response: 0.25, dampingFraction: 0.7)), value: configuration.isPressed)
    }
}

/// 长按缩略图时的大图预览。
private struct ImagePreview: View {
    let url: URL

    var body: some View {
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 360, maxHeight: 480)
        } else {
            Image(systemName: "icloud.and.arrow.down").font(.largeTitle).padding(40)
        }
    }
}

/// 对一张图片能做的事：复制、分享、存到照片、复制图中文字。长按菜单和全屏查看共用。
private struct ImageActionButtons: View {
    let url: URL
    let text: String?
    let toast: Toast

    var body: some View {
        Button { copyImage() } label: { Label("复制图片", systemImage: "doc.on.doc") }
        if let text = text?.nilIfEmpty {
            Button {
                UIPasteboard.general.string = text
                toast.show(L("已复制图中文字"))
            } label: { Label("复制图中文字", systemImage: "text.viewfinder") }
        }
        Button { saveToPhotos() } label: { Label("存储到照片", systemImage: "square.and.arrow.down") }
        ShareLink(item: url) { Label("分享…", systemImage: "square.and.arrow.up") }
    }

    private func copyImage() {
        guard let image = UIImage(contentsOfFile: url.path) else { toast.show(L("图片还没下载好")); return }
        UIPasteboard.general.image = image
        toast.show(L("已复制图片"))
    }

    private func saveToPhotos() {
        guard let image = UIImage(contentsOfFile: url.path) else { toast.show(L("图片还没下载好")); return }
        PhotoSaver.save(image) { error in
            toast.show(L(error == nil ? "已存储到照片" : "没能存到照片：请在设置里允许 Timeline 添加照片"))
        }
    }
}

/// `UIImageWriteToSavedPhotosAlbum` 只接受 Objective-C 的回调方法，包一层。
private final class PhotoSaver: NSObject {
    private let done: (Error?) -> Void
    private static var pending: Set<PhotoSaver> = []

    private init(done: @escaping (Error?) -> Void) { self.done = done }

    static func save(_ image: UIImage, done: @escaping (Error?) -> Void) {
        let saver = PhotoSaver(done: done)
        pending.insert(saver)
        UIImageWriteToSavedPhotosAlbum(image, saver, #selector(finished(_:error:context:)), nil)
    }

    @objc private func finished(_ image: UIImage, error: Error?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            self.done(error)
            PhotoSaver.pending.remove(self)
        }
    }
}

/// 操作完成后底部短暂出现的一句提示。
@MainActor final class Toast: ObservableObject {
    @Published private(set) var message: String?
    private var hide: DispatchWorkItem?

    func show(_ text: String) {
        withAnimation(Motion.fading(.snappy)) { message = text }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in withAnimation(Motion.fading(.easeOut)) { self?.message = nil } }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
}

struct ToastView: View {
    @ObservedObject var toast: Toast

    var body: some View {
        if let message = toast.message {
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.black.opacity(0.75), in: Capsule())
                .transition(Motion.transition(.move(edge: .bottom).combined(with: .opacity)))
                .padding(.bottom, 8)
                .allowsHitTesting(false)
        }
    }
}

private struct ImageViewer: View {
    @ObservedObject var store: JournalStore
    let names: [String]
    let texts: [String: String]
    @State var selection: String
    @StateObject private var toast = Toast()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(names, id: \.self) { name in
                    ZoomableImage(url: store.imageURL(name)) { dismiss() }.tag(name)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: names.count > 1 ? .automatic : .never))
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title).symbolRenderingMode(.hierarchical).foregroundStyle(.white)
            }
            .accessibilityLabel("关闭")
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                ToastView(toast: toast)
                HStack(spacing: 0) {
                    ImageActionButtons(url: store.imageURL(selection), text: texts[selection], toast: toast)
                        .labelStyle(ViewerActionLabel())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.bottom, names.count > 1 ? 24 : 4)
            }
        }
    }
}

/// 全屏查看底部的操作：图标在上、字在下。
private struct ViewerActionLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 4) {
            configuration.icon.font(.title3)
            configuration.title.font(.caption2)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// 双指缩放、双击放大；单击（图上或旁边的黑底）退出查看。
private struct ZoomableImage: View {
    let url: URL
    let close: () -> Void
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5; settled = scale } }
                .onTapGesture(perform: close)
        } else {
            ProgressView().tint(.white)
        }
    }
}

/// 缩略图缓存：列表来回滚动时不重复解码大图。
enum ImageCache {
    private static let cache = NSCache<NSURL, UIImage>()

    static func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    /// 读出并缩小一张图（可以在后台线程调用）。
    nonisolated static func thumbnail(_ url: URL) -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let side: CGFloat = 330
        let scale = side / min(image.size.width, image.size.height)
        let thumbnail = scale < 1 ? image.preparingThumbnail(of: CGSize(width: image.size.width * scale, height: image.size.height * scale)) ?? image
            : image.preparingForDisplay() ?? image
        cache.setObject(thumbnail, forKey: url as NSURL)
        return thumbnail
    }
}

private extension View {
    /// 长按文字：文字块浮起来，弹出日志操作。比屏幕高的长日志整块浮起来会先弹出去再缩回来，只浮起手指附近的一段（见 `LongTextMenu`）。
    @ViewBuilder
    func logContextMenu(store: JournalStore, logged: JournalStore.LoggedLog, actions: LogActions?) -> some View {
        if let actions {
            background(Palette.background)
                .background(LongTextMenu { actions.menu(store: store, logged: logged) })
        } else {
            self
        }
    }
}
