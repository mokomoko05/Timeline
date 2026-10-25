import AppKit
import SwiftUI
import XCTest
@testable import Timeline
@testable import TimelineCore

@MainActor
final class WindowLinkingTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []
    override func setUp() async throws { _ = NSApplication.shared }

    private func makeStore() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory)
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
