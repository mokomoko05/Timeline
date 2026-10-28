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

    func testJournalWindowScrollingWithDataCopy() throws {
        guard let source = ProcessInfo.processInfo.environment["TIMELINE_SCROLL_PROBE_DATA"] else { throw XCTSkip("probe only") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source).appendingPathComponent("journal.json"),
                                         to: directory.appendingPathComponent("journal.json"))
        let store = JournalStore(directory: directory)
        let date = JournalDates.calendar.startOfDay(for: Date())
        let workspace = NotesWorkspaceNavigation()
        workspace.open(.journal, date: date)
        let view = UnifiedNotesView(store: store, workspace: workspace, nav: NotesNavigation(defaults: InMemoryDefaults()),
                                    close: {}, reveal: { _ in }, openDay: { _ in })
            .environment(\.typography, AppTypography(scale: 1.1, lineSpacing: 0))
        try probe("journal data copy", store: store, view, size: NSSize(width: 1424, height: 876), wheel: true)
    }

    func testLongNotesWindowScrolling() throws {
        guard ProcessInfo.processInfo.environment["TIMELINE_SCROLL_PROBE"] != nil else { throw XCTSkip("probe only") }
        let (store, date) = try Self.makeStore(logs: 90, longEvery: 3)
        let task = try XCTUnwrap(store.addParsedTodo("Long notes", on: date))
        store.setLogTask(task.id, forLogs: Set(store.allLogs().map(\.id)))
        let navigation = NotesNavigation(defaults: InMemoryDefaults())
        navigation.open(task: task.id)
        let workspace = NotesWorkspaceNavigation()
        let view = UnifiedNotesView(store: store, workspace: workspace, nav: navigation,
                                    close: {}, reveal: { _ in }, openDay: { _ in })
            .environment(\.typography, AppTypography(scale: 1.1, lineSpacing: 0))
        try probe("long notes 90", store: store, view, size: NSSize(width: 1424, height: 876), wheel: true)
    }

    private func probe<V: View>(_ label: String, store: JournalStore, _ view: V, size: NSSize = NSSize(width: 900, height: 700), wheel: Bool = false) throws {
        let start = CACurrentMediaTime()
        let root = view.environmentObject(WorkspaceInteraction()).environmentObject(ToastCenter())
        let host = NSHostingView(rootView: AnyView(root.frame(width: size.width, height: size.height)))
        let window = QuietWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        Self.keepAlive += [window, host, store]
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        print(String(format: "PROBE %@ open: %.0f ms", label, (CACurrentMediaTime() - start) * 1000))
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let scroll = try XCTUnwrap(scrollViews(in: host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        if wheel {
            func textSources(_ view: NSView) -> [String] {
                if let text = view as? InteractiveTaskText, let source = text.source { return [source] }
                return view.subviews.flatMap(textSources)
            }
            let sources = Set(textSources(host))
            if let entry = store.allLogs().last(where: { sources.contains(LogEventStyle.body($0.log)) && $0.log.hasEditableText }) {
                print("PROBE preparing hovered editor")
                InlineMarkdownEditor.shared.begin(entry.log, on: entry.date, store: store, at: nil,
                                                   fontSize: 14.3, lineSpacing: 0, dark: false, prepare: true)
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                host.layoutSubtreeIfNeeded()
                print("PROBE hovered editor prepared")
            }
            defer { InlineMarkdownEditor.shared.finish() }
            for index in 0..<120 {
                let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                                 wheel1: index < 60 ? 60 : -60, wheel2: 0, wheel3: 0))
                let start = CACurrentMediaTime()
                scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                host.layoutSubtreeIfNeeded()
                if index % 10 == 0 { print(String(format: "PROBE wheel %d: %.1fms", index, (CACurrentMediaTime() - start) * 1000)) }
            }
        }
        Self.report(label + " first pass", Self.run(scroll, host: host))
        Self.report(label + " second pass", Self.run(scroll, host: host))
        window.close()
    }
}
