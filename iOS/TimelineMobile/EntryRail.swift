import SwiftUI
import TimelineCore
import UIKit

/// 节奏条上的一条记录：在条上的位置（0 顶 … 1 底）、颜色，和放大镜里显示的时刻与第一行。
struct RailMark: Identifiable, Equatable {
    let id: UUID
    let position: CGFloat
    let color: Color
    var emphasized = false
    let label: String
    let preview: String

    /// 放大镜里一行能显示的正文：第一行有字的内容，去掉 Markdown 记号。
    static func preview(_ log: DailyLogEntry) -> String {
        let line = LogStyle.body(log).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#>-*+ []").union(.whitespaces)) }
            .first { !$0.isEmpty }
        return String((line ?? LogStyle.label(log) ?? (log.images.isEmpty ? "" : L("图片"))).prefix(60))
    }
}

/// 条旁边的小字（几点、哪天）。
struct RailTick: Equatable {
    let position: CGFloat
    let text: String
}

/// 竖着的节奏条，代替滚动条放在页面右边：每条记录一道刻度，现在页面顶上那一条的位置有一个滑块。
///
/// 点一下或按住上下滑：跳到离手指最近的那条。按住不动一会儿出现放大镜：手指附近的几条连同时刻和第一行列出来，
/// 这时每移动一小段（30 点）换一条，挤在一起的记录也能逐条挑。松手停在选中的那条。
struct EntryRail: View {
    static let width: CGFloat = 30
    private static let step: CGFloat = 30
    let marks: [RailMark]
    var spans: [ClosedRange<CGFloat>] = []
    var ticks: [RailTick] = []
    @ObservedObject var positions: LogPositions
    let select: (UUID) -> Void
    @State private var touch: Touch?
    @State private var picked: UUID?
    @State private var hold: Task<Void, Never>?

    private var currentIndex: Int? { positions.current.flatMap { current in marks.firstIndex { $0.id == current } } }

    private var accessibilityValue: String {
        guard let index = currentIndex else { return LF("共 %lld 条", marks.count) }
        let mark = marks[index]
        return LF("第 %lld 条，共 %lld 条", index + 1, marks.count) + " · " + mark.label + " " + mark.preview
    }

    private struct Touch {
        var startY: CGFloat
        var lastY: CGFloat
        var moved = false
        /// 放大镜：出现时选中的是第几条、手指在哪。
        var fine: (index: Int, originY: CGFloat)?
        var fineIndex = 0
    }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack(alignment: .topLeading) {
                RailTrack(marks: marks, spans: spans, ticks: ticks, active: touch != nil).equatable()
                RailThumb(marks: marks, positions: positions, height: height)
            }
            .contentShape(Rectangle())
            .gesture(drag(height: height))
            .overlay(alignment: .topTrailing) {
                if let touch, touch.fine != nil {
                    let loupe = RailLoupe(marks: marks, index: touch.fineIndex)
                    loupe.offset(x: -(Self.width + 4), y: min(max(0, touch.lastY - RailLoupe.height / 2), max(0, height - RailLoupe.height)))
                        .transition(Motion.transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .trailing))))
                        .allowsHitTesting(false)
                }
            }
            .animation(Motion.adapt(.snappy(duration: 0.18)), value: touch?.fine != nil)
        }
        .frame(width: Self.width)
        .sensoryFeedback(.selection, trigger: picked) { _, new in new != nil }
        .sensoryFeedback(.impact(weight: .medium), trigger: touch?.fine != nil) { old, new in !old && new }
        // 读屏：整条是一个可调节的元素，上下轻扫跳到上一条 / 下一条记录。
        .accessibilityElement()
        .accessibilityLabel(Text("节奏条"))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityHint(Text("上下轻扫跳到上一条或下一条记录"))
        .accessibilityAdjustableAction { direction in
            guard !marks.isEmpty else { return }
            let index = currentIndex ?? -1
            let next = direction == .increment ? min(index + 1, marks.count - 1) : max(index - 1, 0)
            select(marks[next].id)
        }
        // 截图检查用：模拟按住条的中间不动，打开放大镜。
        .onReceive(NotificationCenter.default.publisher(for: PerfProbe.action)) { note in
            if note.object as? String == "railLoupe", !marks.isEmpty {
                let index = marks.count / 2
                touch = Touch(startY: 300, lastY: 300, fine: (index, 300), fineIndex: index)
                pick(index)
            }
            if note.object as? String == "railLoupeEnd" { touch = nil; picked = nil }
        }
    }

    private func drag(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let y = value.location.y
                guard var current = touch else {
                    touch = Touch(startY: y, lastY: y)
                    pick(nearest(y / max(1, height)))
                    startHold()
                    return
                }
                current.lastY = y
                if let fine = current.fine {
                    let index = min(max(0, fine.index + Int(((y - fine.originY) / Self.step).rounded())), marks.count - 1)
                    current.fineIndex = index
                    pick(index)
                } else {
                    if abs(y - current.startY) > 8 { current.moved = true; hold?.cancel() }
                    pick(nearest(y / max(1, height)))
                }
                touch = current
            }
            .onEnded { _ in
                hold?.cancel()
                touch = nil
                picked = nil
            }
    }

    /// 按住不动 0.35 秒：打开放大镜，从现在选中的那条开始。
    private func startHold() {
        hold?.cancel()
        hold = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, var current = touch, !current.moved, current.fine == nil else { return }
            let index = picked.flatMap { id in marks.firstIndex { $0.id == id } } ?? nearest(current.lastY)
            current.fine = (index, current.lastY)
            current.fineIndex = index
            touch = current
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
    @ObservedObject var positions: LogPositions
    let height: CGFloat

    var body: some View {
        if let current = positions.current, let mark = marks.first(where: { $0.id == current }) {
            Capsule().fill(Palette.accent)
                .frame(width: 15, height: 5)
                .overlay(Capsule().stroke(Palette.background, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                .position(x: EntryRail.width - 9, y: height * mark.position)
                .animation(Motion.adapt(.snappy(duration: 0.2)), value: current)
        }
    }
}

/// 放大镜：选中的那条和前后各三条，时刻 + 第一行。
private struct RailLoupe: View {
    static let rows = 7
    static let rowHeight: CGFloat = 34
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
                        RoundedRectangle(cornerRadius: 1).fill(mark.color).frame(width: 3, height: 16)
                        Text(mark.label).font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(offset == 0 ? Palette.accent : Palette.muted)
                            .fixedSize()
                        Text(mark.preview.isEmpty ? " " : mark.preview).font(.caption)
                            .foregroundStyle(offset == 0 ? Palette.ink : Palette.muted)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: Self.rowHeight)
                    .background(offset == 0 ? Palette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .opacity(1 - Double(abs(offset)) * 0.12)
                } else {
                    Color.clear.frame(height: Self.rowHeight)
                }
            }
        }
        .padding(6)
        .frame(width: 250)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.line.opacity(0.7), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

/// 页面现在看到哪一条：每条日志记下自己在内容里的位置（只在排版变了时），滚动时按位置找出顶上那一条。
/// 只有节奏条的滑块订阅它，滚动不会让整页重算。
@MainActor
final class LogPositions: ObservableObject {
    nonisolated static let space = "log-positions"
    @Published private(set) var current: UUID?
    private var tops: [UUID: CGFloat] = [:]

    func record(_ id: UUID, top: CGFloat) { tops[id] = top }

    func update(_ view: UIScrollView) {
        let line = view.contentOffset.y + view.adjustedContentInset.top + 12
        let above = tops.filter { $0.value <= line }
        let best = above.max { $0.value < $1.value }?.key ?? tops.min { $0.value < $1.value }?.key
        if best != current { current = best }
    }

    func reset() {
        tops = [:]
        current = nil
    }
}

private struct LogPositionsKey: EnvironmentKey {
    static let defaultValue: LogPositions? = nil
}

extension EnvironmentValues {
    var logPositions: LogPositions? {
        get { self[LogPositionsKey.self] }
        set { self[LogPositionsKey.self] = newValue }
    }
}

extension View {
    /// 一条日志：把自己在内容里的位置记给 `LogPositions`（没有节奏条的页面什么也不做）。
    @ViewBuilder func recordsLogPosition(_ id: UUID, in positions: LogPositions?) -> some View {
        if let positions {
            onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(LogPositions.space)).minY } action: { positions.record(id, top: $0) }
        } else {
            self
        }
    }

    /// 页面右边放节奏条、不显示滚动条：`positions` 跟着滚动算出顶上那一条。
    func entryRail(_ marks: [RailMark], spans: [ClosedRange<CGFloat>] = [], ticks: [RailTick] = [],
                   positions: LogPositions, edges: ScrollEdges) -> some View {
        scrollIndicators(.hidden)
            .environment(\.logPositions, positions)
            .overlay(alignment: .topTrailing) {
                if !marks.isEmpty {
                    EntryRail(marks: marks, spans: spans, ticks: ticks, positions: positions) { edges.reveal($0.uuidString) }
                        .padding(.trailing, 4)
                        .padding(.top, 8)
                        .padding(.bottom, 96)
                }
            }
            .onAppear {
                positions.reset()
                edges.scrolled = { [positions] in positions.update($0) }
            }
    }
}

/// 笔记页的节奏条：一条笔记一道刻度，从上到下按先后均匀排开（跨很多天，按时间放会挤成几团），旁边标几个日期。
enum NotesRhythm {
    static func marks(_ notes: [JournalStore.LoggedLog]) -> [RailMark] {
        let ordered = ordered(notes)
        let last = CGFloat(max(1, ordered.count - 1))
        return ordered.enumerated().map { index, logged in
            RailMark(id: logged.id, position: ordered.count == 1 ? 0 : CGFloat(index) / last, color: LogStyle.color(logged.log),
                     emphasized: logged.log.isFocusMarker,
                     label: DayText.short(logged.date) + " " + DayText.time(logged.log.createdAt), preview: RailMark.preview(logged.log))
        }
    }

    /// 每天第一条旁边标日期，太挤的省掉。
    static func ticks(_ notes: [JournalStore.LoggedLog]) -> [RailTick] {
        let ordered = ordered(notes)
        let last = CGFloat(max(1, ordered.count - 1))
        var ticks: [RailTick] = []
        var day: String?
        var lastMonth: Int?
        for (index, logged) in ordered.enumerated() where logged.key != day {
            day = logged.key
            let position = ordered.count == 1 ? 0 : CGFloat(index) / last
            if let previous = ticks.last, position - previous.position < 0.14 { continue }
            // 只写几号，换月时（和第一个）才带上月份。
            let month = JournalDates.calendar.component(.month, from: logged.date)
            let showsMonth = ticks.isEmpty || month != lastMonth
            lastMonth = month
            ticks.append(RailTick(position: position, text: showsMonth ? DayText.short(logged.date) : "\(JournalDates.calendar.component(.day, from: logged.date))"))
        }
        return ticks
    }

    /// 和 `LogTimeline` 一样的先后：先按天，一天里按时刻。
    private static func ordered(_ notes: [JournalStore.LoggedLog]) -> [JournalStore.LoggedLog] {
        notes.sorted { $0.key == $1.key ? $0.log.createdAt < $1.log.createdAt : $0.key < $1.key }
    }
}

extension View {
    /// 笔记页第一次打开时停在最下面（最新的笔记）。懒加载的行高是估算的，系统的「从底部开始」会差一截，
    /// 所以出现后再按真实高度落到底。返回这一页时不再跳。
    func startsAtBottom(_ enabled: Bool, edges: ScrollEdges) -> some View {
        modifier(StartsAtBottom(enabled: enabled, edges: edges))
    }
}

private struct StartsAtBottom: ViewModifier {
    let enabled: Bool
    let edges: ScrollEdges
    @State private var done = false

    func body(content: Content) -> some View {
        Group {
            if enabled, #available(iOS 18.0, *) {
                content.defaultScrollAnchor(.bottom, for: .initialOffset)
            } else {
                content
            }
        }
        .task {
            guard enabled, !done else { return }
            done = true
            try? await Task.sleep(nanoseconds: 30_000_000)
            edges.jump(.bottom)
        }
    }
}
