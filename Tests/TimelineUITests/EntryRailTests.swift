import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

/// 日记、笔记页右边的节奏条：代替滚动条；滚动时跟踪页面顶上是哪一条，「回到顶部」「跳到最新」按滚动位置出现。
@MainActor
final class EntryRailTests: XCTestCase {
    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }

    private func settle(_ host: NSView) {
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testTrackerFollowsScrollingWithoutSwiftUIGeometryPerFrame() throws {
        let tracker = ScrollTracker()
        let ids = (0..<40).map { _ in UUID() }
        let root = ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(ids.enumerated()), id: \.offset) { index, id in
                    Text("第 \(index) 条").frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                        .recordsScrollPosition(id, in: tracker)
                }
            }
            .tracksScroll(tracker)
        }
        .frame(width: 300, height: 400)
        let host = NSHostingView(rootView: root)
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        settle(host)
        let scroll = try XCTUnwrap(scrollViews(in: host).first)
        XCTAssertEqual(tracker.current, ids[0], "一开始顶上是第一条")
        XCTAssertFalse(tracker.showsTop)
        XCTAssertTrue(tracker.showsBottom, "离底部很远：显示「跳到最新」")

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 50 * 10 + 5))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(host)
        XCTAssertEqual(tracker.current, ids[10], "滚到第 10 条：滑块跟着到第 10 条")
        XCTAssertTrue(tracker.showsTop, "离开顶部：显示「回到顶部」")

        let bottom = (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(host)
        XCTAssertFalse(tracker.showsBottom, "到底了：不再显示「跳到最新」")
    }

    func testJournalShowsTheRailInsteadOfAScrollBar() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let day = JournalDates.calendar.startOfDay(for: Date())
        for index in 0..<30 {
            _ = try store.quickLog("第 \(index) 条日志\n\n多写一行，让页面长到需要滚动。", on: day, now: day.addingTimeInterval(Double(index + 1) * 600))
        }
        let root = UnifiedJournalView(store: store, date: .constant(day), navigationRequest: 0)
            .environmentObject(WorkspaceInteraction()).environmentObject(ToastCenter())
            .frame(width: 900, height: 600)
        let host = NSHostingView(rootView: root)
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        settle(host)
        let scroll = try XCTUnwrap(scrollViews(in: host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        XCTAssertGreaterThan(scroll.documentView?.frame.height ?? 0, scroll.contentView.bounds.height, "这一天的日志要滚动")
        XCTAssertTrue(!scroll.hasVerticalScroller || scroll.verticalScroller?.isHidden == true || scroll.verticalScroller?.alphaValue == 0,
                      "不显示滚动条（右边是节奏条）")
    }
}
