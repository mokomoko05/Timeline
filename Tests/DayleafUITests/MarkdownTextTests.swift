import AppKit
import SwiftUI
import XCTest
@testable import Dayleaf

@MainActor
final class MarkdownTextTests: XCTestCase {
    private func render(_ source: String) -> NSAttributedString {
        MarkdownText.render(source, color: .labelColor, fontSize: 13)
    }

    private func attributes(_ word: String, in text: NSAttributedString) -> [NSAttributedString.Key: Any] {
        text.attributes(at: (text.string as NSString).range(of: word).location, effectiveRange: nil)
    }

    func testBlockAndInlineFormatting() {
        let text = render("""
        # 标题

        **加粗**、*斜体*、~~删除~~ 和 `代码`

        > 引用

        3. 第三项
        4. 第四项
           - 嵌套

        - [x] 完成
        - [ ] 待办
        """)
        XCTAssertFalse(text.string.contains("# 标题"))
        XCTAssertTrue(text.string.contains("3.\t第三项"))
        XCTAssertTrue(text.string.contains("☑\t完成"))
        XCTAssertTrue(text.string.contains("☐\t待办"))
        let heading = attributes("标题", in: text)[.font] as! NSFont
        XCTAssertGreaterThan(heading.pointSize, 13)
        XCTAssertTrue(NSFontManager.shared.traits(of: attributes("加粗", in: text)[.font] as! NSFont).contains(.boldFontMask))
        XCTAssertTrue(NSFontManager.shared.traits(of: attributes("斜体", in: text)[.font] as! NSFont).contains(.italicFontMask))
        XCTAssertEqual(attributes("删除", in: text)[.strikethroughStyle] as? Int, 1)
        XCTAssertNotNil(attributes("代码", in: text)[.backgroundColor])
        XCTAssertEqual((attributes("引用", in: text)[.paragraphStyle] as? NSParagraphStyle)?.headIndent, 16)
        XCTAssertGreaterThan((attributes("嵌套", in: text)[.paragraphStyle] as! NSParagraphStyle).headIndent, 22)
    }

    func testCodePreservesLiteralMarkdownAndDoesNotActivateURLs() {
        let text = render("```swift\n# literal **bold** | value\nhttps://example.com\n```\n\n`https://example.org`")
        XCTAssertTrue(text.string.contains("# literal **bold** | value"))
        XCTAssertNil(attributes("https://example.com", in: text)[.link])
        XCTAssertNil(attributes("https://example.org", in: text)[.link])
    }

    func testLinksAndRawHTML() {
        let text = render("[网站](https://example.com) [文件](file:///tmp/a.pdf) [危险](javascript:alert) https://example.org\n\n<script>alert(1)</script>")
        XCTAssertEqual(attributes("网站", in: text)[.link] as? URL, URL(string: "https://example.com"))
        XCTAssertEqual(attributes("文件", in: text)[.link] as? URL, URL(string: "file:///tmp/a.pdf"))
        XCTAssertNil(attributes("危险", in: text)[.link])
        XCTAssertNotNil(attributes("https://example.org", in: text)[.link])
        XCTAssertTrue(text.string.contains("<script>alert(1)</script>"))
    }

    func testNativeTableCellsAlignmentAndLinks() {
        let text = render("| 左 | 中 | 右 |\n| :--- | :---: | ---: |\n| **加粗** | [链接](https://example.com) | 42 |\n| 空 | | 尾 |")
        XCTAssertFalse(text.string.contains("---"))
        let left = attributes("左", in: text)[.paragraphStyle] as! NSParagraphStyle
        let center = attributes("中", in: text)[.paragraphStyle] as! NSParagraphStyle
        let right = attributes("42", in: text)[.paragraphStyle] as! NSParagraphStyle
        let first = left.textBlocks.first as! NSTextTableBlock
        let last = right.textBlocks.first as! NSTextTableBlock
        XCTAssertEqual(first.table.numberOfColumns, 3)
        XCTAssertTrue(first.table === last.table)
        XCTAssertEqual(last.startingRow, 1)
        XCTAssertEqual(last.startingColumn, 2)
        XCTAssertEqual(center.alignment, .center)
        XCTAssertEqual(right.alignment, .right)
        XCTAssertNotNil(attributes("链接", in: text)[.link])
    }

    func testTableReflowsAndMeasuredHeightContainsLastLine() throws {
        let text = render("| 项目 | 说明 |\n| --- | --- |\n| 第一项 | 很长的中文内容需要随着窗口宽度自动换行，保持每一列的文字都能完整显示。 |\n| 第二项 | [链接](https://example.com) |\n\n最后一行")
        let measurer = TextMeasurer()
        measurer.update(text, maxLines: 0)
        let wide = measurer.height(forWidth: 600)
        let narrow = measurer.height(forWidth: 230)
        XCTAssertGreaterThan(narrow, wide)
        XCTAssertEqual(measurer.height(forWidth: 600), wide)
        let view = InteractiveTaskText(frame: NSRect(x: 0, y: 0, width: 230, height: narrow + 8))
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: 230, height: CGFloat.greatestFiniteMagnitude)
        view.textStorage?.setAttributedString(text)
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        let last = (text.string as NSString).range(of: "最后一行")
        let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: last, actualCharacterRange: nil), in: container)
        XCTAssertLessThanOrEqual(rect.maxY, narrow + 1)
        XCTAssertEqual(view.linkRegions().first?.url, URL(string: "https://example.com"))
    }
}
