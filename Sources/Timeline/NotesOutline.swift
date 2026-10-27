import AppKit
import SwiftUI
import TimelineCore

/// 笔记的时间线目录：按月分组的日期，每一天有几条。和页面里从上到下的顺序一致（从早到晚）。
struct NotesTimelineIndex {
    struct Day: Identifiable, Equatable {
        let key: String
        let date: Date
        let count: Int
        /// 这一天按时间最早的一条，跳转时定位用。
        let firstNoteID: UUID
        var id: String { key }
    }

    struct Month: Identifiable, Equatable {
        let id: String
        let date: Date
        let days: [Day]
        var count: Int { days.reduce(0) { $0 + $1.count } }
    }

    static func months(_ notes: [JournalStore.LoggedLog]) -> [Month] {
        let calendar = JournalDates.calendar
        let days = Dictionary(grouping: notes, by: \.key).map { key, items -> Day in
            let first = items.min { $0.log.createdAt < $1.log.createdAt }!
            return Day(key: key, date: items[0].date, count: items.count, firstNoteID: first.id)
        }.sorted { $0.key < $1.key }
        var months: [Month] = []
        for day in days {
            let parts = calendar.dateComponents([.year, .month], from: day.date)
            let id = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
            if let last = months.last, last.id == id {
                months[months.count - 1] = Month(id: id, date: last.date, days: last.days + [day])
            } else {
                months.append(Month(id: id, date: calendar.date(from: parts) ?? day.date, days: [day]))
            }
        }
        return months
    }

    static func dayAnchor(_ key: String) -> String { "day-" + key }
}

enum NotesOutlineMode: String {
    case chapters, timeline
}

/// 右侧目录：按待办分章的笔记本可以在「章节」和「时间」之间切换；没有待办的笔记本、单个待办的笔记只有时间线。
struct NotesOutlinePanel<Chapters: View>: View {
    let months: [NotesTimelineIndex.Month]
    /// nil 表示这一页没有章节可列。
    let chapterCount: Int?
    @Binding var mode: NotesOutlineMode
    var floating = false
    let jump: (NotesTimelineIndex.Day) -> Void
    let close: () -> Void
    @ViewBuilder let chapters: () -> Chapters

    var body: some View {
        let showsChapters = chapterCount != nil && mode == .chapters
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let chapterCount {
                    PillSegmentedControl(selection: $mode, segments: [
                        .init(value: NotesOutlineMode.chapters, title: "章节", count: chapterCount),
                        .init(value: .timeline, title: "时间"),
                    ], fillsWidth: true, height: 24, fontSize: 11)
                } else {
                    Text("时间线").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                    Text("\(months.reduce(0) { $0 + $1.days.count }) 天").font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(Palette.muted)
                    Spacer(minLength: 0)
                }
                if floating {
                    Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20) }
                        .buttonStyle(HitAreaButtonStyle(compact: true)).foregroundStyle(Palette.muted)
                        .help("关闭目录").accessibilityLabel("关闭目录")
                }
            }
            if showsChapters {
                chapters()
            } else if months.isEmpty {
                Text("还没有笔记").font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 4)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        NotesTimelineList(months: months, jump: jump)
                    }
                    // 时间线目录从最新的日期打开，和笔记页一样「最新在下面」。
                    .onAppear { if let last = months.last?.days.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 12)
        .frame(width: 210)
        .frame(maxHeight: floating ? 420 : .infinity, alignment: .top)
        .modifier(OutlineSurface(floating: floating))
        .accessibilityElement(children: .contain).accessibilityLabel("目录")
    }
}

/// 目录里的时间线：月份和日期串在同一根竖线上（和主界面的时间轴一样，日期是线上的结）。
/// 点月份把这个月的一串日期收起 / 展开；点日期跳到那一天。
struct NotesTimelineList: View {
    let months: [NotesTimelineIndex.Month]
    let jump: (NotesTimelineIndex.Day) -> Void
    @State private var folded: Set<String> = []

    /// 线在行里的横向位置（圆点的中心）。
    static let lineX: CGFloat = 12

    private enum Item: Identifiable {
        case month(NotesTimelineIndex.Month)
        case day(NotesTimelineIndex.Day)
        var id: String {
            switch self {
            case .month(let month): return "month-" + month.id
            case .day(let day): return day.id
            }
        }
    }

    private var items: [Item] {
        months.flatMap { month -> [Item] in
            [.month(month)] + (folded.contains(month.id) ? [] : month.days.map(Item.day))
        }
    }

    var body: some View {
        let items = items
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Group {
                    switch item {
                    case .month(let month): monthRow(month)
                    case .day(let day): dayRow(day)
                    }
                }
                .background(alignment: .leading) { thread(top: index > 0, bottom: index < items.count - 1) }
                .id(item.id)
            }
        }
    }

    /// 穿过这一行的那段线：第一行只画下半段，最后一行只画上半段，整串就连成一根。
    private func thread(top: Bool, bottom: Bool) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(top ? Palette.line : .clear)
            Rectangle().fill(bottom ? Palette.line : .clear)
        }
        .frame(width: 1.5)
        .padding(.leading, Self.lineX - 0.75)
    }

    private func monthRow(_ month: NotesTimelineIndex.Month) -> some View {
        let isFolded = folded.contains(month.id)
        return Button {
            withAnimation(Motion.quick) {
                if isFolded { folded.remove(month.id) } else { folded.insert(month.id) }
            }
        } label: {
            HStack(spacing: 6) {
                // 月份是线上大一号的空心结。
                Circle().strokeBorder(Palette.muted, lineWidth: 1.5)
                    .background(Circle().fill(Palette.background))
                    .frame(width: 9, height: 9)
                    .frame(width: Self.lineX * 2 - 6)
                Text(month.date, format: .dateTime.year().month(.wide))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.muted)
                    .rotationEffect(.degrees(isFolded ? -90 : 0))
                Spacer(minLength: 2)
                Text("\(month.count)").font(.system(size: 10)).monospacedDigit().foregroundStyle(Palette.muted)
            }
            .padding(.leading, 3).padding(.trailing, 6).padding(.top, 8).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isFolded ? "展开这个月" : "收起这个月")
        .accessibilityLabel(AppLocalizedFormat("%@，%lld 条笔记", month.date.formatted(.dateTime.year().month(.wide)), month.count))
        .accessibilityValue(isFolded ? Text("已收起") : Text("已展开"))
    }

    private func dayRow(_ day: NotesTimelineIndex.Day) -> some View {
        let today = JournalDates.calendar.isDateInToday(day.date)
        return Button { jump(day) } label: {
            HStack(spacing: 6) {
                ZStack {
                    if today { Circle().fill(Palette.accent.opacity(0.22)).frame(width: 11, height: 11) }
                    Circle().fill(today ? Palette.accent : Palette.muted.opacity(0.7)).frame(width: 5, height: 5)
                }
                .frame(width: Self.lineX * 2 - 6)
                Text(day.date.relativeLabel).font(.system(size: 12)).foregroundStyle(today ? Palette.accent : Palette.ink)
                Text(day.date, format: .dateTime.weekday(.abbreviated)).font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer(minLength: 2)
                Text("\(day.count)").font(.system(size: 10)).monospacedDigit().foregroundStyle(Palette.muted)
            }
            .padding(.leading, 3).padding(.trailing, 6).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).raisedOnHover(radius: 5)
        .help(day.key)
        .accessibilityLabel(AppLocalizedFormat("%@，%lld 条笔记", day.key, day.count))
    }
}

private struct OutlineSurface: ViewModifier {
    let floating: Bool
    func body(content: Content) -> some View {
        if floating { content.floatingPanelSurface() } else { content.background(Palette.background) }
    }
}

// MARK: - 回到顶部 / 跳到最新

enum NotesScrollEdge { case top, bottom }

/// 滚动区域右下角的「回到顶部」「跳到最新」：离开顶部 / 底部一段距离才出现。
/// 只有这一层订阅滚动位置（`ScrollTracker` 直接听 NSScrollView）：滚动时整页笔记不重算。
struct NotesScrollButtons: View {
    @ObservedObject var tracker: ScrollTracker
    let scroll: (NotesScrollEdge) -> Void

    var body: some View {
        VStack(spacing: 6) {
            if tracker.showsTop {
                button("arrow.up", "回到顶部") { scroll(.top) }
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
            if tracker.showsBottom {
                button("arrow.down", "跳到最新") { scroll(.bottom) }
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
    }

    private func button(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Palette.line.opacity(0.8), lineWidth: Metrics.hairline))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(HitAreaButtonStyle(compact: true, pressedScale: 0.92))
        .foregroundStyle(Palette.ink)
        .help(LocalizedStringKey(title)).accessibilityLabel(LocalizedStringKey(title))
    }
}
