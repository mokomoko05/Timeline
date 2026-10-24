import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class LogEventStyleTests: XCTestCase {
    func testShortFocusHasXAndMinimumBoundaryHasGreenCheckEvenAfterTextEditing() {
        var log = DailyLogEntry(createdAt: Date(), kind: .note, text: "■ 结束专注 · raw details", focus: true,
                                focusEvent: .end, focusElapsedSeconds: 299, focusMinimumSeconds: 300)
        XCTAssertEqual(LogEventStyle.symbol(log), "xmark")
        XCTAssertEqual(LogEventStyle.color(log), Palette.danger, "未达标用主题的危险色")
        XCTAssertTrue(LogEventStyle.body(log).contains(AppLocalized("未达到最低专注时长")))
        log.text = "Edited end note"
        XCTAssertEqual(LogEventStyle.symbol(log), "xmark")
        XCTAssertEqual(LogEventStyle.body(log), "Edited end note")
        log.focusElapsedSeconds = 300
        XCTAssertEqual(LogEventStyle.symbol(log), "checkmark")
        XCTAssertEqual(LogEventStyle.color(log), Palette.success, "达标用主题的完成色")
        log.focusElapsedSeconds = 301
        XCTAssertEqual(LogEventStyle.symbol(log), "checkmark")
        log.focusMinimumSeconds = 600
        XCTAssertEqual(LogEventStyle.symbol(log), "xmark")
        log.focusMinimumSeconds = 0
        XCTAssertEqual(LogEventStyle.symbol(log), "checkmark")
        let note = DailyLogEntry(createdAt: Date(), kind: .note, text: "Ordinary note")
        XCTAssertNil(LogEventStyle.symbol(note))
    }

    func testTypedDisplayKeepsRawRecordsAndHonorsEditedText() {
        var start = DailyLogEntry(createdAt: Date(), kind: .note, text: "▶ 开始专注", focus: true,
                                  focusEvent: .start, focusGoal: "Read methods", focusPlannedSeconds: 1500)
        XCTAssertEqual(LogEventStyle.body(start), AppLocalizedFormat("计划 %@", FocusSession.brief(1500)))
        XCTAssertEqual(start.text, "▶ 开始专注")
        start.text = "Edited start note"
        XCTAssertEqual(LogEventStyle.body(start), "Edited start note")
        let end = DailyLogEntry(createdAt: Date(), kind: .note, text: "■ 结束专注 · raw details", focus: true,
                                focusEvent: .end, focusElapsedSeconds: 1500, focusEndReason: "计时结束")
        XCTAssertEqual(LogEventStyle.body(end), AppLocalizedFormat("有效专注 %@", FocusSession.duration(1500)) + " · " + AppLocalized("计时结束"))
        let legacy = DailyLogEntry(createdAt: Date(), kind: .note, text: "阶段反馈 · **Finished**\nNext step")
        XCTAssertEqual(legacy.focusMarker, "REVIEW")
        XCTAssertEqual(LogEventStyle.body(legacy), "**Finished**\nNext step")
        XCTAssertEqual(legacy.text, "阶段反馈 · **Finished**\nNext step")
    }

    func testLegacyFocusRecordsUseTimelineSummaryWithoutChangingStoredDetails() {
        let now = Date()
        let start = DailyLogEntry(createdAt: now, kind: .note, text: "▶ 开始专注", focus: true)
        XCTAssertEqual(LogEventStyle.body(start), "")
        let raw = "■ 结束专注 · 用时 25 min 9 s · 累计 1 h 53 min 32 s · 手动结束"
        let end = DailyLogEntry(createdAt: now, kind: .note, text: raw, focus: true)
        XCTAssertEqual(LogEventStyle.body(end), AppLocalizedFormat("有效专注 %@", "25 min 9 s") + " · " + AppLocalized("手动结束"))
        XCTAssertEqual(LogEventStyle.detail(end), AppLocalizedFormat("累计 %@", "1 h 53 min 32 s"))
        XCTAssertEqual(end.text, raw)
    }

    func testTimelineRailConnectsVariableHeightEntriesAndStopsAtEndpoints() {
        for height: CGFloat in [40, 150, 300] {
            let rect = CGRect(x: 0, y: 0, width: 16, height: height)
            let first = LogTimelineRail(hasPrevious: false, hasNext: true, nodeY: 9).path(in: rect).boundingRect
            let middle = LogTimelineRail(hasPrevious: true, hasNext: true, nodeY: 9).path(in: rect).boundingRect
            let last = LogTimelineRail(hasPrevious: true, hasNext: false, nodeY: 9).path(in: rect).boundingRect
            XCTAssertEqual(first.minY, 9)
            XCTAssertEqual(first.maxY, height)
            XCTAssertEqual(middle.minY, 0)
            XCTAssertEqual(middle.maxY, height)
            XCTAssertEqual(last.minY, 0)
            XCTAssertEqual(last.maxY, 9)
            XCTAssertEqual(first.minX, middle.minX)
            XCTAssertEqual(middle.minX, last.minX)
        }
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
        store.addFocusLog("■ 结束专注 · 用时 25 min 9 s · 累计 1 h 53 min 32 s · 手动结束", taskID: task.id,
                          now: now.addingTimeInterval(5), seconds: 1509, event: .end, endReason: "手动结束")
        let navigation = NotesWorkspaceNavigation()
        navigation.open(.journal, date: now)
        let nav = NotesNavigation()
        let view = UnifiedNotesView(store: store, workspace: navigation, nav: nav, close: {}, reveal: { _ in }, openDay: { _ in })
            .environment(\.typography, AppTypography(scale: 1.5))
        let host = NSHostingView(rootView: view)
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        func texts(_ view: NSView) -> [InteractiveTaskText] {
            guard !view.isHiddenOrHasHiddenAncestor else { return [] }
            return (view as? InteractiveTaskText).map { [$0] } ?? view.subviews.flatMap(texts)
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
        nav.open(task: task.id)
        navigation.open(.notes)
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        let notebook = texts(host)
        XCTAssertFalse(notebook.contains { $0.source == goal })
        XCTAssertFalse(notebook.contains { $0.source == "Review content" })
        for index in 1...3 {
            XCTAssertTrue(notebook.contains { $0.source == "Visible note \(index)\nSecond paragraph" })
        }
    }
}
