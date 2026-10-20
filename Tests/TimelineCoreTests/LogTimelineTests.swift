import XCTest
@testable import TimelineCore

final class LogTimelineTests: XCTestCase {
    private func log(_ time: TimeInterval, event: FocusLogEvent? = nil, text: String = "record", focus: Bool = false) -> DailyLogEntry {
        DailyLogEntry(createdAt: Date(timeIntervalSince1970: time), kind: .note, text: text, focus: focus, focusEvent: event)
    }

    func testBlueRailStartsAtFocusNodeAndStopsAtEndNode() throws {
        let logs = [log(0), log(1, event: .start), log(2, event: .note), log(3),
                    log(4, event: .review), log(5, event: .end), log(6)]
        let segments = LogTimelineSegment.segments(in: logs)
        let expected = [(false, false), (false, true), (true, true), (true, true),
                        (true, true), (true, false), (false, false)]
        for (entry, state) in zip(logs, expected) {
            let segment = try XCTUnwrap(segments[entry.id])
            XCTAssertEqual(segment.focusBefore, state.0)
            XCTAssertEqual(segment.focusAfter, state.1)
        }
    }

    func testCrossMidnightAndFilteredRowsUseFullChronology() throws {
        let midnight = Date().timeIntervalSince1970.rounded(.down) + 86400
        let start = log(midnight - 600, event: .start)
        let note = log(midnight + 1, event: .note)
        let end = log(midnight + 900, event: .end)
        let segments = LogTimelineSegment.segments(in: [end, note, start])
        XCTAssertEqual(segments[note.id]?.focusBefore, true)
        XCTAssertEqual(segments[end.id]?.focusBefore, true)
        XCTAssertEqual(segments[end.id]?.focusAfter, false)
        // 日期或待办筛选只取某些节点时，仍使用完整来源算出的区段。
        XCTAssertEqual([note, end].compactMap { segments[$0.id]?.focusBefore }, [true, true])
    }

    func testLegacyMarkersMultipleSessionsAndOpenSession() {
        let logs = [log(0, event: .end), log(1, text: "▶ 开始专注", focus: true),
                    log(2, text: "■ 结束专注", focus: true), log(3),
                    log(4, event: .start), log(5, event: .review), log(6)]
        let segments = LogTimelineSegment.segments(in: logs)
        XCTAssertEqual(segments[logs[0].id]?.focusBefore, false)
        XCTAssertEqual(segments[logs[1].id]?.focusAfter, true)
        XCTAssertEqual(segments[logs[2].id]?.focusAfter, false)
        XCTAssertEqual(segments[logs[3].id]?.focusBefore, false)
        XCTAssertEqual(segments[logs[6].id]?.focusAfter, true)
        XCTAssertTrue(LogTimelineSegment.segments(in: []).isEmpty)
    }
}
