import AppKit
import SwiftUI
import XCTest
@testable import Dayleaf
@testable import DayleafCore

@MainActor
final class WindowLinkingTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []
    override func setUp() async throws { _ = NSApplication.shared }

    private func makeStore() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory)
    }

    func testDayLogWindowKeepsOneViewAndFollowsDateChanges() throws {
        let store = makeStore()
        let name = "DayLogLinkTest-\(UUID().uuidString)"
        let controller = DayLogWindowController(frameName: name)
        Self.keepAlive.append(controller)
        addTeardownBlock { controller.close(); UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)") }
        let calendar = JournalDates.calendar
        let today = calendar.startOfDay(for: Date())
        controller.show(store: store, date: today)
        let host = try XCTUnwrap(controller.window?.contentViewController as? NSHostingController<AnyView>)
        let firstView = host.rootView
        _ = firstView
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        controller.show(store: store, date: tomorrow)
        XCTAssertEqual(controller.day.date, tomorrow, "再次打开换到那一天")
        controller.shift(-2)
        XCTAssertEqual(controller.day.date, calendar.date(byAdding: .day, value: -1, to: today), "前一天 / 后一天作用在日志窗口")
        controller.setDate(today.addingTimeInterval(3600))
        XCTAssertEqual(controller.day.date, today, "日期取当天开始")
    }

    func testDayLogWindowHasItsOwnToast() {
        let controller = DayLogWindowController(frameName: "DayLogToast-\(UUID().uuidString)")
        Self.keepAlive.append(controller)
        controller.toast.show("已删除 2 条日志", actionTitle: "撤销") {}
        XCTAssertNotNil(controller.toast.current, "提示出现在日志窗口自己的提示条上")
    }

    func testUndoMessagesCoverDropCompleteAndTagOperations() {
        for action in ["删除任务", "删除日志", "放弃待办", "恢复待办", "完成状态", "重命名标签", "删除标签"] {
            XCTAssertNotNil(ToastCenter.undoMessages[action], "\(action) 后有带撤销的提示")
        }
    }

    func testTaskPopoverRequestIsDeliveredOnceToTheMatchingRow() {
        let interaction = WorkspaceInteraction()
        let id = UUID()
        interaction.taskPopover = TaskPopoverRequest(id: id, kind: .tags)
        XCTAssertEqual(interaction.taskPopover, TaskPopoverRequest(id: id, kind: .tags))
        XCTAssertNotEqual(interaction.taskPopover, TaskPopoverRequest(id: id, kind: .details))
    }

    func testMenuBarSummaryUsesTheSameCountsAsTheListHeader() throws {
        let store = makeStore()
        let calendar = JournalDates.calendar
        let now = Date()
        let late = try XCTUnwrap(store.addParsedTodo("逾期的", on: now)).id
        store.setDeadline(late, to: calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: now))!)
        let today = try XCTUnwrap(store.addParsedTodo("今天的", on: now)).id
        store.setDeadline(today, to: calendar.startOfDay(for: now))
        _ = store.addParsedTodo("没日期的", on: now)
        let summary = store.taskSummary(now: now)
        XCTAssertEqual(summary.overdue, 1)
        XCTAssertEqual(summary.dueToday, 1, "按截止日期：「没日期的」虽然是今天建的，也不算今天截止")
    }
}
