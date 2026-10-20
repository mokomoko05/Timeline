import AppKit
import SwiftUI
import XCTest
@testable import Timeline

final class ResizableWorkspaceTests: XCTestCase {
    func testTasksAndCalendarShareTheFullHeightAndCalendarAlwaysRemainsVisible() {
        let size = CGSize(width: 1200, height: 800)
        let expanded = WorkspaceDimensions(size: size, leftFraction: 0.4)
        XCTAssertEqual(expanded.tasksFrame.maxX, expanded.calendarFrame.minX)
        XCTAssertEqual(expanded.tasksFrame.height, size.height, "不再有底部的日志区，清单和月历占满整个高度")
        XCTAssertEqual(expanded.calendarFrame.height, size.height)
        let hiddenTasks = WorkspaceDimensions(size: size, leftFraction: 0.4, tasksVisible: false)
        XCTAssertEqual(hiddenTasks.left, 0)
        XCTAssertEqual(hiddenTasks.calendarFrame.width, size.width)
    }

    func testDraggingTheDividerKeepsBothPanesUsableAndRatioRoundTrips() {
        let original = WorkspaceDimensions(size: CGSize(width: 1200, height: 800), leftFraction: 0.4)
        XCTAssertEqual(original.moving(CGSize(width: 70, height: 0)).left, original.left + 70, accuracy: 0.001)
        XCTAssertEqual(original.moving(CGSize(width: -2000, height: 0)).left, 300, "清单最窄 300")
        let maximum = original.moving(CGSize(width: 2000, height: 0))
        XCTAssertEqual(maximum.left, 740, "月历至少留 460")
        let restored = WorkspaceDimensions(size: maximum.size, leftFraction: maximum.left / maximum.size.width)
        XCTAssertEqual(restored.left, maximum.left, accuracy: 0.001)
    }

    @MainActor
    func testNativeResizeDragUsesWindowCoordinatesAcrossMovingHandle() async throws {
        let view = ResizeHandleView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        var began = false
        var ended = false
        var translation: CGSize?
        view.begin = { began = true }
        view.change = { translation = $0 }
        view.end = { ended = true }
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 400, y: 300),
                                                   modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 1))
        let drag = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 480, y: 250),
                                                   modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
                                                   eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: down)
        view.frame.origin = NSPoint(x: 80, y: 50)
        view.mouseDragged(with: drag)
        view.mouseUp(with: drag)
        XCTAssertTrue(began)
        XCTAssertTrue(ended)
        XCTAssertEqual(translation, CGSize(width: 80, height: 50))
    }

    func testNarrowWindowShowsTasksAloneInsteadOfSqueezingTheCalendar() {
        let narrow = WorkspaceDimensions(size: CGSize(width: 700, height: 700), leftFraction: 0.4)
        XCTAssertTrue(narrow.narrow)
        XCTAssertEqual(narrow.tasksFrame.width, 700)
        XCTAssertEqual(narrow.calendarFrame.width, 0)
    }

    func testLayoutSizeIsFrozenOnlyWhileResizing() {
        let actual = CGSize(width: 1001, height: 700)
        XCTAssertEqual(LiveResize.layoutSize(actual: actual, frozen: nil), actual, "不在缩放时用真实尺寸")
        XCTAssertEqual(LiveResize.layoutSize(actual: actual, frozen: CGSize(width: 1200, height: 800)), CGSize(width: 1200, height: 800), "缩放中用冻结的尺寸")
    }

    /// 真实的视图：拖动期间内容尺寸不跟着窗口走（停顿也不追），松手后按真实尺寸。
    @MainActor
    func testContentStaysFrozenDuringResizeThenCatchesUpOnPauseAndOnRelease() async throws {
        final class Probe { var calendar = CGSize.zero }
        let probe = Probe()
        var visible = false
        let view = ResizableWorkspace(tasksVisible: Binding(get: { visible }, set: { visible = $0 })) {
            Color.clear
        } calendar: {
            GeometryReader { proxy in
                Color.clear.onAppear { probe.calendar = proxy.size }.onChange(of: proxy.size) { probe.calendar = $0 }
            }
        }
        let host = NSHostingView(rootView: view)
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(probe.calendar.width, 1000, accuracy: 1, "一开始就是窗口的宽度")

        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        for width in stride(from: 1000.0, through: 900, by: -10) {
            window.setContentSize(NSSize(width: width, height: 700))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(probe.calendar.width, 1000, accuracy: 1, "拖动期间内容的布局尺寸冻结，不跟着窗口重排")

        try await Task.sleep(nanoseconds: 400_000_000)
        window.setContentSize(NSSize(width: 800, height: 700))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(probe.calendar.width, 1000, accuracy: 1, "拖动没结束就一直冻结，哪怕停顿很久：跟手第一")
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(probe.calendar.width, 800, accuracy: 1, "松手后立刻按真实尺寸排版")

        window.setContentSize(NSSize(width: 700, height: 700))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(probe.calendar.width, 700, accuracy: 1, "不是用户拖动的缩放（比如脚本、全屏）立即跟随")
    }

    @MainActor
    func testObserverFollowsTheWindowsLiveResizeNotifications() {
        var states: [Bool] = []
        let view = LiveResizeObserver.LiveResizeView()
        view.takesSnapshot = false
        view.changed = { live, _ in states.append(live) }
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: NSObject())
        XCTAssertEqual(states, [true, false], "只响应自己窗口的通知")
    }

    @MainActor
    func testSnapshotIsBlurredAndHasTheRequestedSize() throws {
        let host = NSHostingView(rootView: HStack(spacing: 0) { Color.black; Color.white }.frame(width: 200, height: 100))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(LiveResize.blurredSnapshot(of: host, rect: host.bounds))
        XCTAssertEqual(image.size.width, 200, accuracy: 1)
        XCTAssertEqual(image.size.height, 100, accuracy: 1)
        // 黑白交界处被模糊成灰色，而不是硬边。
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let edge = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceGray))
        XCTAssertGreaterThan(edge.whiteComponent, 0.2)
        XCTAssertLessThan(edge.whiteComponent, 0.8, "交界处是灰的 = 已经模糊")
        XCTAssertNil(LiveResize.blurredSnapshot(of: host, rect: .zero))
    }
}
