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
                    Picker("", selection: $mode) {
                        Text("章节 \(chapterCount)").tag(NotesOutlineMode.chapters)
                        Text("时间").tag(NotesOutlineMode.timeline)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
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
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(months) { month in
                                HStack {
                                    Text(month.date, format: .dateTime.year().month(.wide))
                                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink)
                                    Spacer()
                                    Text("\(month.count)").font(.system(size: 10)).monospacedDigit().foregroundStyle(Palette.muted)
                                }
                                .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 2)
                                ForEach(month.days) { day in dayRow(day).id(day.id) }
                            }
                        }
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

    private func dayRow(_ day: NotesTimelineIndex.Day) -> some View {
        let today = JournalDates.calendar.isDateInToday(day.date)
        return Button { jump(day) } label: {
            HStack(spacing: 6) {
                Circle().fill(today ? Palette.accent : Palette.muted.opacity(0.5)).frame(width: 5, height: 5)
                Text(day.date.relativeLabel).font(.system(size: 12)).foregroundStyle(today ? Palette.accent : Palette.ink)
                Text(day.date, format: .dateTime.weekday(.abbreviated)).font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer(minLength: 2)
                Text("\(day.count)").font(.system(size: 10)).monospacedDigit().foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
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

/// 笔记列表首尾的两个标记，回报它们相对滚动区域的位置。
private struct NotesScrollEdgeKey: PreferenceKey {
    struct Value: Equatable { var top: CGFloat = -.infinity; var bottom: CGFloat = .infinity }
    static var defaultValue = Value()
    static func reduce(value: inout Value, nextValue: () -> Value) {
        let next = nextValue()
        if next.top != -.infinity { value.top = next.top }
        if next.bottom != .infinity { value.bottom = next.bottom }
    }
}

enum NotesScrollEdge { case top, bottom }

extension View {
    /// 放在笔记列表最上面 / 最下面的那个占位视图上。
    func notesScrollEdge(_ edge: NotesScrollEdge) -> some View {
        background(GeometryReader { proxy in
            let frame = proxy.frame(in: .named(NotesScrollButtons.space))
            Color.clear.preference(key: NotesScrollEdgeKey.self,
                                   value: edge == .top ? .init(top: frame.minY) : .init(bottom: frame.maxY))
        })
    }

    /// 滚动区域右下角的「回到顶部」「跳到最新」：离开顶部 / 底部一段距离才出现。
    func notesScrollButtons(scroll: @escaping (NotesScrollEdge) -> Void) -> some View {
        modifier(NotesScrollButtons(scroll: scroll))
    }
}

/// 只有这一层持有按钮的显示状态：滚动时首尾标记的位置每帧都在变，但只在按钮出现 / 消失时刷新这一层，不重算整页笔记。
struct NotesScrollButtons: ViewModifier {
    static let space = "notes-scroll"
    let scroll: (NotesScrollEdge) -> Void
    @State private var showsTop = false
    @State private var showsBottom = false
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: Self.space)
            .background(GeometryReader { proxy in
                Color.clear.onAppear { height = proxy.size.height }
                    .onChange(of: proxy.size.height) { height = $0 }
            })
            .onPreferenceChange(NotesScrollEdgeKey.self) { value in
                let top = value.top < -240
                let bottom = value.bottom > height + 160
                if top != showsTop { withAnimation(Motion.quick) { showsTop = top } }
                if bottom != showsBottom { withAnimation(Motion.quick) { showsBottom = bottom } }
            }
            .overlay(alignment: .bottomTrailing) {
                VStack(spacing: 6) {
                    if showsTop {
                        button("arrow.up", "回到顶部") { scroll(.top) }
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                    if showsBottom {
                        button("arrow.down", "跳到最新") { scroll(.bottom) }
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                }
                .padding(.trailing, 16).padding(.bottom, 14)
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
