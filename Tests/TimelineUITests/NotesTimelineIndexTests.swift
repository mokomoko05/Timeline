import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class NotesTimelineIndexTests: XCTestCase {
    func testTagNotebookWithoutTasksGetsAMonthGroupedTimeline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let calendar = JournalDates.calendar
        let base = calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 10))!
        for (offset, count) in [(0, 2), (3, 1), (4, 3)] {
            let day = calendar.date(byAdding: .day, value: offset, to: base)!
            for index in 0..<count {
                _ = try store.quickLogEntry("想法 \(offset)-\(index)", linkDefault: false, tags: ["Ideas"], on: day,
                                            now: day.addingTimeInterval(TimeInterval(index * 60)))
            }
        }
        XCTAssertTrue(store.tasks(taggedWith: "Ideas").isEmpty, "这个笔记本没有任何待办")
        let months = NotesTimelineIndex.months(store.notes(forTag: "Ideas"))
        XCTAssertEqual(months.map(\.id), ["2026-09", "2026-10"])
        XCTAssertEqual(months.map { $0.days.map(\.key) }, [["2026-09-29"], ["2026-10-02", "2026-10-03"]])
        XCTAssertEqual(months.map(\.count), [2, 4])
        let first = try XCTUnwrap(months.last?.days.last)
        let earliest = store.notes(forTag: "Ideas").filter { $0.key == first.key }.min { $0.log.createdAt < $1.log.createdAt }
        XCTAssertEqual(first.firstNoteID, earliest?.id, "跳转定位到那一天最早的一条")
        XCTAssertEqual(NotesTimelineIndex.dayAnchor(first.key), "day-2026-10-03")
    }

    func testEmptyNotesHaveNoTimeline() {
        XCTAssertTrue(NotesTimelineIndex.months([]).isEmpty)
    }
}
