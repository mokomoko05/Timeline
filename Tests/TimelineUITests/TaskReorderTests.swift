import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class TaskReorderTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    private func rect(_ index: Int, height: CGFloat = 40) -> CGRect {
        CGRect(x: 0, y: CGFloat(index) * (height + 6), width: 300, height: height)
    }

    // MARK: - 纯几何

    func testTargetFollowsTheLeadingEdgeAndStaysInsideTheGroup() {
        let frames = (0..<4).map { rect($0) }
        XCTAssertEqual(ReorderMath.targetIndex(frames: frames, active: 0, translation: 0), 0)
        XCTAssertEqual(ReorderMath.targetIndex(frames: frames, active: 0, translation: 20), 0, "下沿还没越过下一行的中线")
        XCTAssertEqual(ReorderMath.targetIndex(frames: frames, active: 0, translation: 30), 1)
        XCTAssertEqual(ReorderMath.targetIndex(frames: frames, active: 0, translation: 100), 2)
        XCTAssertEqual(ReorderMath.targetIndex(frames: frames, active: 3, translation: -100), 1)
        XCTAssertEqual(ReorderMath.clamp(500, frames: frames, active: 0), frames[3].maxY - frames[0].maxY, "不能拖出分组下沿")
        XCTAssertEqual(ReorderMath.clamp(-500, frames: frames, active: 2), frames[0].minY - frames[2].minY, "不能拖出分组上沿")
    }

    /// 一条很高的条目往上拖：它的上沿一越过上面短条目的中线，短条目就要让位，而不是等到高条目的中心越过。
    func testATallRowDraggedUpMakesTheShortRowAboveYieldImmediately() {
        let frames = [CGRect(x: 0, y: 0, width: 300, height: 40), CGRect(x: 0, y: 46, width: 300, height: 40),
                      CGRect(x: 0, y: 92, width: 300, height: 140)]
        XCTAssertEqual(ReorderMath.targetIndex(frames: frames, active: 2, translation: -20), 2, "上沿还没到上一行中线（66）")
        XCTAssertEqual(ReorderMath.targetIndex(frames: frames, active: 2, translation: -30), 1, "上沿到 62，越过中线 66，短条目让位")
        XCTAssertEqual(ReorderMath.targetIndex(frames: frames, active: 2, translation: -80), 0, "继续上拖，越过第一条")
        // 反方向：短条目往下拖过一条很高的，用它的下沿判断。
        let down = [CGRect(x: 0, y: 0, width: 300, height: 40), CGRect(x: 0, y: 46, width: 300, height: 140)]
        XCTAssertEqual(ReorderMath.targetIndex(frames: down, active: 0, translation: 40), 0, "下沿 80 还没过高条目的中线 116")
        XCTAssertEqual(ReorderMath.targetIndex(frames: down, active: 0, translation: 80), 1, "下沿 120 越过 116")
        // 让位距离是被拖行（很高）的高度，高条目最终落在最上面。
        XCTAssertEqual(ReorderMath.shift(frames: frames, active: 2, target: 0, index: 0, spacing: 6), 146)
        XCTAssertEqual(ReorderMath.shift(frames: frames, active: 2, target: 0, index: 1, spacing: 6), 146)
        XCTAssertEqual(ReorderMath.slotOffset(frames: frames, active: 2, target: 0), -92)
    }

    func testRowsMakeRoomByExactlyTheDraggedRowsHeightAndSpacing() {
        // 行高不同：被拖的是 60 高的第 0 行。
        let frames = [CGRect(x: 0, y: 0, width: 300, height: 60), CGRect(x: 0, y: 66, width: 300, height: 30),
                      CGRect(x: 0, y: 102, width: 300, height: 50), CGRect(x: 0, y: 158, width: 300, height: 40)]
        let down = (0..<4).map { ReorderMath.shift(frames: frames, active: 0, target: 2, index: $0, spacing: 6) }
        XCTAssertEqual(down, [0, -66, -66, 0], "被拖行向下越过两行，这两行各上移 60+6")
        XCTAssertEqual(ReorderMath.slotOffset(frames: frames, active: 0, target: 2), 152 - 60, "落位后被拖行底边对齐原第 2 行的底边")
        let up = (0..<4).map { ReorderMath.shift(frames: frames, active: 3, target: 1, index: $0, spacing: 6) }
        XCTAssertEqual(up, [0, 46, 46, 0], "被拖行向上越过两行，这两行各下移 40+6")
        XCTAssertEqual(ReorderMath.slotOffset(frames: frames, active: 3, target: 1), 66 - 158)
        XCTAssertEqual(ReorderMath.moved(["a", "b", "c", "d"], from: 0, to: 2), ["b", "c", "a", "d"])
        XCTAssertEqual(ReorderMath.moved(["a", "b", "c", "d"], from: 3, to: 1), ["a", "d", "b", "c"])
    }

    // MARK: - 时间轴落点

    func testTimelineDropBelongsToTheNearestDateAboveIt() {
        let calendar = JournalDates.calendar
        let today = calendar.startOfDay(for: Date()), tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let gap = TimelineSlots.id("test-gap-top", .fixed)
        let dayA = TimelineSlots.id("test-marker-a", .day(today)), dayB = TimelineSlots.id("test-marker-b", .day(tomorrow))
        let undated = TimelineSlots.id("test-marker-undated", .day(nil))
        let now = TimelineSlots.id("test-now", .fixed)
        let (a1, a2, b1, dragged) = (UUID(), UUID(), UUID(), UUID())
        let intoB = TimelineSlots.placement(of: dragged, in: [gap, dayA, a1, now, a2, dayB, dragged, b1, undated])
        XCTAssertEqual(intoB?.day, tomorrow, "落在明天的刻度下面就是明天")
        XCTAssertEqual(intoB?.order, [dragged, b1], "只排那一天的任务，「现在」之类的不算")
        let endOfA = TimelineSlots.placement(of: dragged, in: [gap, dayA, a1, now, a2, dragged, dayB, b1])
        XCTAssertEqual(endOfA?.day, today, "放在下一个日期之前，算上一天的末尾")
        XCTAssertEqual(endOfA?.order, [a1, a2, dragged])
        let noDue = TimelineSlots.placement(of: dragged, in: [dayA, a1, undated, dragged])
        XCTAssertNotNil(noDue)
        XCTAssertNil(noDue?.day, "未设日期")
        XCTAssertNil(TimelineSlots.placement(of: dragged, in: [gap, dragged, dayA, a1]), "最上面没有日期，放不下")
    }

    func testRejectedDropSlidesBackWithoutCommitting() async throws {
        let ids = (0..<3).map { _ in UUID() }
        let model = TaskReorderModel()
        for (i, id) in ids.enumerated() { model.frames[id] = rect(i) }
        model.groupProvider = { _ in ids }
        var commits = 0
        model.commit = { _ in commits += 1 }
        model.accepts = { _ in false }
        XCTAssertTrue(model.begin(ids[0]))
        model.update(100)
        model.finish()
        XCTAssertEqual(commits, 0)
        XCTAssertFalse(model.isActive)
        XCTAssertEqual(model.returning, !Motion.reduced, "别的行带动画回原位")
    }

    // MARK: - 状态模型

    func testModelCommitsAndResetsImmediatelyOnRelease() async throws {
        let ids = (0..<4).map { _ in UUID() }
        let model = TaskReorderModel()
        for (i, id) in ids.enumerated() { model.frames[id] = rect(i) }
        model.groupProvider = { _ in ids }
        var commits: [[UUID]] = []
        model.commit = { commits.append($0) }

        XCTAssertTrue(model.begin(ids[0]))
        XCTAssertFalse(model.begin(ids[1]), "拖动中不能再开始另一次")
        model.update(100)
        XCTAssertEqual(model.target, 2)
        XCTAssertEqual(model.offset(for: ids[0]), 100, "被拖行紧跟指针")
        XCTAssertEqual(model.offset(for: ids[1]), -46, "其他行让位")
        XCTAssertEqual(model.offset(for: ids[2]), -46)
        XCTAssertEqual(model.offset(for: ids[3]), 0)
        model.update(-30)
        XCTAssertEqual(model.target, 0, "拖回去，让位的行回到原位")
        XCTAssertEqual(model.offset(for: ids[1]), 0)
        model.update(100)
        model.finish()
        XCTAssertEqual(commits, [[ids[1], ids[2], ids[0], ids[3]]])
        XCTAssertFalse(model.isActive)
        XCTAssertEqual(model.offset(for: ids[0]), 0)
    }

    func testCancelAndUnchangedDropsNeverCommit() async throws {
        let ids = (0..<3).map { _ in UUID() }
        let model = TaskReorderModel()
        for (i, id) in ids.enumerated() { model.frames[id] = rect(i) }
        model.groupProvider = { _ in ids }
        var commits = 0
        model.commit = { _ in commits += 1 }
        XCTAssertTrue(model.begin(ids[1]))
        model.update(60)
        model.cancel()
        XCTAssertEqual(commits, 0)
        XCTAssertFalse(model.isActive)
        XCTAssertTrue(model.begin(ids[1]))
        model.update(5)
        model.finish()
        XCTAssertEqual(commits, 0, "没有换位置就不改数据")
        model.groupProvider = { _ in [ids[0]] }
        XCTAssertFalse(model.begin(ids[0]), "分组里只有一项，没有可排的")
    }

    // MARK: - 真实视图里的把手

    private struct Harness: View {
        let todos: [Todo]
        @ObservedObject var model: TaskReorderModel
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: TaskReorderModel.spacing) {
                    ForEach(todos) { todo in
                        HStack {
                            Text(todo.title).frame(maxWidth: .infinity, alignment: .leading)
                            TaskDragHandle(task: todo, enabled: true, reorder: TaskReorderHooks(
                                begin: { model.begin(todo.id) }, update: { model.update($0) },
                                end: { model.finish() }, cancel: { model.cancel() }))
                        }
                        .frame(height: 40)
                        .taskReorderRow(id: todo.id, model: model, space: "taskList")
                    }
                }
                .coordinateSpace(name: "taskList")
                .onPreferenceChange(TaskRowFramesKey.self) { model.frames = $0 }
            }
        }
    }

    private func handles(in view: NSView) -> [TaskHandleView] {
        view.subviews.flatMap { sub in (sub as? TaskHandleView).map { [$0] } ?? handles(in: sub) }
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testDraggingTheRealHandleLetsOtherRowsMakeRoomAndCommitsTheOrder() async throws {
        let todos = (1...4).map { Todo(title: "任务\($0)") }
        let model = TaskReorderModel()
        model.groupProvider = { _ in todos.map(\.id) }
        var commits: [[UUID]] = []
        model.commit = { commits.append($0) }
        let host = NSHostingView(rootView: Harness(todos: todos, model: model))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        Self.keepAlive += [window, host, model]
        addTeardownBlock { @MainActor in window.close() }
        for _ in 0..<20 where model.frames.count < 4 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(model.frames.count, 4, "每一行都回传了位置")

        let found = handles(in: host)
        XCTAssertEqual(found.count, 4)
        let first = try XCTUnwrap(found.min { host.convert($0.bounds, from: $0).minY < host.convert($1.bounds, from: $1).minY })
        XCTAssertNotNil(first.enclosingScrollView, "把手能找到外层清单，用来自动滚动")
        let start = first.convert(NSPoint(x: first.bounds.midX, y: first.bounds.midY), to: nil)

        first.mouseDown(with: mouse(.leftMouseDown, at: start, in: window))
        // 窗口坐标 y 向上，向下拖 100 点。
        first.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 100), in: window))
        XCTAssertEqual(model.activeID, todos[0].id)
        XCTAssertEqual(model.target, 2)
        XCTAssertEqual(model.offset(for: todos[1].id), -46, "第二行上移让位")
        XCTAssertEqual(model.offset(for: todos[0].id), 100, accuracy: 0.5)

        first.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: start.x, y: start.y - 100), in: window))
        XCTAssertEqual(commits, [[todos[1].id, todos[2].id, todos[0].id, todos[3].id]])
        XCTAssertFalse(model.isActive)
    }

    func testDraggingOutsideTheGroupRemainsAClampedReorder() async throws {
        let todos = (1...3).map { Todo(title: "任务\($0)") }
        let model = TaskReorderModel()
        model.groupProvider = { _ in todos.map(\.id) }
        var commits = 0
        model.commit = { _ in commits += 1 }
        let host = NSHostingView(rootView: Harness(todos: todos, model: model))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        Self.keepAlive += [window, host, model]
        addTeardownBlock { @MainActor in window.close() }
        for _ in 0..<20 where model.frames.count < 3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let first = try XCTUnwrap(handles(in: host).min { host.convert($0.bounds, from: $0).minY < host.convert($1.bounds, from: $1).minY })
        let start = first.convert(NSPoint(x: first.bounds.midX, y: first.bounds.midY), to: nil)
        first.mouseDown(with: mouse(.leftMouseDown, at: start, in: window))
        first.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 60), in: window))
        XCTAssertTrue(model.isActive)
        // 纵向越过日期边界仍然只排本组，不能触发日历拖放。
        var dragged: UUID?
        first.startNativeDrag = { id, _, _, _ in dragged = id }
        let outside = NSPoint(x: start.x, y: start.y - 1000)
        first.mouseDragged(with: mouse(.leftMouseDragged, at: outside, in: window))
        XCTAssertEqual(model.target, 2)
        XCTAssertEqual(model.offset(for: todos[0].id), 92, accuracy: 1)
        first.mouseUp(with: mouse(.leftMouseUp, at: outside, in: window))
        XCTAssertFalse(model.isActive)
        XCTAssertEqual(commits, 1)
        XCTAssertNil(dragged)

        first.mouseDown(with: mouse(.leftMouseDown, at: start, in: window))
        first.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 60), in: window))
        XCTAssertTrue(model.isActive)
        first.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: start.x + 500, y: start.y - 60), in: window))
        XCTAssertEqual(dragged, todos[0].id)
        XCTAssertFalse(model.isActive, "日历拖放接手时取消组内排序")
        XCTAssertEqual(commits, 1, "取消排序不会写入顺序")
    }

    /// 卡顿的根因回归测试：拖动时模型每秒更新几十次，持有模型的外层界面（真实应用里是整个 ContentView）一次都不能重新渲染。
    private static var outerRenders = 0

    private struct Outer: View {
        @State private var model = TaskReorderModel()
        let todos: [Todo]
        let expose: (TaskReorderModel) -> Void
        var body: some View {
            Self.countRender()
            expose(model)
            return Harness(todos: todos, model: model)
        }
        private static func countRender() { TaskReorderTests.outerRenders += 1 }
    }

    func testDraggingNeverRerendersTheViewThatOwnsTheModel() async throws {
        let todos = (1...6).map { Todo(title: "任务\($0)") }
        var captured: TaskReorderModel?
        let host = NSHostingView(rootView: Outer(todos: todos, expose: { captured = $0 }))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        Self.keepAlive += [window, host]
        addTeardownBlock { @MainActor in window.close() }
        let model = try XCTUnwrap(captured)
        model.groupProvider = { _ in todos.map(\.id) }
        for _ in 0..<20 where model.frames.count < 6 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(model.frames.count, 6)
        try await Task.sleep(nanoseconds: 200_000_000)
        let before = Self.outerRenders
        XCTAssertTrue(model.begin(todos[0].id))
        for step in 0...60 {
            model.update(CGFloat(step) * 4)
            if step % 10 == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        model.cancel()
        XCTAssertEqual(Self.outerRenders, before, "拖动过程中外层不能重绘（否则整个清单和日历每次鼠标移动都重算）")
    }

    // MARK: - 真实渲染出来的位置

    private struct RenderedKey: PreferenceKey {
        static var defaultValue: [UUID: CGRect] = [:]
        static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
    }

    /// 和 Harness 一样，但每行内部再量一次自己实际画在哪里（位移会反映在这里，布局位置不会）。
    private struct MeasuredHarness: View {
        let todos: [Todo]
        @ObservedObject var model: TaskReorderModel
        let rendered: (([UUID: CGRect]) -> Void)
        var heights: [CGFloat] = []
        var body: some View {
            VStack(alignment: .leading, spacing: TaskReorderModel.spacing) {
                ForEach(Array(todos.enumerated()), id: \.element.id) { index, todo in
                    Text(todo.title).frame(maxWidth: .infinity, alignment: .leading).frame(height: heights.isEmpty ? 40 : heights[index])
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: RenderedKey.self, value: [todo.id: proxy.frame(in: .global)])
                        })
                        .taskReorderRow(id: todo.id, model: model, space: "taskList")
                }
            }
            .coordinateSpace(name: "taskList")
            .onPreferenceChange(TaskRowFramesKey.self) { model.frames = $0 }
            .onPreferenceChange(RenderedKey.self) { rendered($0) }
        }
    }

    func testOtherRowsReallyMoveOnScreenToMakeRoomAndSettleBack() async throws {
        let todos = (1...4).map { Todo(title: "任务\($0)") }
        let model = TaskReorderModel()
        model.groupProvider = { _ in todos.map(\.id) }
        var rendered: [UUID: CGRect] = [:]
        let host = NSHostingView(rootView: MeasuredHarness(todos: todos, model: model, rendered: { rendered = $0 }))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        Self.keepAlive += [window, host, model]
        addTeardownBlock { @MainActor in window.close() }
        for _ in 0..<20 where model.frames.count < 4 || rendered.count < 4 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let home = rendered
        XCTAssertEqual(home.count, 4)

        XCTAssertTrue(model.begin(todos[0].id))
        model.update(100)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(rendered[todos[0].id]!.minY - home[todos[0].id]!.minY, 100, accuracy: 1, "被拖的行跟着指针")
        XCTAssertEqual(rendered[todos[1].id]!.minY - home[todos[1].id]!.minY, -46, accuracy: 1, "第二行真的上移让位")
        XCTAssertEqual(rendered[todos[2].id]!.minY - home[todos[2].id]!.minY, -46, accuracy: 1, "第三行真的上移让位")
        XCTAssertEqual(rendered[todos[3].id]!.minY, home[todos[3].id]!.minY, accuracy: 1, "越过范围之外的行不动")

        model.update(0)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(rendered[todos[1].id]!.minY, home[todos[1].id]!.minY, accuracy: 1, "拖回去，让位的行回到原位")
        model.cancel()
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    func testTallRowDraggedUpReallyPushesTheShortRowsAboveDownOnScreen() async throws {
        let todos = (1...3).map { Todo(title: "任务\($0)") }
        let model = TaskReorderModel()
        model.groupProvider = { _ in todos.map(\.id) }
        var rendered: [UUID: CGRect] = [:]
        let host = NSHostingView(rootView: MeasuredHarness(todos: todos, model: model, rendered: { rendered = $0 }, heights: [40, 40, 140]))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        Self.keepAlive += [window, host, model]
        addTeardownBlock { @MainActor in window.close() }
        for _ in 0..<20 where model.frames.count < 3 || rendered.count < 3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let home = rendered
        XCTAssertTrue(model.begin(todos[2].id))
        model.update(-30)   // 高条目只上移 30：它的上沿刚过第二条的中线
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(model.target, 1)
        XCTAssertEqual(rendered[todos[2].id]!.minY - home[todos[2].id]!.minY, -30, accuracy: 1)
        XCTAssertEqual(rendered[todos[1].id]!.minY - home[todos[1].id]!.minY, 146, accuracy: 1, "短条目下移让出整个高条目的高度")
        XCTAssertEqual(rendered[todos[0].id]!.minY, home[todos[0].id]!.minY, accuracy: 1)
        model.update(-92)   // 一路拖到最上面
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(model.target, 0)
        XCTAssertEqual(rendered[todos[0].id]!.minY - home[todos[0].id]!.minY, 146, accuracy: 1)
        XCTAssertEqual(rendered[todos[1].id]!.minY - home[todos[1].id]!.minY, 146, accuracy: 1)
        model.cancel()
        try await Task.sleep(nanoseconds: 500_000_000)
    }
}
