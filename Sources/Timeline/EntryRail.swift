import AppKit
import SwiftUI
import TimelineCore

/// 节奏条上的一条记录：在条上的位置（0 顶 … 1 底）、颜色，和放大镜里显示的时刻与第一行。
struct RailMark: Identifiable, Equatable {
    let id: UUID
    let position: CGFloat
    let color: Color
    var emphasized = false
    let label: String
    let preview: String

    /// 放大镜里一行能显示的正文：第一行有字的内容，去掉 Markdown 记号。
    @MainActor static func preview(_ log: DailyLogEntry) -> String {
        let line = LogEventStyle.body(log).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#>-*+ []`").union(.whitespaces)) }
            .first { !$0.isEmpty }
        return String((line ?? (log.images.isEmpty ? "" : AppLocalized("图片"))).prefix(60))
    }
}

/// 条旁边的小字（几点、哪天）。
struct RailTick: Equatable {
    let position: CGFloat
    let text: String
}

/// 竖着的节奏条，代替滚动条放在日记、笔记页的右边（和 iPhone 一样）：每条记录一道刻度，页面顶上那一条的位置有一个滑块。
///
/// 点一下或按住上下拖：跳到离指针最近的那条。指针停在条上时旁边浮出放大镜，列出附近几条的时刻和第一行。
/// 长日志懒加载时滚动条按估算的高度走、忽大忽小，节奏条按记录本身排，不受影响。
struct EntryRail: View {
    static let width: CGFloat = 30
    let marks: [RailMark]
    var spans: [ClosedRange<CGFloat>] = []
    var ticks: [RailTick] = []
    @ObservedObject var tracker: ScrollTracker
    let select: (UUID) -> Void
    /// 拖完 / 点完停下的那一条（短暂高亮）。
    var settle: (UUID) -> Void = { _ in }
    @State private var hover: CGFloat?
    @State private var dragging = false
    @State private var picked: UUID?

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack(alignment: .topLeading) {
                RailTrack(marks: marks, spans: spans, ticks: ticks, active: hover != nil || dragging).equatable()
                RailThumb(marks: marks, tracker: tracker, height: height)
            }
            .contentShape(Rectangle())
            .gesture(drag(height: height))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hover = point.y
                case .ended: hover = nil
                }
            }
            .overlay(alignment: .topTrailing) {
                if let y = hover, !marks.isEmpty {
                    let index = nearest(y / max(1, height))
                    RailLoupe(marks: marks, index: index)
                        .offset(x: -(Self.width + 4), y: min(max(0, y - RailLoupe.height / 2), max(0, height - RailLoupe.height)))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: hover == nil)
        }
        .frame(width: Self.width)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppLocalized("记录分布"))
    }

    private func drag(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                dragging = true
                hover = value.location.y
                pick(nearest(value.location.y / max(1, height)))
            }
            .onEnded { _ in
                dragging = false
                if let picked { settle(picked) }
                picked = nil
            }
    }

    private func nearest(_ fraction: CGFloat) -> Int {
        let target = min(1, max(0, fraction))
        return marks.indices.min { abs(marks[$0].position - target) < abs(marks[$1].position - target) } ?? 0
    }

    private func pick(_ index: Int) {
        guard marks.indices.contains(index), marks[index].id != picked else { return }
        picked = marks[index].id
        select(marks[index].id)
    }
}

/// 条本身和刻度：只在记录变了时重画，滚动时不动。
private struct RailTrack: View, Equatable {
    let marks: [RailMark]
    let spans: [ClosedRange<CGFloat>]
    let ticks: [RailTick]
    let active: Bool

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let x = EntryRail.width - 9
            ZStack(alignment: .topLeading) {
                Capsule().fill(Palette.line.opacity(active ? 0.9 : 0.55))
                    .frame(width: 3, height: height)
                    .position(x: x, y: height / 2)
                ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                    Capsule().fill(Palette.accent.opacity(0.35))
                        .frame(width: 7, height: max(3, height * (span.upperBound - span.lowerBound)))
                        .position(x: x, y: height * (span.lowerBound + span.upperBound) / 2)
                }
                ForEach(marks) { mark in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(mark.color)
                        .frame(width: mark.emphasized ? 13 : 9, height: 2)
                        .position(x: x, y: height * mark.position)
                }
                ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                    // 右对齐，停在刻度左边，不压着刻度。
                    Text(tick.text).font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(Palette.muted)
                        .fixedSize()
                        .frame(width: 40, alignment: .trailing)
                        .position(x: x - 8 - 20, y: height * tick.position)
                }
            }
        }
    }
}

/// 现在页面顶上那一条的位置。滚动时只有它跟着变。
private struct RailThumb: View {
    let marks: [RailMark]
    @ObservedObject var tracker: ScrollTracker
    let height: CGFloat

    var body: some View {
        if let current = tracker.current, let mark = marks.first(where: { $0.id == current }) {
            Capsule().fill(Palette.accent)
                .frame(width: 15, height: 5)
                .overlay(Capsule().stroke(Palette.background, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                .position(x: EntryRail.width - 9, y: height * mark.position)
        }
    }
}

/// 放大镜：指针附近的那条和前后各三条，时刻 + 第一行。
private struct RailLoupe: View {
    static let rows = 7
    static let rowHeight: CGFloat = 26
    static var height: CGFloat { CGFloat(rows) * rowHeight + 12 }
    let marks: [RailMark]
    let index: Int

    var body: some View {
        VStack(spacing: 0) {
            ForEach(-(Self.rows / 2)...(Self.rows / 2), id: \.self) { offset in
                let position = index + offset
                if marks.indices.contains(position) {
                    let mark = marks[position]
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1).fill(mark.color).frame(width: 3, height: 13)
                        Text(mark.label).font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(offset == 0 ? Palette.accent : Palette.muted)
                            .fixedSize()
                        Text(mark.preview.isEmpty ? " " : mark.preview).font(.system(size: 11))
                            .foregroundStyle(offset == 0 ? Palette.ink : Palette.muted)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: Self.rowHeight)
                    .background(offset == 0 ? Palette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .opacity(1 - Double(abs(offset)) * 0.12)
                } else {
                    Color.clear.frame(height: Self.rowHeight)
                }
            }
        }
        .padding(6)
        .frame(width: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line.opacity(0.7), lineWidth: Metrics.hairline))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }
}

/// 滚动位置：直接听 NSScrollView 的滚动（不经过 SwiftUI 的布局），算出页面顶上是哪一条、要不要显示「回到顶部」「跳到最新」。
/// 页面本身不订阅它（用 `@State` 持有）：滚动时只有节奏条的滑块和那两个按钮刷新，整页笔记不重算。
@MainActor
final class ScrollTracker: ObservableObject {
    static let space = "scroll-tracker"
    private struct Position: Equatable {
        var current: UUID?
        var showsTop = false
        var showsBottom = false
    }

    @Published private var position = Position()
    var current: UUID? { position.current }
    var showsTop: Bool { position.showsTop }
    var showsBottom: Bool { position.showsBottom }
    /// 每条记录里垫着的一个小 NSView（懒加载的列表里只有已经排出来的那些）：滚动时按它们在内容里的位置找顶上那一条。
    /// 不用 SwiftUI 的 GeometryReader：那样每滚一帧每一行都要重算一遍。
    fileprivate let markers = NSHashTable<RowMarkerView>.weakObjects()
    fileprivate weak var scrollView: NSScrollView?

    private var pending = false
    private var scrolling = false

    func reset() {
        if current != nil { position.current = nil }
    }

    /// 有新的一行挂上来（刚打开、懒加载出新行）：这一轮事件处理完后再算一次（一轮里只算一次）。
    func setNeedsUpdate(scrolling: Bool = false) {
        self.scrolling = self.scrolling || scrolling
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            if self.scrolling, let scrollView = self.scrollView { InlineMarkdownEditor.shared.didScroll(in: scrollView) }
            self.scrolling = false
            self.update()
        }
    }

    func update() {
        guard let scrollView, let document = scrollView.documentView else { return }
        if scrollView.hasVerticalScroller { scrollView.hasVerticalScroller = false }
        let visible = scrollView.contentView.bounds
        let offset = visible.minY
        let top = offset > 240
        let bottom = document.frame.height - visible.maxY > 160
        let line = offset + 12
        var best: (id: UUID, top: CGFloat)?
        var first: (id: UUID, top: CGFloat)?
        for marker in markers.allObjects {
            guard let id = marker.id, marker.window != nil, marker.isDescendant(of: document) else { continue }
            let value = marker.convert(NSPoint.zero, to: document).y
            if value <= line, value > (best?.top ?? -.infinity) { best = (id, value) }
            if value < (first?.top ?? .infinity) { first = (id, value) }
        }
        let next = Position(current: best?.id ?? first?.id, showsTop: top, showsBottom: bottom)
        if next != position { position = next }
    }
}

/// 放在滚动内容里（背景）：挂到窗口上时找到外面的 NSScrollView，听它的滚动和内容高度变化。
private struct ScrollTrackerHook: NSViewRepresentable {
    let tracker: ScrollTracker

    func makeNSView(context: Context) -> HookView { HookView(tracker: tracker) }
    func updateNSView(_ view: HookView, context: Context) { view.tracker = tracker }

    final class HookView: NSView {
        var tracker: ScrollTracker
        private var observed: NSScrollView?
        private var lastOrigin = NSPoint.zero

        init(tracker: ScrollTracker) {
            self.tracker = tracker
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let scroll = enclosingScrollView, scroll !== observed else { return }
            NotificationCenter.default.removeObserver(self)
            observed = scroll
            lastOrigin = scroll.contentView.bounds.origin
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.documentView?.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            if let document = scroll.documentView {
                NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSView.frameDidChangeNotification, object: document)
            }
            MainActor.assumeIsolated {
                tracker.scrollView = scroll
                tracker.setNeedsUpdate()
            }
        }

        @objc private func changed() {
            MainActor.assumeIsolated {
                let origin = observed?.contentView.bounds.origin ?? .zero
                tracker.setNeedsUpdate(scrolling: origin != lastOrigin)
                lastOrigin = origin
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

private struct RowMarker: NSViewRepresentable {
    let id: UUID
    let tracker: ScrollTracker

    func makeNSView(context: Context) -> RowMarkerView {
        let view = RowMarkerView()
        view.id = id
        view.tracker = tracker
        return view
    }

    func updateNSView(_ view: RowMarkerView, context: Context) {
        view.id = id
        if view.tracker !== tracker { view.tracker = tracker }
    }
}

final class RowMarkerView: NSView {
    var id: UUID?
    weak var tracker: ScrollTracker? {
        didSet { if window != nil { register() } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { register() }
    }

    private func register() {
        MainActor.assumeIsolated {
            tracker?.markers.add(self)
            tracker?.setNeedsUpdate()
        }
    }
}

extension View {
    /// 滚动内容的最外层：内容坐标系，以及听滚动的钩子。
    func tracksScroll(_ tracker: ScrollTracker) -> some View {
        coordinateSpace(name: ScrollTracker.space)
            .background(ScrollTrackerHook(tracker: tracker))
    }

    /// 一条记录：在左上角垫一个 1×1 的小视图，`ScrollTracker` 滚动时按它的位置找出页面顶上那一条。
    func recordsScrollPosition(_ id: UUID, in tracker: ScrollTracker) -> some View {
        overlay(alignment: .topLeading) { RowMarker(id: id, tracker: tracker).frame(width: 1, height: 1) }
    }

    @ViewBuilder fileprivate func hidesScrollIndicators() -> some View {
        if #available(macOS 14.0, *) { scrollIndicators(.never) } else { scrollIndicators(.hidden) }
    }

    /// 页面右边放节奏条、不显示滚动条；右下角是「回到顶部」「跳到最新」。
    func entryRail(_ marks: [RailMark], spans: [ClosedRange<CGFloat>] = [], ticks: [RailTick] = [], tracker: ScrollTracker,
                   select: @escaping (UUID) -> Void, settle: @escaping (UUID) -> Void = { _ in },
                   scroll: @escaping (NotesScrollEdge) -> Void) -> some View {
        hidesScrollIndicators()
            .overlay(alignment: .topTrailing) {
                if !marks.isEmpty {
                    EntryRail(marks: marks, spans: spans, ticks: ticks, tracker: tracker, select: select, settle: settle)
                        .padding(.trailing, 4)
                        .padding(.top, 10)
                        .padding(.bottom, 64)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                NotesScrollButtons(tracker: tracker, scroll: scroll)
                    .padding(.trailing, marks.isEmpty ? 16 : EntryRail.width + 10).padding(.bottom, 14)
            }
    }
}

/// 日记的节奏条：从上到下是 0–24 点，每条日志按时刻放，专注的时段画成一段。
enum DayRhythm {
    @MainActor static func marks(_ logs: [DailyLogEntry]) -> [RailMark] {
        logs.sorted { $0.createdAt < $1.createdAt }.map { log in
            RailMark(id: log.id, position: fraction(log.createdAt), color: LogEventStyle.color(log), emphasized: log.isFocusMarker,
                     label: NoteThread.shortTime(log.createdAt), preview: RailMark.preview(log))
        }
    }

    /// 由「开始专注」到「结束」配对出的时段；今天还没结束的那一段画到现在。
    static func spans(_ logs: [DailyLogEntry], date: Date) -> [ClosedRange<CGFloat>] {
        var result: [ClosedRange<CGFloat>] = []
        var open: Date?
        for log in logs.sorted(by: { $0.createdAt < $1.createdAt }) {
            if log.focusMarker == "FOCUS" { open = log.createdAt }
            if log.focusMarker == "END", let start = open {
                result.append(fraction(start)...max(fraction(start), fraction(log.createdAt)))
                open = nil
            }
        }
        if let open, JournalDates.calendar.isDateInToday(date) { result.append(fraction(open)...max(fraction(open), fraction(Date()))) }
        return result
    }

    static let ticks = [6, 12, 18].map { RailTick(position: CGFloat($0) / 24, text: "\($0)") }

    private static func fraction(_ date: Date) -> CGFloat {
        let start = JournalDates.calendar.startOfDay(for: date)
        return CGFloat(min(1, max(0, date.timeIntervalSince(start) / 86_400)))
    }
}

/// 笔记页的节奏条：一条笔记一道刻度，从上到下按页面上的先后均匀排开（跨很多天，按时间放会挤成几团），旁边标几个日期。
enum NotesRhythm {
    @MainActor static func marks(_ notes: [JournalStore.LoggedLog]) -> [RailMark] {
        let last = CGFloat(max(1, notes.count - 1))
        return notes.enumerated().map { index, logged in
            RailMark(id: logged.id, position: notes.count == 1 ? 0 : CGFloat(index) / last, color: LogEventStyle.color(logged.log),
                     emphasized: logged.log.isFocusMarker,
                     label: logged.date.formatted(.dateTime.month(.defaultDigits).day()) + " " + NoteThread.shortTime(logged.log.createdAt),
                     preview: RailMark.preview(logged.log))
        }
    }

    /// 每天第一条旁边标日期，太挤的省掉；只写几号，换月时（和第一个）才带上月份。
    static func ticks(_ notes: [JournalStore.LoggedLog]) -> [RailTick] {
        let last = CGFloat(max(1, notes.count - 1))
        var ticks: [RailTick] = []
        var day: String?
        var lastMonth: Int?
        for (index, logged) in notes.enumerated() where logged.key != day {
            day = logged.key
            let position = notes.count == 1 ? 0 : CGFloat(index) / last
            if let previous = ticks.last, position - previous.position < 0.14 { continue }
            let month = JournalDates.calendar.component(.month, from: logged.date)
            let showsMonth = ticks.isEmpty || month != lastMonth
            lastMonth = month
            let dayNumber = JournalDates.calendar.component(.day, from: logged.date)
            ticks.append(RailTick(position: position, text: showsMonth ? "\(month)/\(dayNumber)" : "\(dayNumber)"))
        }
        return ticks
    }
}
