import XCTest
import TimelineCore
@testable import TimelineKit

@MainActor
final class ReadOnlyAndQueryTests: XCTestCase {
    private func snapshotOfFiles(_ directory: URL) -> [String: Date] {
        var result: [String: Date] = [:]
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = enumerator?.nextObject() as? URL {
            result[url.path] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return result
    }

    func testReadOnlySnapshotSeesTheDataButNeverWritesAnything() throws {
        let fixture = try Fixture.make(testCase: self)
        let before = snapshotOfFiles(fixture.directory)
        let snapshot = fixture.snapshot()
        XCTAssertTrue(snapshot.isReadOnly)
        XCTAssertNil(snapshot.errorMessage)
        XCTAssertEqual(snapshot.allLogs(includeFocus: true).count, 6)
        XCTAssertEqual(snapshot.locate(number: 1)?.task.title.contains("EuroSys"), true)
        snapshot.addTodo("不该被写入", on: fixture.day1)
        _ = try? snapshot.quickLog("不该被写入", on: fixture.day1)
        snapshot.save()
        XCTAssertEqual(snapshotOfFiles(fixture.directory), before, "只读打开不创建、不修改任何文件（包括备份）")
        XCTAssertEqual(snapshot.allLogs(includeFocus: true).count, 6, "修改接口都不生效")
    }

    func testReadOnlySnapshotOfAnOldFormatFileMigratesInMemoryOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-old-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let legacy = Data(#"{"version":5,"days":{"2026-10-06":{"todos":[{"id":"11111111-1111-1111-1111-111111111111","title":"旧任务","completed":false}],"summary":""}}}"#.utf8)
        try legacy.write(to: directory.appendingPathComponent("journal.json"))
        let snapshot = JournalStore(directory: directory, readOnlySnapshot: true)
        XCTAssertNil(snapshot.errorMessage)
        XCTAssertEqual(snapshot.locate(number: 1)?.task.title, "旧任务", "内存里已经补了编号")
        XCTAssertNotNil(snapshot.locate(number: 1)?.task.dueDate, "旧的所在日期当作截止日期")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("journal.json")), legacy, "磁盘上的原文件一字未动")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["journal.json"], "没有生成备份或迁移文件")
    }

    func testMissingOrCorruptDataIsReportedNotCrashed() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-none-" + UUID().uuidString)
        let missing = JournalStore(directory: empty, readOnlySnapshot: true)
        XCTAssertNil(missing.errorMessage)
        XCTAssertTrue(missing.allLogs().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path), "读不存在的目录不会把它创建出来")
        let corrupt = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-bad-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: corrupt) }
        try Data("{ not json".utf8).write(to: corrupt.appendingPathComponent("journal.json"))
        XCTAssertNotNil(JournalStore(directory: corrupt, readOnlySnapshot: true).errorMessage)
    }

    func testFiltersByTaskDateKindTextAndImageOcr() throws {
        let fixture = try Fixture.make(testCase: self)
        let store = fixture.snapshot()
        func rows(_ configure: (inout LogFilter) -> Void) -> [String] {
            var filter = LogFilter()
            configure(&filter)
            return LogQuery.rows(in: store, filter: filter).map(\.text)
        }
        XCTAssertEqual(rows { _ in }.count, 5, "默认不含专注记录")
        XCTAssertEqual(rows { $0.includeFocus = true }.count, 6)
        XCTAssertEqual(rows { $0.tasks = [1] }.count, 3)
        XCTAssertEqual(rows { $0.tasks = [2] }, ["周报发出去了"])
        XCTAssertEqual(rows { $0.tasks = [1, 2] }.count, 4)
        XCTAssertEqual(rows { $0.since = fixture.day2; $0.until = fixture.day2 }.count, 2)
        XCTAssertEqual(rows { $0.until = fixture.day1 }.count, 3)
        XCTAssertEqual(rows { $0.kinds = [.block] }, ["图 4 的坐标轴没标单位"])
        XCTAssertEqual(rows { $0.grep = "公式" }, ["读完摘要，公式 3 看不懂"])
        XCTAssertEqual(rows { $0.grep = "throughput" }.count, 1, "能搜到截图里识别出的文字，且不区分大小写")
        XCTAssertEqual(rows { $0.grep = "EuroSys" }.count, 3, "也搜任务标题")
        XCTAssertEqual(rows { $0.onlyWithImages = true }.count, 1)
        XCTAssertEqual(rows { $0.last = 2 }, ["截了张图 https://example.com/fig4", "周报发出去了"], "最近 2 条，仍按时间升序")
        XCTAssertEqual(rows { $0.reverse = true }.first, "周报发出去了")
        XCTAssertEqual(rows { $0.tasks = [1]; $0.grep = "没有这个词" }, [])
    }

    func testRowsUseTheLiveTaskNumberAndTitleAndSurviveDeletedTasks() throws {
        let fixture = try Fixture.make(testCase: self)
        fixture.store.renameTodo(fixture.paper.id, title: "读 EuroSys 论文（改名后）", on: fixture.paper.date)
        fixture.store.deleteTodo(fixture.report.id, on: fixture.report.date)
        fixture.store.save()
        let store = fixture.snapshot()
        var filter = LogFilter()
        filter.tasks = [1]
        XCTAssertTrue(LogQuery.rows(in: store, filter: filter).allSatisfy { $0.taskTitle == "读 EuroSys 论文（改名后）" })
        filter.tasks = [2]
        let orphan = LogQuery.rows(in: store, filter: filter)
        XCTAssertEqual(orphan.count, 1, "任务删了，日志仍按当时记下的编号可以筛出来")
        XCTAssertEqual(orphan.first?.taskTitle, "写周报")
    }

    func testLookupByShortIdPrefix() throws {
        let fixture = try Fixture.make(testCase: self)
        let store = fixture.snapshot()
        let first = try XCTUnwrap(LogQuery.rows(in: store, filter: LogFilter()).first)
        XCTAssertEqual(LogQuery.lookup(first.shortID, in: store), .found(first.id))
        XCTAssertEqual(LogQuery.lookup(first.id.uuidString, in: store), .found(first.id), "完整 UUID 也行")
        XCTAssertEqual(LogQuery.lookup(String(first.shortID.prefix(5)).uppercased(), in: store), .found(first.id), "前缀、不分大小写")
        XCTAssertEqual(LogQuery.lookup("zz", in: store), .notFound, "少于 3 位不查")
        XCTAssertEqual(LogQuery.lookup("zzzzzz", in: store), .notFound)
    }

    func testDateArguments() {
        let now = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 15))!
        func key(_ text: String) -> String? { DateArgument.parse(text, now: now).map(JournalDates.key) }
        XCTAssertEqual(key("2026-10-07"), "2026-10-07")
        XCTAssertEqual(key("10-07"), "2026-10-07")
        XCTAssertEqual(key("today"), "2026-10-08")
        XCTAssertEqual(key("昨天"), "2026-10-07")
        XCTAssertEqual(key("7d"), "2026-10-01")
        XCTAssertEqual(key("0d"), "2026-10-08")
        XCTAssertNil(key("2026-13-45"))
        XCTAssertNil(key("下周"))
        XCTAssertNil(key("02-30"))
    }
}
