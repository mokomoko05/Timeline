import XCTest
import TimelineCore
@testable import TimelineKit

@MainActor
final class TagCLITests: XCTestCase {
    /// 论文（#1）打上「科研/论文」，周报（#2）打上「科研」，牛奶（#3）不打标签。
    private func tagged() throws -> Fixture {
        let fixture = try Fixture.make(testCase: self, saved: false)
        fixture.store.setTags(fixture.paper.id, ["科研/论文"])
        fixture.store.setTags(fixture.report.id, ["科研"])
        fixture.store.save()
        return fixture
    }

    func testNotesByTagGatherAllTaggedTasksIncludingSubtags() throws {
        let fixture = try tagged()
        let result = runCLI(["notes", "科研"], directory: fixture.directory)
        XCTAssertEqual(result.code, 0, result.err)
        XCTAssertTrue(result.out.contains("#科研"), result.out)
        XCTAssertTrue(result.out.contains("2 个待办"), result.out)
        XCTAssertTrue(result.out.contains("读完摘要"), "子标签「科研/论文」的笔记一起汇总")
        XCTAssertTrue(result.out.contains("周报发出去了"))
        XCTAssertFalse(result.out.contains("随手记一笔"), "没关联待办的日志不算")
        XCTAssertFalse(result.out.contains("开始专注"), "不含专注记录")
        let sub = runCLI(["notes", "#科研/论文"], directory: fixture.directory)
        XCTAssertTrue(sub.out.contains("读完摘要"))
        XCTAssertFalse(sub.out.contains("周报发出去了"), "子标签不含上级的其他待办")
        XCTAssertEqual(runCLI(["notes", "3"], directory: fixture.directory).code, 0, "数字仍是任务编号")
    }

    func testLogsTagFilterAndTasksShowTags() throws {
        let fixture = try tagged()
        let logs = runCLI(["logs", "--tag", "科研/论文", "-a"], directory: fixture.directory)
        XCTAssertTrue(logs.out.contains("坐标轴"))
        XCTAssertFalse(logs.out.contains("周报发出去了"))
        let withFocus = runCLI(["logs", "--tag", "科研", "--focus", "-a"], directory: fixture.directory)
        XCTAssertTrue(withFocus.out.contains("开始专注"), "专注记录也带标签，--focus 时能按标签查到")
        XCTAssertEqual(runCLI(["logs", "--tag", "12"], directory: fixture.directory).code, 2, "纯数字不是标签")
        let tasks = runCLI(["tasks"], directory: fixture.directory)
        XCTAssertTrue(tasks.out.contains("#科研/论文"), tasks.out)
        let only = runCLI(["tasks", "--tag", "科研/论文"], directory: fixture.directory)
        XCTAssertTrue(only.out.contains("EuroSys") && !only.out.contains("周报"), only.out)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(runCLI(["tasks", "--json"], directory: fixture.directory).out.utf8)) as? [[String: Any]])
        XCTAssertEqual(json.first { $0["number"] as? Int == 1 }?["tags"] as? [String], ["科研/论文"])
    }

    func testTagsCommandListsCounts() throws {
        let fixture = try tagged()
        let result = runCLI(["tags"], directory: fixture.directory)
        XCTAssertEqual(result.code, 0, result.err)
        XCTAssertTrue(result.out.contains("#科研") && result.out.contains("2 个待办"), result.out)
        XCTAssertTrue(result.out.contains("#科研/论文"))
        let empty = try Fixture.make(testCase: self)
        XCTAssertTrue(runCLI(["tags"], directory: empty.directory).err.contains("还没有标签"))
    }
}
