import AppKit
import SwiftUI
import DayleafCore

/// 月历列宽只取决于外层视口，给滚动条固定留位；出现滚动条时不会再次改变列宽。
struct CalendarGridMetrics {
    static let scrollbarGutter: CGFloat = 16
    let columnWidth: CGFloat
    let weekdayHeight: CGFloat
    let weekHeights: [CGFloat]

    init(size: CGSize, counts: [Int], scale: Double) {
        columnWidth = max(1, floor((size.width - 4 - Self.scrollbarGutter - 6 * 6) / 7))
        weekdayHeight = ceil(max(18, 14 * scale))
        let weeks = max(1, (counts.count + 6) / 7)
        let available = floor((size.height - weekdayHeight - 4 - 6 * CGFloat(weeks)) / CGFloat(weeks))
        let header = ceil(max(18, 15 * scale)) + 12
        weekHeights = stride(from: 0, to: counts.count, by: 7).map { start in
            let items = counts[start..<min(start + 7, counts.count)].max() ?? 0
            return max(80, available, ceil(header + CGFloat(items) * (22 * scale + 3)))
        }
    }
}

/// 点击月份标题弹出：快速跳到任意年月。
struct MonthJumper: View {
    @Environment(\.typography) private var typography
    @Environment(\.locale) private var locale
    let current: Date
    let jump: (Date) -> Void
    @State private var year: Int

    init(current: Date, jump: @escaping (Date) -> Void) {
        self.current = current
        self.jump = jump
        _year = State(initialValue: JournalDates.calendar.component(.year, from: current))
    }

    var body: some View {
        let calendar = JournalDates.calendar
        let currentYear = calendar.component(.year, from: current)
        let currentMonth = calendar.component(.month, from: current)
        let formatter = DateFormatter()
        formatter.locale = locale
        return VStack(spacing: 10) {
            HStack {
                Button { year -= 1 } label: { Image(systemName: "chevron.left") }.buttonStyle(HitAreaButtonStyle()).accessibilityLabel("上一年")
                Spacer()
                Text(String(year)).font(.system(size: typography.pt(14), weight: .semibold, design: .rounded))
                Spacer()
                Button { year += 1 } label: { Image(systemName: "chevron.right") }.buttonStyle(HitAreaButtonStyle()).accessibilityLabel("下一年")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(1...12, id: \.self) { month in
                    let selected = year == currentYear && month == currentMonth
                    Button { if let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) { jump(date) } } label: {
                        Text(formatter.shortStandaloneMonthSymbols[month - 1]).font(.system(size: typography.pt(13), weight: selected ? .semibold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(selected ? Palette.accent : Palette.soft.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(selected ? Palette.onAccent : Palette.ink)
                    }.buttonStyle(.plain)
                }
            }
            Button("回到本月") { jump(Date()) }.buttonStyle(HitAreaButtonStyle()).font(.system(size: typography.pt(12))).foregroundStyle(Palette.accent)
        }
        .padding(14).frame(width: 240)
    }
}

/// 在日历区域内用触控板横向轻扫切换月份；纵向滚动不受影响。
struct MonthSwipeCatcher: NSViewRepresentable {
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> SwipeView {
        let view = SwipeView()
        view.install()
        return view
    }

    func updateNSView(_ view: SwipeView, context: Context) { view.onSwipe = onSwipe }
    static func dismantleNSView(_ view: SwipeView, coordinator: ()) { view.remove() }

    final class SwipeView: NSView {
        var onSwipe: ((Int) -> Void)?
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var fired = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window, window.attachedSheet == nil, event.hasPreciseScrollingDeltas else { return }
            if event.phase == .began || event.phase == .mayBegin { accumulated = 0; fired = false }
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5 {
                accumulated += event.scrollingDeltaX
                if !fired, abs(accumulated) > 70 {
                    fired = true
                    onSwipe?(accumulated < 0 ? 1 : -1)
                }
            }
            if event.phase == .ended || event.phase == .cancelled { accumulated = 0; fired = false }
        }
    }
}
