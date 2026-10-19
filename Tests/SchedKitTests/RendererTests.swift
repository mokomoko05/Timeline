import XCTest
import DayleafCore
@testable import SchedKit

@MainActor
final class RendererTests: XCTestCase {
    private func context(_ fixture: Fixture, width: Int = 80, style: Style = .plain, imageProtocol: ImageProtocol = .none) -> RenderContext {
        RenderContext(width: width, style: style, imageProtocol: imageProtocol, imagesDirectory: fixture.directory.appendingPathComponent("Images"))
    }

    func testListGroupsByDayAndShowsTimeKindTaskAndImageHint() throws {
        let fixture = try Fixture.make(testCase: self)
        let rows = LogQuery.rows(in: fixture.snapshot(), filter: LogFilter())
        let text = LogRenderer.list(rows, ctx: context(fixture)).joined(separator: "\n")
        XCTAssertTrue(text.contains("── 2026-10-07 周三"), text)
        XCTAssertTrue(text.contains("── 2026-10-08 周四"))
        XCTAssertTrue(text.contains("09:05  INFO    #1   读完摘要，公式 3 看不懂"))
        XCTAssertTrue(text.contains("10:30  BLOCK   #1   图 4 的坐标轴没标单位"))
        XCTAssertTrue(text.contains("17:20  DONE    #2   周报发出去了"))
        XCTAssertTrue(text.contains("🖼 1 张图片（sched show"), "带图片的日志提示怎么查看")
        XCTAssertFalse(text.contains("\u{1B}"), "不着色时没有任何转义序列")
    }

    func testEveryRenderedLineFitsTheTerminalWidthEvenWithChineseText() throws {
        let fixture = try Fixture.make(testCase: self)
        let long = "这是一条很长很长的日志，用来确认中文按显示宽度换行而且续行缩进对齐，不会超出终端宽度导致错位。" + String(repeating: "再来一些内容", count: 5)
        _ = try fixture.store.quickLog(long, taskID: fixture.paper.id, on: fixture.day2)
        let rows = LogQuery.rows(in: fixture.store, filter: LogFilter())
        for width in [40, 60, 80] {
            let lines = LogRenderer.list(rows, ctx: context(fixture, width: width))
            XCTAssertTrue(lines.allSatisfy { TerminalText.width($0) <= width }, "宽度 \(width)：\(lines.first { TerminalText.width($0) > width } ?? "")")
            XCTAssertEqual(lines.filter { $0.contains("再来一些内容") || $0.contains("这是一条很长") }.isEmpty, false)
        }
    }

    func testColorModeAddsLinksAndStylesButKeepsTheSameVisibleText() throws {
        let fixture = try Fixture.make(testCase: self)
        let rows = LogQuery.rows(in: fixture.snapshot(), filter: LogFilter())
        let plain = LogRenderer.list(rows, ctx: context(fixture)).map { $0 }
        let colored = LogRenderer.list(rows, ctx: context(fixture, style: Style(enabled: true)))
        XCTAssertTrue(colored.joined().contains("\u{1B}]8;;https://example.com/fig4\u{07}"), "裸网址变成可点击的超链接")
        XCTAssertEqual(colored.map(TerminalText.stripEscapes), plain, "着色前后可见文字完全一致")
    }

    func testDetailShowsFullTextTaskAndImagePathWhenTheTerminalCannotDrawImages() throws {
        let fixture = try Fixture.make(testCase: self)
        let row = try XCTUnwrap(LogQuery.rows(in: fixture.snapshot(), filter: { var f = LogFilter(); f.onlyWithImages = true; return f }()).first)
        let lines = LogRenderer.detail(row, ctx: context(fixture))
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("2026-10-08 08:40"))
        XCTAssertTrue(text.contains("#1 读 EuroSys 论文"))
        XCTAssertTrue(text.contains(row.images[0]), "不支持内联图片时打印文件路径")
        XCTAssertTrue(text.contains("识别文字：Throughput (ops/s) latency"))
    }

    func testDetailDrawsTheImageInlineWhenTheProtocolIsSupported() throws {
        let fixture = try Fixture.make(testCase: self)
        let row = try XCTUnwrap(LogQuery.rows(in: fixture.snapshot(), filter: { var f = LogFilter(); f.onlyWithImages = true; return f }()).first)
        let iterm = LogRenderer.detail(row, ctx: context(fixture, imageProtocol: .iterm2)).joined(separator: "\n")
        XCTAssertTrue(iterm.contains("\u{1B}]1337;File="), "iTerm2 / 日页内置终端协议")
        let kitty = LogRenderer.detail(row, ctx: context(fixture, imageProtocol: .kitty)).joined(separator: "\n")
        XCTAssertTrue(kitty.contains("\u{1B}_Ga=T,f=100"))
    }

    func testMissingImageFileIsReportedInsteadOfCrashing() throws {
        let fixture = try Fixture.make(testCase: self)
        let row = try XCTUnwrap(LogQuery.rows(in: fixture.snapshot(), filter: { var f = LogFilter(); f.onlyWithImages = true; return f }()).first)
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("Images").appendingPathComponent(row.images[0]))
        XCTAssertTrue(LogRenderer.detail(row, ctx: context(fixture)).joined().contains("找不到图片文件"))
    }

    func testPorcelainIsTabSeparatedWithSixColumnsAndNoNewlinesInText() throws {
        let fixture = try Fixture.make(testCase: self)
        _ = try fixture.store.quickLog("第一行\n第二行\t带制表符", taskID: fixture.report.id, on: fixture.day2)
        let lines = LogRenderer.porcelain(LogQuery.rows(in: fixture.store, filter: LogFilter()))
        XCTAssertTrue(lines.allSatisfy { $0.split(separator: "\t", omittingEmptySubsequences: false).count == 6 }, "\(lines)")
        let multi = try XCTUnwrap(lines.first { $0.contains("第一行") })
        XCTAssertTrue(multi.hasSuffix("第一行 第二行 带制表符"))
        XCTAssertEqual(multi.split(separator: "\t")[4], "#2")
        XCTAssertEqual(lines.first?.split(separator: "\t").first?.count, 8, "第一列是 8 位短标识")
    }

    func testJsonAndMarkdownOutputs() throws {
        let fixture = try Fixture.make(testCase: self)
        let rows = LogQuery.rows(in: fixture.snapshot(), filter: { var f = LogFilter(); f.tasks = [1]; return f }())
        let object = try JSONSerialization.jsonObject(with: Data(LogRenderer.json(rows).utf8)) as? [[String: Any]]
        XCTAssertEqual(object?.count, 3)
        XCTAssertEqual(object?.last?["kind"] as? String, "note")
        XCTAssertEqual(object?.last?["task"] as? Int, 1)
        XCTAssertEqual((object?.last?["images"] as? [String])?.count, 1)
        XCTAssertEqual((object?.last?["image_text"] as? [String: String])?.values.first, "Throughput (ops/s) latency")
        let markdown = LogRenderer.markdown(title: "#1 读 EuroSys 论文", rows: rows)
        XCTAssertTrue(markdown.hasPrefix("# #1 读 EuroSys 论文\n\n## 2026-10-07\n- 09:05 [INFO] 读完摘要，公式 3 看不懂"), markdown)
        XCTAssertTrue(markdown.contains("## 2026-10-08"))
        XCTAssertTrue(markdown.contains("![](Images/"), "图片引用 Images 文件夹")
        XCTAssertTrue(markdown.contains("[BLOCK]"))
    }

    func testTaskListShowsNumbersDueNotesAndFocus() throws {
        let fixture = try Fixture.make(testCase: self)
        fixture.store.setDeadline(fixture.paper.id, to: fixture.day2)
        fixture.store.save()
        let store = fixture.snapshot()
        let now = JournalDates.calendar.date(bySettingHour: 12, minute: 0, second: 0, of: fixture.day2)!
        let rows = LogRenderer.taskRows(in: store, includeCompleted: false)
        XCTAssertEqual(rows.map(\.number), [1, 2, 3], "按截止时间排序，没有截止的在最后")
        let lines = LogRenderer.tasks(rows, ctx: context(fixture), now: now)
        XCTAssertTrue(lines[0].contains("#1") && lines[0].contains("今天") && lines[0].contains("3 条笔记"), lines[0])
        XCTAssertTrue(lines[2].contains("买牛奶"))
        XCTAssertTrue(lines.allSatisfy { TerminalText.width($0) <= 80 })
        fixture.store.toggleTodo(fixture.report.id, on: fixture.report.date)
        fixture.store.save()
        XCTAssertEqual(LogRenderer.taskRows(in: fixture.snapshot(), includeCompleted: false).map(\.number), [1, 3])
        XCTAssertEqual(LogRenderer.taskRows(in: fixture.snapshot(), includeCompleted: true).count, 3)
    }

    func testFocusTimelineMarkersAndGoalSurviveRenderingSearchAndExport() throws {
        let fixture = try Fixture.make(testCase: self)
        let goal = "Understand throughput\nCheck the evaluation method"
        let start = try XCTUnwrap(fixture.store.addFocusLog("▶ 开始专注", taskID: fixture.paper.id,
            now: fixture.day2, event: .start, goal: goal, plannedSeconds: 1500))
        _ = try fixture.store.quickLogEntry("Observation", taskID: fixture.paper.id, on: fixture.day2,
            now: fixture.day2.addingTimeInterval(60), focusEvent: .note)
        _ = try fixture.store.quickLogEntry("Review result", taskID: fixture.paper.id, on: fixture.day2,
            now: fixture.day2.addingTimeInterval(1500), focusEvent: .review)
        fixture.store.addFocusLog("■ 结束专注", taskID: fixture.paper.id,
            now: fixture.day2.addingTimeInterval(1501), seconds: 1500, event: .end)
        var filter = LogFilter()
        filter.includeFocus = true
        let rows = LogQuery.rows(in: fixture.store, filter: filter).filter { $0.focusEvent != nil }
        XCTAssertEqual(rows.map(\.marker), ["FOCUS", "NOTE", "REVIEW", "END"])
        let plain = LogRenderer.list(rows, ctx: context(fixture)).joined(separator: "\n")
        for marker in ["FOCUS", "NOTE", "REVIEW", "END"] { XCTAssertTrue(plain.contains(marker), plain) }
        XCTAssertFalse(plain.contains("INFO"))
        XCTAssertTrue(plain.contains("Understand throughput"))
        XCTAssertTrue(plain.contains("Check the evaluation method"))
        let colored = LogRenderer.list(rows, ctx: context(fixture, style: Style(enabled: true)))
        XCTAssertEqual(colored.map(TerminalText.stripEscapes).joined(separator: "\n"), plain)
        let markdown = LogRenderer.markdown(title: "Focus", rows: rows)
        XCTAssertTrue(markdown.contains("[FOCUS]"))
        XCTAssertTrue(markdown.contains("\n  Understand throughput\n  Check the evaluation method"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(LogRenderer.json(rows).utf8)) as? [[String: Any]])
        XCTAssertEqual(json.first?["focus_event"] as? String, "start")
        XCTAssertEqual(json.first?["focus_goal"] as? String, goal)
        filter.grep = "Understand throughput"
        XCTAssertEqual(LogQuery.rows(in: fixture.store, filter: filter).map(\.id), [start])
    }

    func testLegacyReflectionGetsTheSameMarkerInCLIAndNotebook() throws {
        let fixture = try Fixture.make(testCase: self)
        let log = try XCTUnwrap(fixture.store.quickLogEntry("阶段反馈 · Finished", on: fixture.day2).entry)
        let row = try XCTUnwrap(LogQuery.rows(in: fixture.store, filter: LogFilter()).first { $0.id == log.id })
        XCTAssertEqual(row.marker, log.focusMarker)
        XCTAssertEqual(row.marker, "REVIEW")
    }

    func testInlineImageProtocolDetectionAndEncoding() throws {
        XCTAssertEqual(ImageProtocol.detect(["TERM_PROGRAM": "Scheduler"]), .iterm2, "日页内置终端")
        XCTAssertEqual(ImageProtocol.detect(["TERM_PROGRAM": "iTerm.app"]), .iterm2)
        XCTAssertEqual(ImageProtocol.detect(["TERM_PROGRAM": "ghostty"]), .kitty)
        XCTAssertEqual(ImageProtocol.detect(["TERM": "xterm-kitty"]), .kitty)
        XCTAssertEqual(ImageProtocol.detect(["TERM_PROGRAM": "Apple_Terminal"]), .none, "系统自带终端不支持")
        XCTAssertEqual(ImageProtocol.detect(["TERM_PROGRAM": "Scheduler", "TMUX": "/tmp/tmux"]), .none, "tmux 里转义序列会被吞")
        XCTAssertEqual(ImageProtocol.detect(["TERM_PROGRAM": "Apple_Terminal", "SCHED_IMAGES": "kitty"]), .kitty, "可强制指定")
        XCTAssertEqual(InlineImage.columns(pixelWidth: 400, maxColumns: 72), 25)
        XCTAssertEqual(InlineImage.columns(pixelWidth: 4000, maxColumns: 60), 60, "大图缩到最多 60 列")
        XCTAssertEqual(InlineImage.columns(pixelWidth: 10, maxColumns: 60), 8, "小图不放大")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("img-\(UUID().uuidString).png")
        try pngData(width: 3000, height: 1500).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let prepared = try XCTUnwrap(InlineImage.prepare(file, maxPixel: 1100))
        XCTAssertEqual(prepared.pixelWidth, 1100, "长边缩到 1100 像素")
        XCTAssertEqual(prepared.pixelHeight, 550, "保持比例")
        let kitty = try XCTUnwrap(InlineImage.sequence(prepared, name: "a.png", columns: 40, protocol: .kitty))
        XCTAssertTrue(kitty.hasPrefix("\u{1B}_Ga=T,f=100,c=40,m="))
        XCTAssertTrue(kitty.hasSuffix("\u{1B}\\\n"))
        let chunks = kitty.components(separatedBy: "\u{1B}\\").filter { !$0.isEmpty && $0 != "\n" }
        XCTAssertTrue(chunks.dropLast().allSatisfy { $0.contains("m=1;") }, "除最后一块外都标记还有后续")
        XCTAssertTrue(chunks.last?.contains("m=0;") == true)
        XCTAssertNil(InlineImage.sequence(prepared, name: "a.png", columns: 40, protocol: .none))
        XCTAssertNil(InlineImage.prepare(file.deletingLastPathComponent().appendingPathComponent("no-such-file.png")))
    }
}
