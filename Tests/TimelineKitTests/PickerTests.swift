import XCTest
import TimelineCore
@testable import TimelineKit

@MainActor
final class PickerTests: XCTestCase {
    func testKeyDecoderHandlesArrowsPagesControlKeysAndUtf8() {
        let esc: UInt8 = 0x1B
        XCTAssertEqual(KeyDecoder.decode([esc, 0x5B, 0x41]).keys, [.up])
        XCTAssertEqual(KeyDecoder.decode([esc, 0x4F, 0x42]).keys, [.down], "应用光标模式的 ESC O B")
        XCTAssertEqual(KeyDecoder.decode([esc, 0x5B, 0x35, 0x7E]).keys, [.pageUp])
        XCTAssertEqual(KeyDecoder.decode([esc, 0x5B, 0x36, 0x7E]).keys, [.pageDown])
        XCTAssertEqual(KeyDecoder.decode([0x0D]).keys, [.enter])
        XCTAssertEqual(KeyDecoder.decode([0x7F]).keys, [.backspace])
        XCTAssertEqual(KeyDecoder.decode([0x03]).keys, [.ctrl("c")])
        XCTAssertEqual(KeyDecoder.decode([esc]).keys, [.escape])
        XCTAssertEqual(KeyDecoder.decode(Array("j/".utf8)).keys, [.char("j"), .char("/")])
        XCTAssertEqual(KeyDecoder.decode(Array("公".utf8)).keys, [.char("公")], "中文输入")
        let partial = KeyDecoder.decode([0x41, esc, 0x5B])
        XCTAssertEqual(partial.keys, [.char("A")])
        XCTAssertEqual(partial.rest, [esc, 0x5B], "不完整的转义序列留到下一批")
        let partialUTF8 = KeyDecoder.decode([0xE5, 0x85])
        XCTAssertEqual(partialUTF8.keys, [])
        XCTAssertEqual(partialUTF8.rest, [0xE5, 0x85])
    }

    private func rows(_ fixture: Fixture) -> [LogRow] { LogQuery.rows(in: fixture.snapshot(), filter: LogFilter()) }

    func testNavigationSearchAndQuit() throws {
        let fixture = try Fixture.make(testCase: self)
        var state = PickerState(rows: rows(fixture))
        XCTAssertEqual(state.visible.count, 5)
        XCTAssertEqual(state.cursor, 4, "默认停在最新一条")
        XCTAssertEqual(state.handle(.up, height: 20), .none)
        XCTAssertEqual(state.cursor, 3)
        _ = state.handle(.char("g"), height: 20)
        XCTAssertEqual(state.cursor, 0)
        _ = state.handle(.char("k"), height: 20)
        XCTAssertEqual(state.cursor, 0, "不会越界")
        _ = state.handle(.char("G"), height: 20)
        XCTAssertEqual(state.cursor, 4)
        _ = state.handle(.char("/"), height: 20)
        XCTAssertEqual(state.mode, .search)
        for ch in "公式" { _ = state.handle(.char(ch), height: 20) }
        XCTAssertEqual(state.visible.map(\.text), ["读完摘要，公式 3 看不懂"], "输入即筛选")
        _ = state.handle(.backspace, height: 20)
        XCTAssertEqual(state.query, "公")
        _ = state.handle(.enter, height: 20)
        XCTAssertEqual(state.mode, .list)
        XCTAssertEqual(state.query, "公", "回车确认后保留筛选")
        XCTAssertEqual(state.handle(.escape, height: 20), .none, "有筛选时 Esc 先清筛选")
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.handle(.char("q"), height: 20), .quit)
        XCTAssertEqual(state.handle(.ctrl("c"), height: 20), .quit)
    }

    func testSearchMatchesImageOcrTaskNumberAndShortId() throws {
        let fixture = try Fixture.make(testCase: self)
        var state = PickerState(rows: rows(fixture))
        _ = state.handle(.char("/"), height: 20)
        for ch in "latency" { _ = state.handle(.char(ch), height: 20) }
        XCTAssertEqual(state.visible.count, 1, "搜到截图里的文字")
        _ = state.handle(.ctrl("u"), height: 20)
        for ch in "#2" { _ = state.handle(.char(ch), height: 20) }
        XCTAssertEqual(state.visible.map(\.text), ["周报发出去了"], "按任务编号")
        let target = try XCTUnwrap(rows(fixture).first)
        _ = state.handle(.ctrl("u"), height: 20)
        for ch in target.shortID { _ = state.handle(.char(ch), height: 20) }
        XCTAssertEqual(state.visible.map(\.id), [target.id], "按短标识")
        _ = state.handle(.ctrl("u"), height: 20)
        for ch in "不存在的词" { _ = state.handle(.char(ch), height: 20) }
        XCTAssertTrue(state.visible.isEmpty)
        XCTAssertNil(state.current)
        XCTAssertEqual(state.handle(.enter, height: 20), .none)
        XCTAssertTrue(state.render(width: 60, height: 10, style: .plain).joined().contains("没有匹配「不存在的词」"))
    }

    func testDetailScrollsNavigatesAndOffersCopyImagesAndSelect() throws {
        let fixture = try Fixture.make(testCase: self)
        let all = rows(fixture)
        var state = PickerState(rows: all)
        let ctx = RenderContext(width: 60, imagesDirectory: fixture.directory.appendingPathComponent("Images"))
        let provider: (LogRow) -> [String] = { LogRenderer.detail($0, ctx: ctx) + Array(repeating: "更多内容", count: 30) }
        _ = state.handle(.enter, height: 12, detailProvider: provider)
        XCTAssertEqual(state.mode, .detail)
        XCTAssertEqual(state.current?.id, all.last?.id)
        _ = state.handle(.down, height: 12, detailProvider: provider)
        XCTAssertEqual(state.detailScroll, 1)
        _ = state.handle(.char("G"), height: 12, detailProvider: provider)
        XCTAssertGreaterThan(state.detailScroll, 10)
        _ = state.handle(.char("N"), height: 12, detailProvider: provider)
        XCTAssertEqual(state.current?.id, all[all.count - 2].id, "N 看上一条")
        XCTAssertEqual(state.detailScroll, 0, "换一条后回到顶部")
        XCTAssertEqual(state.handle(.char("y"), height: 12, detailProvider: provider), .copy(all[all.count - 2].text))
        let withImage = try XCTUnwrap(all.first { !$0.images.isEmpty })
        XCTAssertEqual(state.current?.id, withImage.id)
        XCTAssertEqual(state.handle(.char("i"), height: 12, detailProvider: provider), .showImages(withImage), "带图片的一条可以查看图片")
        _ = state.handle(.char("N"), height: 12, detailProvider: provider)
        XCTAssertEqual(state.handle(.char("i"), height: 12, detailProvider: provider), .none, "这条没有图片")
        XCTAssertEqual(state.notice, "这条日志没有图片")
        _ = state.handle(.char("n"), height: 12, detailProvider: provider)
        _ = state.handle(.char("g"), height: 12, detailProvider: provider)
        _ = state.handle(.left, height: 12, detailProvider: provider)
        XCTAssertEqual(state.mode, .list)
        while state.current?.id != withImage.id { _ = state.handle(.char("k"), height: 12) }
        _ = state.handle(.enter, height: 12, detailProvider: provider)
        XCTAssertEqual(state.handle(.char("i"), height: 12, detailProvider: provider), .showImages(withImage))
        XCTAssertEqual(state.handle(.char("p"), height: 12, detailProvider: provider), .select(withImage))
    }

    func testSelectOnEnterReturnsTheRowForPrintMode() throws {
        let fixture = try Fixture.make(testCase: self)
        var state = PickerState(rows: rows(fixture), selectOnEnter: true)
        let expected = try XCTUnwrap(state.current)
        XCTAssertEqual(state.handle(.enter, height: 20), .select(expected))
    }

    func testRenderFillsExactlyTheScreenAndNeverExceedsTheWidth() throws {
        let fixture = try Fixture.make(testCase: self)
        _ = try fixture.store.quickLog(String(repeating: "很长的一条日志内容", count: 20), taskID: fixture.paper.id, on: fixture.day2)
        var state = PickerState(rows: LogQuery.rows(in: fixture.store, filter: LogFilter()))
        for (width, height) in [(40, 8), (60, 12), (100, 30)] {
            var frame = state.render(width: width, height: height, style: .plain)
            XCTAssertEqual(frame.count, height)
            XCTAssertTrue(frame.allSatisfy { TerminalText.width($0) <= width }, "\(width)x\(height)：\(frame.first { TerminalText.width($0) > width } ?? "")")
            frame = state.render(width: width, height: height, style: Style(enabled: true))
            XCTAssertEqual(frame.count, height)
            XCTAssertTrue(frame.allSatisfy { TerminalText.width($0) <= width })
            _ = state.handle(.enter, height: height, detailProvider: { LogRenderer.detail($0, ctx: RenderContext(width: width, imagesDirectory: fixture.directory)) })
            let detail = state.render(width: width, height: height, style: .plain, detailLines: LogRenderer.detail(state.current!, ctx: RenderContext(width: width, imagesDirectory: fixture.directory)))
            XCTAssertEqual(detail.count, height)
            XCTAssertTrue(detail.allSatisfy { TerminalText.width($0) <= width })
            _ = state.handle(.escape, height: height)
        }
    }

    func testListScrollKeepsTheCursorVisible() throws {
        let fixture = try Fixture.make(testCase: self)
        for index in 0..<40 { _ = try fixture.store.quickLog("批量日志 \(index)", on: fixture.day2, now: fixture.day2.addingTimeInterval(Double(index) * 60 + 80_000)) }
        var state = PickerState(rows: LogQuery.rows(in: fixture.store, filter: LogFilter()))
        _ = state.handle(.char("g"), height: 10)
        XCTAssertEqual(state.top, 0)
        for _ in 0..<30 { _ = state.handle(.down, height: 10) }
        let frame = state.render(width: 70, height: 10, style: .plain).joined(separator: "\n")
        XCTAssertGreaterThan(state.top, 0)
        XCTAssertTrue(state.cursor >= state.top && state.cursor < state.top + 7, "光标始终在可见的 7 行里")
        XCTAssertTrue(frame.contains("31/45"), "头部显示位置：\(frame.split(separator: "\n").first ?? "")")
        _ = state.handle(.pageDown, height: 10)
        _ = state.handle(.end, height: 10)
        XCTAssertEqual(state.cursor, 44)
    }
}
