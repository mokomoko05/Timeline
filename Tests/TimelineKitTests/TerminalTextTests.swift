import XCTest
@testable import TimelineKit

final class TerminalTextTests: XCTestCase {
    func testWidthCountsChineseAndEmojiAsTwoCellsAndIgnoresEscapes() {
        XCTAssertEqual(TerminalText.width("abc"), 3)
        XCTAssertEqual(TerminalText.width("读论文"), 6)
        XCTAssertEqual(TerminalText.width("a读b"), 4)
        XCTAssertEqual(TerminalText.width("🖼"), 2)
        XCTAssertEqual(TerminalText.width("e\u{0301}"), 1, "组合重音不占格")
        XCTAssertEqual(TerminalText.width("\u{1B}[31m红\u{1B}[0m"), 2, "颜色序列不占宽度")
        XCTAssertEqual(TerminalText.width("\u{1B}]8;;https://a.com\u{07}链接\u{1B}]8;;\u{07}"), 4, "超链接序列不占宽度")
        XCTAssertEqual(TerminalText.stripEscapes("\u{1B}[1m粗\u{1B}[0m体"), "粗体")
    }

    func testTruncateNeverSplitsAWideCharacterAndKeepsWithinLimit() {
        XCTAssertEqual(TerminalText.truncate("hello", to: 10), "hello")
        let cut = TerminalText.truncate("读论文看公式", to: 7)
        XCTAssertLessThanOrEqual(TerminalText.width(cut), 7)
        XCTAssertEqual(cut, "读论文…", "7 格放不下第 4 个字（需要 6+2），所以停在 3 个字加省略号")
        XCTAssertEqual(TerminalText.truncate("abcdef", to: 4), "abc…")
        XCTAssertEqual(TerminalText.truncate("abc", to: 0), "")
        let colored = TerminalText.truncate("\u{1B}[31m红色很长很长的文字\u{1B}[0m", to: 6)
        XCTAssertLessThanOrEqual(TerminalText.width(colored), 6)
        XCTAssertTrue(colored.contains("\u{1B}[0m"), "截断后补上重置，颜色不会漏到后面")
    }

    func testPadAndWrapRespectDisplayWidth() {
        XCTAssertEqual(TerminalText.width(TerminalText.pad("读", to: 6)), 6)
        let lines = TerminalText.wrap("这是一段比较长的中文日志，需要按显示宽度自动换行而不是按字符数", width: 20)
        XCTAssertGreaterThan(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { TerminalText.width($0) <= 20 })
        XCTAssertEqual(lines.joined(), "这是一段比较长的中文日志，需要按显示宽度自动换行而不是按字符数", "不丢字")
        let words = TerminalText.wrap("the quick brown fox jumps over the lazy dog", width: 16)
        XCTAssertEqual(words, ["the quick brown", "fox jumps over", "the lazy dog"], "优先在空格处断开，折行后不以空格开头")
        XCTAssertEqual(TerminalText.wrap("第一行\n第二行", width: 30), ["第一行", "第二行"], "保留原有换行")
        XCTAssertEqual(TerminalText.wrap("", width: 10), [""])
    }

    func testStyleIsAPassThroughWhenDisabledAndLinksUseOSC8() {
        let plain = Style.plain
        XCTAssertEqual(plain.red("x"), "x")
        XCTAssertEqual(plain.link("文字", url: "https://a.com"), "文字")
        let color = Style(enabled: true)
        XCTAssertEqual(color.red("x"), "\u{1B}[31mx\u{1B}[0m")
        XCTAssertEqual(color.link("文字", url: "https://a.com"), "\u{1B}]8;;https://a.com\u{07}文字\u{1B}]8;;\u{07}")
        XCTAssertEqual(TerminalText.width(color.bold(color.link("文字", url: "https://a.com"))), 4)
    }
}
