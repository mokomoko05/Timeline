import AppKit
import SwiftUI
import XCTest
import DayleafCore
@testable import Dayleaf

@MainActor
final class LogEventStyleTests: XCTestCase {
    func testTypedDisplayKeepsRawRecordsAndHonorsEditedText() {
        var start = DailyLogEntry(createdAt: Date(), kind: .note, text: "▶ 开始专注", focus: true,
                                  focusEvent: .start, focusGoal: "Read methods", focusPlannedSeconds: 1500)
        XCTAssertEqual(LogEventStyle.body(start), AppLocalizedFormat("计划 %@", FocusSession.brief(1500)))
        XCTAssertEqual(start.text, "▶ 开始专注")
        start.text = "Edited start note"
        XCTAssertEqual(LogEventStyle.body(start), "Edited start note")
        let end = DailyLogEntry(createdAt: Date(), kind: .note, text: "■ 结束专注 · raw details", focus: true,
                                focusEvent: .end, focusElapsedSeconds: 1500, focusEndReason: "计时结束")
        XCTAssertEqual(LogEventStyle.body(end), AppLocalizedFormat("有效专注 %@", FocusSession.brief(1500)) + " · " + AppLocalized("计时结束"))
        let legacy = DailyLogEntry(createdAt: Date(), kind: .note, text: "阶段反馈 · **Finished**\nNext step")
        XCTAssertEqual(legacy.focusMarker, "REVIEW")
        XCTAssertEqual(LogEventStyle.body(legacy), "**Finished**\nNext step")
        XCTAssertEqual(legacy.text, "阶段反馈 · **Finished**\nNext step")
    }

    func testJournalShowsGoalAndEveryNoteWithoutDisclosureAtLargeTextSize() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let now = Date()
        let task = try XCTUnwrap(store.addParsedTodo("Paper", on: now))
        let goal = "Goal line one\nGoal line two\nGoal line three\nGoal line four"
        store.addFocusLog("▶ 开始专注", taskID: task.id, now: now, event: .start, goal: goal, plannedSeconds: 1500)
        for index in 1...3 {
            _ = try store.quickLogEntry("Visible note \(index)\nSecond paragraph", taskID: task.id, on: now,
                                       now: now.addingTimeInterval(Double(index)), focusEvent: .note)
        }
        _ = try store.quickLogEntry("Review content", taskID: task.id, on: now, now: now.addingTimeInterval(4), focusEvent: .review)
        let navigation = NotesWorkspaceNavigation()
        navigation.open(.journal, date: now)
        let view = UnifiedNotesView(store: store, workspace: navigation, nav: NotesNavigation(), close: {}, reveal: { _ in }, openDay: { _ in })
            .environment(\.typography, AppTypography(scale: 1.5))
        let host = NSHostingView(rootView: view)
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        func texts(_ view: NSView) -> [InteractiveTaskText] {
            (view as? InteractiveTaskText).map { [$0] } ?? view.subviews.flatMap(texts)
        }
        let rendered = texts(host)
        XCTAssertTrue(rendered.contains { $0.source == goal })
        for index in 1...3 {
            XCTAssertTrue(rendered.contains { $0.source == "Visible note \(index)\nSecond paragraph" })
        }
        XCTAssertTrue(rendered.contains { $0.source == "Review content" })
        let timestamp = LogEventStyle.time(now)
        XCTAssertEqual(timestamp.count, 8)
        XCTAssertEqual(timestamp.filter { $0 == ":" }.count, 2)
    }
}
