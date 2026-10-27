import AppKit
import SwiftUI
import XCTest
import TimelineCore
import TimelineMath
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

    /// AI 回答里常见、但 SwiftMath 原本不认识的写法：换成等价写法后都能排出来（一个不认识的命令会让整个公式退回原文）。
    func testCommonAIAnswerLatexRenders() {
        let formulas = [
            // 一篇 DeepSeek 解释 MTP 的回答里的原样公式。
            #"\tilde{e} = \text{RMSNorm}_{\text{enorm}}\big(E(t_{i+1})\big), \qquad \tilde{h} = \text{RMSNorm}_{\text{hnorm}}\big(h_i^{(0)}\big)"#,
            #"u = \text{eh\_proj}\Big( \operatorname{concat}(\tilde{e}, \tilde{h}) \Big)"#,
            #"z = \text{RMSNorm}_{\text{mtp\_norm}}\big(h_i^{(1)}\big), \qquad \text{logits}_{i+2} = \text{lm\_head}(z)"#,
            #"\operatorname{Attention}(Q,K,V)=\operatorname{softmax}\left(\frac{QK^\top}{\sqrt{d_k}}\right)V"#,
            #"\theta^* = \operatorname*{arg\,max}_{\theta} \sum_i \log p_\theta(x_i)"#,
            #"\bigl( a \bigr) \Bigg| w \Bigg| \lVert x \rVert_2 \lvert y \rvert"#,
            #"\boldsymbol{\alpha} + \bm{x} + \dfrac{a}{b} + \tfrac{c}{d} \implies \varnothing \dots"#,
            #"\begin{align} a &= b \\ c &= d \tag{1} \end{align}"#,
            #"\begin{equation} E = mc^2 \label{eq:1} \end{equation}"#,
            #"\begin{array}{cc} 1 & 2 \\ 3 & 4 \end{array}"#,
            #"\overset{\text{def}}{=} \underset{x}{\arg\min} \xrightarrow{f} \underbrace{a+b}_{n} \boxed{x=1}"#,
            #"f(x) = \begin{cases} 1 & \text{如果 } x > 0 \\ 0 & \text{否则} \end{cases}"#,
            #"50\% \text{ 的概率}, a \& b, x ≤ y × z"#,
        ]
        for latex in formulas {
            var error: NSError?
            XCTAssertNotNil(MTMathListBuilder.build(fromString: MathCompat.normalize(latex), error: &error), latex)
            XCTAssertNil(error, "\(latex) → \(MathCompat.normalize(latex))")
        }
        // 换行 `\\` 不能被当成「反斜杠加空格」改掉。
        XCTAssertEqual(MathCompat.normalize(#"a \\ b"#), #"a \\ b"#)
        XCTAssertEqual(MathCompat.normalize(#"a\ b"#), #"a\;b"#)
        // 中文不会被丢掉：排出来的公式比没有中文时宽。
        let with = MathAttachment.rendered(.init(latex: #"\text{否则}"#, display: false), fontSize: 13)
        XCTAssertGreaterThan(with?.size.width ?? 0, 20)
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
        let wide = """
        稍宽（缩小）：

        $$
        \\tilde e = \\mathrm{RMSNorm}_{enorm}(E(t_{i+1})), \\quad \\tilde h = \\mathrm{RMSNorm}_{hnorm}(h_i^{(0)})
        $$

        特别长（左右滑动）：

        $$
        \\mathcal{L} = -\\frac{1}{T}\\sum_{i=2+k}^{T+1} \\log P_i^{(k)}[t_i] + \\lambda \\sum_{k=1}^{D} \\left( \\alpha_k \\|W_k\\|^2 + \\beta_k \\sum_{j=1}^{n} \\mathrm{KL}(p_j \\| q_j) \\right) + \\gamma \\int_0^1 f(x)\\,dx
        $$

        后文照常。
        """
        for (name, text) in [("math", source), ("wide", wide)] {
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let view = name == "wide" ? InteractiveTaskText(frame: NSRect(x: 0, y: 0, width: 360, height: 300))
                : NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 560))
            view.drawsBackground = true
            view.appearance = appearance
            view.textContainerInset = NSSize(width: 16, height: 16)
            view.backgroundColor = dark ? NSColor(white: 0.12, alpha: 1) : .white
            view.textStorage?.setAttributedString(MarkdownText.render(text, color: .labelColor, fontSize: 13))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: path).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
        }
    }
}
