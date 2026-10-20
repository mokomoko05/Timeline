import XCTest
import TimelineCore
@testable import TimelineKit

@MainActor
final class CLITests: XCTestCase {
    func testLogsDefaultsToTheLast30AndFiltersApply() throws {
        let fixture = try Fixture.make(testCase: self)
        let all = runCLI(["logs"], directory: fixture.directory)
        XCTAssertEqual(all.code, 0, all.err)
        XCTAssertTrue(all.out.contains("读完摘要"), all.out)
        XCTAssertFalse(all.out.contains("开始专注"), "默认不含专注记录")
        XCTAssertTrue(runCLI(["logs", "--focus"], directory: fixture.directory).out.contains("开始专注"))
        let task2 = runCLI(["logs", "-t", "2"], directory: fixture.directory)
        XCTAssertTrue(task2.out.contains("周报发出去了"))
        XCTAssertFalse(task2.out.contains("读完摘要"))
        XCTAssertTrue(runCLI(["logs", "-t", "#2"], directory: fixture.directory).out.contains("周报发出去了"), "#2 写法也行")
        XCTAssertTrue(runCLI(["logs", "--task=1,2"], directory: fixture.directory).out.contains("周报发出去了"))
        let day = runCLI(["logs", "-d", "2026-10-07"], directory: fixture.directory)
        XCTAssertTrue(day.out.contains("随手记一笔"))
        XCTAssertFalse(day.out.contains("周报发出去了"))
        XCTAssertTrue(runCLI(["logs", "-k", "block"], directory: fixture.directory).out.contains("坐标轴"))
        XCTAssertTrue(runCLI(["logs", "-g", "latency"], directory: fixture.directory).out.contains("截了张图"), "搜截图里的文字")
        XCTAssertEqual(runCLI(["logs", "-n", "1", "--porcelain"], directory: fixture.directory).out.split(separator: "\n").count, 1)
        let empty = runCLI(["logs", "-g", "没有这个词"], directory: fixture.directory)
        XCTAssertEqual(empty.code, 0)
        XCTAssertTrue(empty.err.contains("没有符合条件的日志"))
    }

    func testOutputFormats() throws {
        let fixture = try Fixture.make(testCase: self)
        let json = runCLI(["logs", "--json"], directory: fixture.directory)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [[String: Any]])?.count, 5)
        let porcelain = runCLI(["logs", "--porcelain", "-a"], directory: fixture.directory)
        XCTAssertEqual(porcelain.out.split(separator: "\n").count, 5)
        XCTAssertTrue(porcelain.out.split(separator: "\n").allSatisfy { $0.split(separator: "\t", omittingEmptySubsequences: false).count == 6 })
        XCTAssertTrue(runCLI(["logs", "--md"], directory: fixture.directory).out.hasPrefix("# 日志\n"))
        XCTAssertTrue(runCLI(["logs", "--format", "md", "-t", "2"], directory: fixture.directory).out.contains("- 17:20 [DONE]"))
        let bad = runCLI(["logs", "--format", "xml"], directory: fixture.directory)
        XCTAssertEqual(bad.code, 2)
        XCTAssertTrue(bad.err.contains("不认识的输出格式"))
    }

    func testPipedOutputIsPlainAndTtyOutputIsColoredUnlessDisabled() throws {
        let fixture = try Fixture.make(testCase: self)
        XCTAssertFalse(runCLI(["logs"], directory: fixture.directory).out.contains("\u{1B}"), "输出被管道接走时不着色")
        XCTAssertTrue(runCLI(["logs"], directory: fixture.directory, tty: true).out.contains("\u{1B}[3"), "终端里着色")
        XCTAssertFalse(runCLI(["logs"], directory: fixture.directory, tty: true, env: ["NO_COLOR": "1"]).out.contains("\u{1B}"), "NO_COLOR")
        XCTAssertFalse(runCLI(["logs", "--no-color"], directory: fixture.directory, tty: true).out.contains("\u{1B}"))
        XCTAssertTrue(runCLI(["logs", "--color", "always"], directory: fixture.directory).out.contains("\u{1B}["))
        XCTAssertFalse(runCLI(["logs"], directory: fixture.directory, tty: true, env: ["TERM": "dumb"]).out.contains("\u{1B}"))
    }

    func testShowByIdWithAmbiguousAndMissingReferences() throws {
        let fixture = try Fixture.make(testCase: self)
        let ids = runCLI(["logs", "--porcelain", "-a"], directory: fixture.directory).out.split(separator: "\n").map { String($0.split(separator: "\t")[0]) }
        let shown = runCLI(["show", ids[0]], directory: fixture.directory)
        XCTAssertEqual(shown.code, 0, shown.err)
        XCTAssertTrue(shown.out.contains("读完摘要，公式 3 看不懂"))
        XCTAssertTrue(shown.out.contains("#1 读 EuroSys 论文"))
        XCTAssertTrue(runCLI(["show", String(ids[0].prefix(5)), "--json"], directory: fixture.directory).out.contains("\"kind\" : \"note\""))
        XCTAssertEqual(runCLI(["show", "zzzzzz"], directory: fixture.directory).code, 1)
        XCTAssertEqual(runCLI(["show"], directory: fixture.directory).code, 2)
        // 构造一个必然有歧义的前缀：所有 id 共同的最长前缀（至少 3 位时才查得到）。
        XCTAssertTrue(runCLI(["show", "000"], directory: fixture.directory).code == 1)
    }

    func testNotesForATaskIncludeHeaderMetaAndMarkdown() throws {
        let fixture = try Fixture.make(testCase: self)
        let notes = runCLI(["notes", "1"], directory: fixture.directory)
        XCTAssertEqual(notes.code, 0, notes.err)
        XCTAssertTrue(notes.out.hasPrefix("#1 读 EuroSys 论文\n3 条笔记"), notes.out)
        XCTAssertFalse(notes.out.contains("开始专注"), "笔记不含专注记录")
        XCTAssertFalse(notes.out.contains("周报"), "只含这个任务的")
        let markdown = runCLI(["notes", "#1", "--md"], directory: fixture.directory)
        XCTAssertTrue(markdown.out.hasPrefix("# #1 读 EuroSys 论文\n\n## 2026-10-07"), markdown.out)
        let unknown = runCLI(["notes", "abc"], directory: fixture.directory)
        XCTAssertEqual(unknown.code, 1, "不是编号就当标签找；没有这个标签时报错，拼错了脚本能发现")
        XCTAssertTrue(unknown.err.contains("没有标签「abc」"), unknown.err)
        XCTAssertEqual(runCLI(["notes"], directory: fixture.directory).code, 2)
        let none = runCLI(["notes", "3"], directory: fixture.directory)
        XCTAssertTrue(none.err.contains("还没有笔记"))
    }

    func testFocusEventsStayInLogsButNotInTaskOrTagNotebooks() throws {
        let fixture = try Fixture.make(testCase: self)
        fixture.store.setTags(fixture.paper.id, ["reading"])
        fixture.store.addFocusLog("▶ 开始专注", taskID: fixture.paper.id, now: fixture.day2,
                                  event: .start, goal: "Focus goal", plannedSeconds: 1500)
        _ = try fixture.store.quickLogEntry("Focus observation", taskID: fixture.paper.id, on: fixture.day2, focusEvent: .note)
        _ = try fixture.store.quickLogEntry("Stage feedback", taskID: fixture.paper.id, on: fixture.day2, focusEvent: .review)
        fixture.store.addFocusLog("■ 结束专注", taskID: fixture.paper.id, now: fixture.day2.addingTimeInterval(1500),
                                  event: .end)
        fixture.store.save()
        for target in ["1", "reading"] {
            let result = runCLI(["notes", target, "--focus", "--md"], directory: fixture.directory)
            XCTAssertEqual(result.code, 0, result.err)
            XCTAssertTrue(result.out.contains("Focus observation"))
            for marker in ["[FOCUS]", "[REVIEW]", "[END]"] { XCTAssertFalse(result.out.contains(marker), result.out) }
        }
        let result = runCLI(["logs", "--focus", "--md"], directory: fixture.directory)
        for marker in ["[FOCUS]", "[NOTE]", "[REVIEW]", "[END]"] { XCTAssertTrue(result.out.contains(marker), result.out) }
    }

    func testTasksAndStatus() throws {
        let fixture = try Fixture.make(testCase: self)
        let tasks = runCLI(["tasks"], directory: fixture.directory)
        XCTAssertTrue(tasks.out.contains("#1") && tasks.out.contains("#3"))
        let json = runCLI(["tasks", "--json", "--all"], directory: fixture.directory)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [[String: Any]])?.count, 3)
        let status = runCLI(["status"], directory: fixture.directory)
        XCTAssertEqual(status.code, 0)
        XCTAssertTrue(status.out.contains("3 个未完成 / 共 3 个"), status.out)
        XCTAssertTrue(status.out.contains("5 条"))
        XCTAssertTrue(status.out.contains("没有运行"), "没有 socket 时如实说应用没在运行")
    }

    func testPickNeedsATtyAndPrintsTheSelectedIdWhenAnInjectedPickerSelects() throws {
        let fixture = try Fixture.make(testCase: self)
        let refused = runCLI(["pick"], directory: fixture.directory, tty: false)
        XCTAssertEqual(refused.code, 2)
        XCTAssertTrue(refused.err.contains("fzf"))
        var out = ""
        var picked: PickerState?
        var environment = CLIEnvironment(arguments: ["pick", "-t", "1", "--dir", fixture.directory.path], stdoutIsTTY: true, stdinIsTTY: true, columns: 90,
                                         out: { out += $0 }, err: { _ in }, runPicker: { state, _, _ in
            picked = state
            return InteractivePicker.Outcome(selected: state.current, message: nil)
        })
        environment.currentDirectory = fixture.directory.path
        XCTAssertEqual(CLI.run(environment), 0)
        XCTAssertEqual(picked?.visible.count, 3, "pick 也支持筛选")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines).count, 8, "输出选中那条的短标识")
    }

    func testArgumentErrorsAndHelp() throws {
        let fixture = try Fixture.make(testCase: self)
        XCTAssertEqual(runCLI(["wat"], directory: fixture.directory).code, 2)
        XCTAssertEqual(runCLI(["logs", "-t", "abc"], directory: fixture.directory).code, 2)
        XCTAssertEqual(runCLI(["logs", "-d", "下周"], directory: fixture.directory).code, 2)
        XCTAssertEqual(runCLI(["logs", "-k", "bogus"], directory: fixture.directory).code, 2)
        XCTAssertEqual(runCLI(["logs", "-n"], directory: fixture.directory).code, 2, "缺少值")
        XCTAssertEqual(runCLI(["logs", "-n", "-3"], directory: fixture.directory).code, 2)
        let help = runCLI(["help"], directory: fixture.directory)
        XCTAssertEqual(help.code, 0)
        XCTAssertTrue(help.out.contains("timeline log [-t N]"))
        XCTAssertTrue(help.out.contains("fzf"))
        XCTAssertEqual(runCLI(["--version"], directory: fixture.directory).out, "timeline \(CLI.version)\n")
        XCTAssertEqual(runCLI([], directory: fixture.directory).code, 2)
    }

    func testCorruptDataFailsLoudlyWithoutTouchingTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-bad-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("journal.json")
        try Data("{ broken".utf8).write(to: file)
        let result = runCLI(["logs"], directory: directory)
        XCTAssertEqual(result.code, 1)
        XCTAssertTrue(result.err.contains("无法读取日记"))
        XCTAssertEqual(try String(contentsOf: file), "{ broken")
    }

    func testWritingWithoutARunningAppReportsItAndNeverLaunchesWithNoLaunch() throws {
        let fixture = try Fixture.make(testCase: self)
        var launched = 0
        let result = runCLI(["log", "--no-launch", "hello"], directory: fixture.directory, launch: { launched += 1 })
        XCTAssertEqual(result.code, 1)
        XCTAssertTrue(result.err.contains("没有在运行"), result.err)
        XCTAssertEqual(launched, 0)
        XCTAssertEqual(runCLI(["log"], directory: fixture.directory, tty: true).code, 2, "没有内容")
        XCTAssertEqual(runCLI(["todo"], directory: fixture.directory).code, 2)
        XCTAssertEqual(runCLI(["done"], directory: fixture.directory).code, 2)
        XCTAssertEqual(runCLI(["done", "abc"], directory: fixture.directory).code, 2)
        XCTAssertEqual(runCLI(["log", "-t", "x", "hi"], directory: fixture.directory).code, 2)
        XCTAssertEqual(fixture.snapshot().allLogs(includeFocus: true).count, 6, "没有写入任何数据")
    }
}
