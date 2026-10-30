import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class LogScrollTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []
    /// 第一条上面是列表的内边距和顶部锚点。
    private static let firstEntryTop: CGFloat = 21

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        var result: [NSScrollView] = []
        if let scroll = view as? NSScrollView { result.append(scroll) }
        for sub in view.subviews { result += scrollViews(in: sub) }
        return result
    }

    private func open(logCount: Int, height: CGFloat = 640, day: Date? = nil) throws -> (NSScrollView, NSHostingView<AnyView>) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let day = day ?? JournalDates.calendar.date(byAdding: .day, value: -1, to: JournalDates.calendar.startOfDay(for: Date()))!
        for index in 0..<logCount {
            _ = try store.quickLog("第 \(index) 条日志，稍微写长一点让它占满一行，测试滚动位置", on: day, now: day.addingTimeInterval(Double(index + 1)))
        }
        let view = UnifiedJournalView(store: store, workspace: NotesWorkspaceNavigation(date: day))
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
        // 日志列表是最高的那个滚动视图。
        let scroll = try XCTUnwrap(scrollViews(in: host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        return (scroll, host)
    }

    /// 往日从当天第一条开始读。
    func testPastLongDayOpensAtTheTopAndStaysThereWithoutScrolling() throws {
        let (scroll, host) = try open(logCount: 300)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height * 3, "内容远比窗口长")
        XCTAssertEqual(scroll.contentView.bounds.minY, Self.firstEntryTop, accuracy: 1, "打开时停在第一条")
        // 再等一会儿：不能“顿一下然后自己滚到底”。
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.minY, Self.firstEntryTop, accuracy: 1, "之后也不会自己滚动")
    }

    /// 今天从最新一条开始（接着写）。
    func testTodayLongDayOpensAtTheNewestEntry() throws {
        let (scroll, _) = try open(logCount: 300, day: JournalDates.calendar.startOfDay(for: Date()))
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertEqual(scroll.contentView.bounds.maxY, document.frame.height - 20, accuracy: 2, "打开时停在末尾（底部内边距之上）")
    }

    func testShortDayIsTopAlignedWithNothingScrolledAway() throws {
        let (scroll, _) = try open(logCount: 3)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1, "内容比窗口短，不会被滚走，一眼能看到全部日志")
    }

    func testEmptyDayShowsAnEmptyListFromTheTop() throws {
        let (scroll, _) = try open(logCount: 0)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
    }
}
