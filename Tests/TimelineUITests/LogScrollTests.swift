import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class LogScrollTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        var result: [NSScrollView] = []
        if let scroll = view as? NSScrollView { result.append(scroll) }
        for sub in view.subviews { result += scrollViews(in: sub) }
        return result
    }

    private func open(logCount: Int, height: CGFloat = 640) throws -> (NSScrollView, NSHostingView<AnyView>) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let day = JournalDates.calendar.startOfDay(for: Date())
        for index in 0..<logCount {
            _ = try store.quickLog("第 \(index) 条日志，稍微写长一点让它占满一行，测试滚动位置", on: day, now: day.addingTimeInterval(Double(index + 1)))
        }
        let view = DailyLogView(store: store, date: day, collapse: nil, autoFocus: false)
            .environmentObject(WorkspaceInteraction()).environmentObject(ToastCenter())
        let host = NSHostingView(rootView: AnyView(view.frame(width: 1000, height: height)))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        Self.keepAlive += [window, host]
        // 给惰性布局和延迟校正留出时间。
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        host.layoutSubtreeIfNeeded()
        // 日志列表是最高的那个滚动视图（复盘区的文本滚动视图也在里面）。
        let scroll = try XCTUnwrap(scrollViews(in: host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        return (scroll, host)
    }

    func testLongDayOpensAtTheTopAndStaysThereWithoutScrolling() throws {
        let (scroll, host) = try open(logCount: 300)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height * 3, "内容远比窗口长")
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1, "打开时停在顶部")
        // 再等一会儿：不能“顿一下然后自己滚到底”。
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1, "之后也不会自己滚动")
    }

    func testShortDayIsTopAlignedWithNothingScrolledAway() throws {
        let (scroll, _) = try open(logCount: 3)
        let document = try XCTUnwrap(scroll.documentView)
        let visible = scroll.contentView.bounds
        XCTAssertEqual(visible.minY, 0, accuracy: 1, "内容比窗口短，不会被滚走，一眼能看到全部日志")
        XCTAssertGreaterThanOrEqual(document.frame.height, visible.height - 1, "内容区至少和窗口一样高")
    }

    func testEmptyDayShowsAnEmptyListFromTheTop() throws {
        let (scroll, _) = try open(logCount: 0)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
    }
}
