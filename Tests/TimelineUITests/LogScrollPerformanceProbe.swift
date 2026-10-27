import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

/// 长日志滚动的开销和抖动：像滚轮一样一小段一小段地滚，记每一步排版 + 绘制花的时间，
/// 以及滚完之后位置有没有被列表自己挪动（估算行高和真实行高不一致时会跳）。`TIMELINE_SCROLL_PROBE=1` 时才运行。
@MainActor
final class LogScrollPerformanceProbe: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    static func longLog(_ index: Int) -> String {
        var lines = ["## 第 \(index) 段记录", "", "今天把同步的问题查清楚了，记录一下过程和结论，方便以后回头看。"]
        for item in 1...12 {
            lines.append("- 第 \(item) 点：**重点** 在于 `cache` 的失效时机，还有 [链接](https://example.com/\(item)) 和一些中文说明文字，让这一行足够长，会折成两三行显示。")
        }
        lines += ["", "```swift", "let value = compute(\(index))", "print(value)", "```", "", "> 引用一段别人的话，作为参考。", "", "结尾一段普通文字。"]
        return lines.joined(separator: "\n")
    }

    static func makeStore(logs: Int, longEvery: Int = 3) throws -> (JournalStore, Date) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = JournalStore(directory: directory)
        let day = JournalDates.calendar.startOfDay(for: Date())
        for index in 0..<logs {
            let text = index % longEvery == 0 ? longLog(index) : "第 \(index) 条短日志，写一点普通内容 #标签"
            _ = try store.quickLog(text, on: day, now: day.addingTimeInterval(Double(index + 1) * 60))
        }
        return (store, day)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }

    /// 滚一遍：每步 `step` 点，下去再上来。返回每步耗时（毫秒）和被列表挪动的次数 / 最大挪动量。
    static func run(_ scroll: NSScrollView, host: NSView, step: CGFloat = 40) -> (times: [Double], jumps: Int, worstJump: CGFloat, heights: Set<Int>) {
        var times: [Double] = []
        var jumps = 0
        var worst: CGFloat = 0
        var heights = Set<Int>()
        func go(_ y: CGFloat) {
            let start = CACurrentMediaTime()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            RunLoop.main.run(until: Date())
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            times.append((CACurrentMediaTime() - start) * 1000)
            let actual = scroll.contentView.bounds.minY
            if abs(actual - y) > 0.5 { jumps += 1; worst = max(worst, abs(actual - y)) }
            heights.insert(Int(scroll.documentView?.frame.height ?? 0))
        }
        var y: CGFloat = 0
        while y + scroll.contentView.bounds.height < (scroll.documentView?.frame.height ?? 0) - 1 {
            y += step
            go(y)
        }
        while y > 0 {
            y = max(0, y - step)
            go(y)
        }
        return (times, jumps, worst, heights)
    }

    static func report(_ label: String, _ result: (times: [Double], jumps: Int, worstJump: CGFloat, heights: Set<Int>)) {
        let sorted = result.times.sorted()
        guard !sorted.isEmpty else { print("PROBE \(label): no steps"); return }
        let slow = sorted.filter { $0 > 16.7 }.count
        print(String(format: "PROBE %@: %d steps, median %.1f ms, p95 %.1f ms, max %.1f ms, >16.7ms %d; jumps %d (worst %.0f pt); document heights seen %d",
                     label, sorted.count, sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)], sorted.last!, slow,
                     result.jumps, result.worstJump, result.heights.count))
    }

    func testDailyLogScrolling() throws {
        guard ProcessInfo.processInfo.environment["TIMELINE_SCROLL_PROBE"] != nil else { throw XCTSkip("probe only") }
        // 普通的一天（整页一次排好）和特别长的一天（懒加载）。
        for (count, longEvery) in [(30, 5), (90, 3)] {
            let (store, day) = try Self.makeStore(logs: count, longEvery: longEvery)
            try probe("journal \(count)", store: store, DailyLogView(store: store, date: day, collapse: nil, autoFocus: false))
            try probe("journal \(count) reopened", store: store, DailyLogView(store: store, date: day, collapse: nil, autoFocus: false))
        }
    }

    /// 笔记窗口里的日记（`UnifiedJournalView`）：一天里很多条长日志。
    func testJournalWindowScrolling() throws {
        guard ProcessInfo.processInfo.environment["TIMELINE_SCROLL_PROBE"] != nil else { throw XCTSkip("probe only") }
        for (count, longEvery) in [(30, 5), (90, 3)] {
            let (store, day) = try Self.makeStore(logs: count, longEvery: longEvery)
            try probe("notes journal \(count)", store: store, UnifiedJournalView(store: store, date: .constant(day), navigationRequest: 0))
        }
    }

    private func probe<V: View>(_ label: String, store: JournalStore, _ view: V) throws {
        let start = CACurrentMediaTime()
        let root = view.environmentObject(WorkspaceInteraction()).environmentObject(ToastCenter())
        let host = NSHostingView(rootView: AnyView(root.frame(width: 900, height: 700)))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        Self.keepAlive += [window, host, store]
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        print(String(format: "PROBE %@ open: %.0f ms", label, (CACurrentMediaTime() - start) * 1000))
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let scroll = try XCTUnwrap(scrollViews(in: host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        Self.report(label + " first pass", Self.run(scroll, host: host))
        Self.report(label + " second pass", Self.run(scroll, host: host))
        window.close()
    }
}
