import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class MarkdownMathRenderTests: XCTestCase {
    private func render(_ source: String) -> NSAttributedString {
        MarkdownText.render(source, color: .labelColor, fontSize: 13)
    }

    private func attachments(_ text: NSAttributedString) -> [(NSTextAttachment, NSRange)] {
        var result: [(NSTextAttachment, NSRange)] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let attachment = value as? NSTextAttachment { result.append((attachment, range)) }
        }
        return result
    }

    func testFormulasBecomeAttachmentsAndDisplayIsCentered() {
        let text = render("勾股 $a^2+b^2=c^2$ 定理\n\n$$\n\\int_0^1 x\\,dx = \\frac{1}{2}\n$$\n\n后文 **加粗**")
        let found = attachments(text)
        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(text.string.hasPrefix("勾股 \u{FFFC} 定理"))
        XCTAssertFalse(text.string.contains("$"))
        XCTAssertFalse(text.string.contains("\u{E003}"))
        let display = found[1]
        XCTAssertNotNil(text.attribute(MathAttachment.displayKey, at: display.1.location, effectiveRange: nil))
        let style = text.attribute(.paragraphStyle, at: display.1.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.alignment, .center)
        let inlineStyle = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertNotEqual(inlineStyle?.alignment, .center)
        // 行内公式的附件高度和正文相当，下沿在基线下面。
        XCTAssertLessThan(found[0].0.bounds.height, 30)
        XCTAssertLessThan(found[0].0.bounds.minY, 0)
        XCTAssertGreaterThan(display.0.bounds.height, found[0].0.bounds.height)
        XCTAssertTrue(text.string.contains("后文 加粗"))
        // 遮罩里真的有字形（画进不支持的画布时会是一片空白）。
        let mask = MathAttachment.rendered(.init(latex: "x^2", display: false), fontSize: 13)?.mask
        let coverage = (mask?.dataProvider?.data as Data?)?.reduce(0) { $0 + Int($1) } ?? 0
        XCTAssertGreaterThan(coverage, 0)
    }

    func testMultilineDisplayInsideAParagraphKeepsSurroundingLines() {
        let text = render("前一行\n$$\nx = 1 \\\\\ny = 2\n$$\n后一行")
        XCTAssertEqual(attachments(text).count, 1)
        XCTAssertEqual(text.string, "前一行\n\u{FFFC}\n后一行\n")
    }

    func testInvalidFormulaFallsBackToSource() {
        let text = render("坏的 $\\frac{a$ 公式")
        XCTAssertTrue(attachments(text).isEmpty)
        XCTAssertTrue(text.string.contains("$\\frac{a$"))
    }

    func testTaskLinesAndCodeAreUnaffected() {
        let source = "$$\na\nb\n$$\n- [ ] 任务 $x$\n\n```\n$y$\n```"
        let text = MarkdownText.render(source, color: .labelColor, fontSize: 13, interactiveTasks: true)
        var line: Int?
        text.enumerateAttribute(MarkdownText.taskLineKey, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let value = value as? Int { line = value }
        }
        XCTAssertEqual(line, 5, "公式跨行后任务的行号不变")
        XCTAssertTrue(text.string.contains("$y$"), "代码块里的 $ 原样显示")
        XCTAssertEqual(attachments(text).count, 3)
    }

    /// 渲染开销：一篇带 40 个公式的笔记第一次排和缓存后再排各要多久。
    func testRenderCost() {
        var parts: [String] = []
        for index in 0..<20 {
            parts.append("第 \(index) 段：设 $x_\(index) = \\alpha^{\(index)} + \\beta$，则")
            parts.append("$$\n\\sum_{k=1}^{\(index + 2)} \\frac{x_k^2}{\\sqrt{k+\(index)}} = \\int_0^{\\infty} e^{-t^{\(index % 3 + 1)}}\\,dt\n$$")
        }
        let source = parts.joined(separator: "\n\n")
        let plain = source.replacingOccurrences(of: "$", with: "")
        func time(_ block: () -> Void) -> Double {
            let start = CFAbsoluteTimeGetCurrent()
            block()
            return (CFAbsoluteTimeGetCurrent() - start) * 1000
        }
        _ = render("预热 $x$")
        let baseline = time { _ = render(plain) }
        let cold = time { _ = render(source) }
        let warm = time { _ = render(source) }
        func drawCost(_ text: NSAttributedString) -> (layout: Double, first: Double, again: Double) {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude))
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let layout = time { manager.ensureLayout(for: container) }
        let image = NSImage(size: manager.usedRect(for: container).size)
        let draw = time {
            image.lockFocus()
            manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: .zero)
            image.unlockFocus()
        }
        let redraw = time {
            image.lockFocus()
            manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: .zero)
            image.unlockFocus()
        }
        return (layout, draw, redraw)
        }
        let text = render(source)
        let plainCost = drawCost(render(plain)), mathCost = drawCost(text)
        print(String(format: "[math] 40 个公式：解析拼字 无公式同文 %.1f ms，首次 %.1f ms，缓存后 %.1f ms", baseline, cold, warm))
        print(String(format: "[math] 排版 %.1f / %.1f ms，首次绘制 %.1f / %.1f ms，再次绘制 %.1f / %.1f ms（无公式 / 有公式）",
                     plainCost.layout, mathCost.layout, plainCost.first, mathCost.first, plainCost.again, mathCost.again))
        XCTAssertEqual(attachments(text).count, 40)
        XCTAssertLessThan(warm, baseline + 20, "缓存后公式几乎不增加开销")
    }

    /// 离屏看效果：`TIMELINE_DESIGN_PREVIEW=/输出目录 swift test --filter MarkdownMathRenderTests`。
    func testRenderPreview() throws {
        guard let path = ProcessInfo.processInfo.environment["TIMELINE_DESIGN_PREVIEW"], !path.isEmpty else {
            throw XCTSkip("设置 TIMELINE_DESIGN_PREVIEW 时才渲染")
        }
        let source = """
        ## 公式 $\\LaTeX$

        二次方程 $ax^2+bx+c=0$ 的根是 $x=\\frac{-b\\pm\\sqrt{b^2-4ac}}{2a}$，判别式 $\\Delta$ 决定根的个数。

        $$
        f(x) = \\int_{-\\infty}^{\\infty} \\hat f(\\xi)\\, e^{2\\pi i \\xi x}\\, d\\xi
        $$

        - 欧拉恒等式 $e^{i\\pi}+1=0$
        - 矩阵 $\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}$
        - 价格 $5 到 $10 不是公式

        > 引用里的公式：
        > $$\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}$$

        坏的公式 $\\frac{a$ 显示原文。
        """
        for (name, text) in [("math", source)] {
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 560))
            view.appearance = appearance
            view.textContainerInset = NSSize(width: 16, height: 16)
            view.backgroundColor = dark ? NSColor(white: 0.12, alpha: 1) : .white
            view.textStorage?.setAttributedString(MarkdownText.render(text, color: .labelColor, fontSize: 13))
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: path).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
        }
    }
}
