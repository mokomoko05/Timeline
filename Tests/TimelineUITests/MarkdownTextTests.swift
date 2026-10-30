import AppKit
import SwiftUI
import XCTest
@testable import Timeline

@MainActor
final class MarkdownTextTests: XCTestCase {
    private func render(_ source: String) -> NSAttributedString {
        MarkdownText.render(source, color: .labelColor, fontSize: 13)
    }

    private func attributes(_ word: String, in text: NSAttributedString) -> [NSAttributedString.Key: Any] {
        text.attributes(at: (text.string as NSString).range(of: word).location, effectiveRange: nil)
    }

    /// 引用是灰底框：连着的 > 行是一块；隔着空行的两段引用是两块，空行留着、不在框里。
    func testQuotesSeparatedByABlankLineAreTwoBlocks() {
        let text = render("> 第一段\n> 接着\n\n> 第二段\n\n正文")
        func blocks(_ word: String) -> [NSTextBlock] { (attributes(word, in: text)[.paragraphStyle] as? NSParagraphStyle)?.textBlocks ?? [] }
        let first = blocks("第一段"), second = blocks("第二段")
        XCTAssertEqual(first.count, 1)
        XCTAssertNotNil(first.first?.backgroundColor)
        XCTAssertEqual(second.count, 1)
        XCTAssertFalse(first.first === second.first, "隔着空行的引用是两块")
        XCTAssertTrue(blocks("接着").first === first.first)
        XCTAssertTrue(blocks("正文").isEmpty)
        XCTAssertTrue(text.string.contains("接着\n\n第二段"), "两块之间的空行留着")
        let blank = (text.string as NSString).range(of: "接着\n\n").location + 3
        XCTAssertTrue(((text.attribute(.paragraphStyle, at: blank, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks ?? []).isEmpty, "空行没有灰底")
        let separate = render("> 甲\n\n正文\n\n> 乙")
        XCTAssertFalse((separate.attributes(at: (separate.string as NSString).range(of: "甲").location, effectiveRange: nil)[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first
                       === (separate.attributes(at: (separate.string as NSString).range(of: "乙").location, effectiveRange: nil)[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first)
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
        // 待办项和工作板、就地编辑器一样画成圆圈（附件），不能点的正文里不带行号。
        XCTAssertTrue(text.string.contains("\u{FFFC}\t完成"))
        XCTAssertTrue(text.string.contains("\u{FFFC}\t待办"))
        XCTAssertNil(attributes("\u{FFFC}", in: text)[MarkdownText.taskLineKey])
        let heading = attributes("标题", in: text)[.font] as! NSFont
        XCTAssertGreaterThan(heading.pointSize, 13)
        XCTAssertTrue(NSFontManager.shared.traits(of: attributes("加粗", in: text)[.font] as! NSFont).contains(.boldFontMask))
        XCTAssertTrue(NSFontManager.shared.traits(of: attributes("斜体", in: text)[.font] as! NSFont).contains(.italicFontMask))
        XCTAssertEqual(attributes("删除", in: text)[.strikethroughStyle] as? Int, 1)
        XCTAssertNotNil(attributes("代码", in: text)[.backgroundColor])
        XCTAssertEqual((attributes("引用", in: text)[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.count, 1, "引用画在灰底框里")
        XCTAssertGreaterThan((attributes("嵌套", in: text)[.paragraphStyle] as! NSParagraphStyle).headIndent, 22)
    }

    func testCodePreservesLiteralMarkdownAndDoesNotActivateURLs() {
        let text = render("```swift\n# literal **bold** | value\nhttps://example.com\n```\n\n`https://example.org`")
        XCTAssertTrue(text.string.contains("# literal **bold** | value"))
        XCTAssertNil(attributes("https://example.com", in: text)[.link])
        XCTAssertNil(attributes("https://example.org", in: text)[.link])
    }

    func testHeadingLevelsHaveDistinctColorsAndBlankLinesArePreserved() {
        let source = (1...6).map { String(repeating: "#", count: $0) + " Heading\($0)" }.joined(separator: "\n\n")
        let rendered = render(source)
        let colors = (1...6).compactMap { attributes("Heading\($0)", in: rendered)[.foregroundColor] as? NSColor }
        XCTAssertEqual(Set(colors).count, 6)
        XCTAssertTrue(render("First\n\n\n\nSecond").string.contains("First\n\n\n\nSecond"))
        let tasks = MarkdownText.render("- [x] Done\n- [ ] Pending", color: .labelColor, fontSize: 13, interactiveTasks: true)
        XCTAssertEqual(attributes("Done", in: tasks)[.strikethroughStyle] as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertNil(attributes("Pending", in: tasks)[.strikethroughStyle])
    }

    func testInteractiveTaskCirclesKeepSourceLinesAndIgnoreCode() {
        let source = "# 中文标题\n\n- [ ] 同名\n  - [X] 嵌套\n\n- [ ] 第二项\n\n~~~\n- [ ] code\n~~~"
        let text = MarkdownText.render(source, color: .labelColor, fontSize: 13, interactiveTasks: true)
        var lines: [Int] = []
        text.enumerateAttribute(MarkdownText.taskLineKey, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let line = value as? Int else { return }
            lines.append(line)
            XCTAssertNotNil(text.attribute(.attachment, at: range.location, effectiveRange: nil))
            XCTAssertNil(text.attribute(.link, at: range.location, effectiveRange: nil))
        }
        XCTAssertEqual(lines, [3, 4, 6])
        XCTAssertTrue(text.string.contains("- [ ] code"))
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

    /// 中日韩字体没有斜体：`*重点*` 要真的倾斜；拉丁字母用字体自己的斜体，不再叠一层。
    func testEmphasisSlantsCJKOnlyAndIsVisible() {
        func render(_ source: String) -> NSAttributedString { MarkdownText.render(source, color: .black, fontSize: 13, lineSpacing: 2, scale: 1) }
        func pixels(_ text: NSAttributedString) -> Data {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            text.draw(at: NSPoint(x: 2, y: 2))
            NSGraphicsContext.restoreGraphicsState()
            return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * 40)
        }
        XCTAssertNotEqual(pixels(render("重要内容")), pixels(render("*重要内容*")), "中文看得出强调")
        let mixed = render("*重要 important*")
        XCTAssertNotNil(mixed.attribute(.obliqueness, at: 0, effectiveRange: nil))
        let latin = (mixed.string as NSString).range(of: "important").location
        XCTAssertNil(mixed.attribute(.obliqueness, at: latin, effectiveRange: nil), "拉丁字母不重复倾斜")
        XCTAssertNil(render("重要内容").attribute(.obliqueness, at: 0, effectiveRange: nil), "没有强调的不倾斜")
    }

    /// 正文里的 `<details>`：不显示 HTML 标签，收起时只有标题，展开有内容；没有折叠记忆的地方内容都显示。
    func testDetailsRenderAsDisclosure() {
        let source = "开头\n\n<details>\n<summary>更多</summary>\n\n里面的**内容**\n\n</details>\n\n结尾"
        func render(_ folds: Set<String>?) -> NSAttributedString {
            MarkdownText.render(source, color: .labelColor, fontSize: 13, lineSpacing: 2, scale: 1, folds: folds)
        }
        let closed = render([]).string
        XCTAssertFalse(closed.contains("<"), closed)
        XCTAssertTrue(closed.contains("更多") && closed.contains("结尾"), closed)
        XCTAssertFalse(closed.contains("里面的"), closed)
        let opened = render(["d:更多#0=open"])
        XCTAssertTrue(opened.string.contains("里面的内容"), opened.string)
        XCTAssertFalse(opened.string.contains("</details>"), opened.string)
        var key: String?
        opened.enumerateAttribute(MarkdownText.headingFoldKey, in: NSRange(location: 0, length: opened.length)) { value, _, _ in if let value = value as? String { key = value } }
        XCTAssertEqual(key, "d:更多#0=closed", "点下去要变成收起")
        XCTAssertTrue(render(nil).string.contains("里面的内容"), "不能折叠的地方内容都显示")

        let initiallyOpen = "<details open>\n<summary>默认展开</summary>\n\n内容\n\n</details>"
        XCTAssertTrue(MarkdownText.render(initiallyOpen, color: .labelColor, fontSize: 13, lineSpacing: 2, scale: 1, folds: []).string.contains("内容"))
        XCTAssertFalse(MarkdownText.render(initiallyOpen, color: .labelColor, fontSize: 13, lineSpacing: 2, scale: 1, folds: ["d:默认展开#0=closed"]).string.contains("内容"))

        // 代码块里的标签、别的 HTML 照旧。
        let code = "```\n<details>\n</details>\n```"
        XCTAssertTrue(MarkdownText.render(code, color: .labelColor, fontSize: 13, lineSpacing: 2, scale: 1, folds: []).string.contains("<details>"))
        XCTAssertTrue(MarkdownText.render("<div>原样</div>", color: .labelColor, fontSize: 13, lineSpacing: 2, scale: 1, folds: []).string.contains("<div>"))
    }

    /// 折叠记忆：`<details open>` 收起后记得住，点一下切到另一个状态；给编辑器的形式也对。
    @MainActor
    func testDisclosureFoldMemory() {
        let defaults = InMemoryDefaults()
        let previous = HeadingFolds.defaults
        HeadingFolds.defaults = defaults
        defer { HeadingFolds.defaults = previous }
        HeadingFolds.toggle("d:甲#0=closed", in: "x")
        XCTAssertEqual(HeadingFolds.folded(in: "x"), ["d:甲#0=closed"])
        XCTAssertEqual(HeadingFolds.editorFolds(in: "x"), ["d:甲#0": false])
        HeadingFolds.toggle("d:甲#0=open", in: "x")
        XCTAssertEqual(HeadingFolds.editorFolds(in: "x"), ["d:甲#0": true])
        HeadingFolds.set("d:甲#0", folded: false, in: "x")
        XCTAssertEqual(HeadingFolds.editorFolds(in: "x"), ["d:甲#0": false])
        HeadingFolds.set("h1:标题#0", folded: true, in: "x")
        XCTAssertEqual(HeadingFolds.editorFolds(in: "x"), ["d:甲#0": false, "h1:标题#0": true])
    }
}
