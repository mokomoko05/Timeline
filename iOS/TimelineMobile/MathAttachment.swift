import TimelineMath
import SwiftUI
import TimelineCore
import UIKit

/// Markdown 里的公式排成 `RichText` 里的一个附件（SwiftMath，CoreText 原生排版，不起 WebView）。
///
/// 每个公式只排一次版，画成一张黑色的图；画的时候按当时的深浅色染成正文颜色（每种外观染一次、记住）。
/// 排版可以在后台做（`MarkdownBlock.prewarm` 预排正文时一起排好），结果按公式和字号全局缓存。
final class MathAttachment: NSTextAttachment {
    /// 拉丁现代体和正文的苹方 / SF 放在一起显得小一点，稍微放大。
    static let fontScale: CGFloat = 1.1

    final class Rendered: @unchecked Sendable {
        let image: UIImage
        /// 基线离图片底边的距离（和 SwiftMath 摆放公式的算法一致）。
        let baseline: CGFloat
        private let lock = NSLock()
        private var tinted: [UIUserInterfaceStyle: UIImage] = [:]

        init?(formula: MarkdownMath.Formula, fontSize: CGFloat) {
            var math = MathImage(latex: formula.latex, fontSize: fontSize, textColor: .black,
                                 labelMode: formula.display ? .display : .text, textAlignment: .left)
            let (error, image, info) = math.asImage()
            guard error == nil, let image, let info, image.size.width > 0, image.size.height > 0 else { return nil }
            self.image = image
            baseline = (image.size.height - max(info.ascent + info.descent, fontSize / 2)) / 2 + info.descent
        }

        func image(for traits: UITraitCollection, color: UIColor) -> UIImage {
            let style = traits.userInterfaceStyle
            lock.lock()
            defer { lock.unlock() }
            if let cached = tinted[style] { return cached }
            let resolved = color.resolvedColor(with: traits)
            let result = UIGraphicsImageRenderer(size: image.size, format: image.imageRendererFormat).image { _ in
                resolved.setFill()
                UIRectFill(CGRect(origin: .zero, size: image.size))
                image.draw(at: .zero, blendMode: .destinationIn, alpha: 1)
            }
            tinted[style] = result
            return result
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Rendered] = [:]
    nonisolated(unsafe) private static var failed: Set<String> = []

    static func rendered(_ formula: MarkdownMath.Formula, fontSize: CGFloat) -> Rendered? {
        let size = (fontSize * fontScale * 2).rounded() / 2
        let key = "\(formula.display ? "D" : "I")\(size)|\(formula.latex)"
        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        let known = failed.contains(key)
        lock.unlock()
        if known { return nil }
        let rendered = Rendered(formula: formula, fontSize: size)
        lock.lock()
        if let rendered {
            if cache.count > 600 { cache.removeAll() }
            cache[key] = rendered
        } else {
            failed.insert(key)
        }
        lock.unlock()
        return rendered
    }

    let rendered: Rendered
    let color: UIColor
    let formula: MarkdownMath.Formula

    init(_ rendered: Rendered, formula: MarkdownMath.Formula, color: UIColor) {
        self.rendered = rendered
        self.color = color
        self.formula = formula
        super.init(data: nil, ofType: nil)
        bounds = CGRect(x: 0, y: -rendered.baseline, width: rendered.image.size.width, height: rendered.image.size.height)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 独占一段的独立公式居中，上下多留一点空。
    static func centerDisplayMath(_ text: NSMutableAttributedString, size: CGFloat) {
        let string = text.string as NSString
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let attachment = value as? MathAttachment, attachment.formula.display else { return }
            let paragraph = string.paragraphRange(for: range)
            let rest = string.substring(with: paragraph).replacingOccurrences(of: "\u{FFFC}", with: "")
            guard rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let current = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle ?? NSParagraphStyle()
            guard let centered = current.mutableCopy() as? NSMutableParagraphStyle else { return }
            centered.alignment = .center
            centered.firstLineHeadIndent = current.headIndent
            centered.paragraphSpacingBefore = max(current.paragraphSpacingBefore, size * 0.4)
            centered.paragraphSpacing = max(current.paragraphSpacing, size * 0.4)
            text.addAttribute(.paragraphStyle, value: centered, range: paragraph)
        }
    }

    /// 画的时候才按当时的深浅色取颜色。
    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> UIImage? {
        rendered.image(for: UITraitCollection.current, color: color)
    }

    /// 公式附件；排不出来时返回 nil，调用方显示原文。
    static func string(_ formula: MarkdownMath.Formula, size: CGFloat, color: UIColor, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString? {
        guard let rendered = rendered(formula, fontSize: size) else { return nil }
        let result = NSMutableAttributedString(attachment: MathAttachment(rendered, formula: formula, color: color))
        result.addAttributes(attributes, range: NSRange(location: 0, length: result.length))
        return result
    }
}

extension Text {
    /// 只能用 `Text` 的地方（标题、表格、划掉的待办）：公式换成模板图拼进文字里，跟着文字的颜色。
    init(markdown text: AttributedString, size: CGFloat) {
        guard text.containsMath else {
            self.init(text)
            return
        }
        var result = Text(verbatim: "")
        for run in text.runs {
            let part: Text
            if let formula = run[MathFormulaAttribute.self], let rendered = MathAttachment.rendered(formula, fontSize: size) {
                part = Text(Image(uiImage: rendered.image).renderingMode(.template)).baselineOffset(-rendered.baseline)
            } else {
                part = Text(AttributedString(text[run.range]))
            }
            result = Text("\(result)\(part)")
        }
        self = result
    }
}
