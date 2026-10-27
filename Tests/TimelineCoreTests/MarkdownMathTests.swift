import XCTest
@testable import TimelineCore

final class MarkdownMathTests: XCTestCase {
    private func formulas(_ source: String) -> [MarkdownMath.Formula] { MarkdownMath.extract(source).formulas }

    func testInlineAndDisplayFormulas() {
        let source = "质能 $E=mc^2$ 和\n$$\n\\frac{a}{b} \\\\ x_1 * y_2\n$$\n后文"
        let extracted = MarkdownMath.extract(source)
        XCTAssertEqual(extracted.formulas, [
            .init(latex: "E=mc^2", display: false),
            .init(latex: "\\frac{a}{b} \\\\ x_1 * y_2", display: true),
        ])
        // 行数不变，LaTeX 的反斜杠、星号不会留给 Markdown 解析器。
        XCTAssertEqual(extracted.source.components(separatedBy: "\n").count, source.components(separatedBy: "\n").count)
        XCTAssertFalse(extracted.source.contains("\\frac"))
        XCTAssertFalse(extracted.source.contains("*"))
        XCTAssertTrue(extracted.source.hasSuffix("\n后文"))
    }

    func testBracketDelimitersAndSingleLineDisplay() {
        XCTAssertEqual(formulas("a \\(x+1\\) b \\[\\sum_i i\\] $$y$$"), [
            .init(latex: "x+1", display: false),
            .init(latex: "\\sum_i i", display: true),
            .init(latex: "y", display: true),
        ])
    }

    func testDollarAmountsAndEscapesStayText() {
        XCTAssertEqual(formulas("价格 $5 到 $10"), [])
        XCTAssertEqual(formulas("花了 $ 20 和 $30"), [])
        XCTAssertEqual(formulas("转义 \\$x\\$ 不是公式"), [])
        XCTAssertEqual(formulas("没有结束 $x"), [])
        XCTAssertEqual(formulas("$x $"), [])
    }

    func testCodeIsLeftAlone() {
        let source = "`$x$` 行内代码\n```\n$$\ny\n$$\n```\n然后 $z$"
        let extracted = MarkdownMath.extract(source)
        XCTAssertEqual(extracted.formulas, [.init(latex: "z", display: false)])
        XCTAssertTrue(extracted.source.contains("`$x$`"))
        XCTAssertTrue(extracted.source.contains("```\n$$\ny\n$$\n```"))
    }

    func testPiecesAndContinuation() {
        let source = "- 列表\n  $$\n  a+b\n  $$\n- 下一项"
        let extracted = MarkdownMath.extract(source)
        XCTAssertEqual(extracted.formulas, [.init(latex: "a+b", display: true)])
        let lines = extracted.source.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 5)
        // 列表里的公式：后面几行保留缩进，仍然属于这一项。
        XCTAssertTrue(lines[2].hasPrefix("  "))
        XCTAssertEqual(lines[4], "- 下一项")
        let pieces = MarkdownMath.pieces(lines[1] + lines[2], formulas: extracted.formulas)
        XCTAssertEqual(pieces, [.text("  "), .formula(.init(latex: "a+b", display: true)), .text("  ")])
        XCTAssertEqual(MarkdownMath.restore(lines[1].trimmingCharacters(in: .whitespaces), formulas: extracted.formulas), "$$a+b$$")
    }

    func testQuotedDisplayDropsQuoteMarkers() {
        XCTAssertEqual(formulas("> $$\n> x^2\n> $$"), [.init(latex: "x^2", display: true)])
    }

    func testPlainTextUntouched() {
        let source = "没有公式的正文 **加粗**"
        XCTAssertEqual(MarkdownMath.extract(source).source, source)
        XCTAssertEqual(MarkdownMath.pieces(source, formulas: []), [.text(source)])
    }
}
