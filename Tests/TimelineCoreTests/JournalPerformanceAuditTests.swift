import XCTest
@testable import TimelineCore

@MainActor
final class JournalPerformanceAuditTests: XCTestCase {
    private struct Fixture: Encodable {
        let version = 8
        let days: [String: DayEntry]
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTagCreationWithTenThousandLogs() throws {
        var days: [String: DayEntry] = [:]
        let start = JournalDates.date(for: "2025-01-01")!
        for offset in 0..<200 {
            let date = JournalDates.calendar.date(byAdding: .day, value: offset, to: start)!
            var entry = DayEntry()
            entry.todos = (0..<5).map { index in
                var task = Todo(title: "Audit task \(offset)-\(index)")
                task.tags = ["Audit/History"]
                return task
            }
            entry.logs = (0..<50).map { index in
                DailyLogEntry(createdAt: date.addingTimeInterval(Double(index)), kind: .note,
                              text: "Synthetic audit record \(index)", tags: ["Audit/History"])
            }
            days[JournalDates.key(date)] = entry
        }
        let url = try directory()
        try JSONEncoder().encode(Fixture(days: days)).write(to: url.appendingPathComponent("journal.json"))
        let store = JournalStore(directory: url)
        let started = Date()
        XCTAssertEqual(store.createTag("Audit/New"), "Audit/New")
        let elapsed = Date().timeIntervalSince(started)
        print("PERFORMANCE AUDIT: 1000 tasks, 10000 logs, createTag \(elapsed * 1000) ms (debug)")
        XCTAssertLessThan(elapsed, 5, "Creating a tag must finish even with substantial history")
        let reloaded = JournalStore(directory: url)
        XCTAssertEqual(reloaded.tasks().count, 1000)
        XCTAssertEqual(reloaded.allLogs(includeFocus: true).count, 10000)
        XCTAssertTrue(reloaded.allTags().contains { $0.name == "Audit/New" })
        // 同样的历史，开启后台写入后主线程只付快照的代价。
        let background = JournalStore(directory: url)
        background.writesInBackground = true
        let task = try XCTUnwrap(background.tasks().first)
        var toggles: [Double] = []
        for _ in 0..<10 {
            let begin = Date()
            background.toggleTodo(task.id, on: task.date)
            toggles.append(Date().timeIntervalSince(begin) * 1000)
        }
        background.waitForPendingWrites()
        toggles.sort()
        print("PERFORMANCE AUDIT: 1000 tasks, 10000 logs, toggle main-thread ms with background writes min/median/max: \(toggles.first!)/\(toggles[5])/\(toggles.last!) (debug)")
        XCTAssertEqual(JournalStore(directory: url, readOnlySnapshot: true).locate(task.id)?.task.completed, background.locate(task.id)?.task.completed)
    }

    /// Explicit opt-in: work only on a temporary copy, never change the source journal.
    func testLocalJournalCopyWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["TIMELINE_AUDIT_JOURNAL"] else {
            throw XCTSkip("Set TIMELINE_AUDIT_JOURNAL to benchmark a temporary copy of a local journal")
        }
        let url = try directory()
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url.appendingPathComponent("journal.json"))
        let store = JournalStore(directory: url)
        let taskCount = store.tasks().count, logCount = store.allLogs(includeFocus: true).count
        var timings: [Double] = []
        for index in 0..<30 {
            let started = Date()
            XCTAssertNotNil(store.createTag("性能审计/\(index)"))
            timings.append(Date().timeIntervalSince(started) * 1000)
        }
        timings.sort()
        print("PERFORMANCE AUDIT: local copy, \(taskCount) tasks, \(logCount) logs; createTag 30x min/median/max ms: \(timings.first!)/\(timings[15])/\(timings.last!)")
        XCTAssertEqual(store.tasks().count, taskCount)
        XCTAssertEqual(store.allLogs(includeFocus: true).count, logCount)
    }
}
