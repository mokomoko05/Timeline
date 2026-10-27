import AppKit
import TimelineMath
import TimelineCore

/// Markdown 里的公式排成文字里的一个附件（SwiftMath，CoreText 原生排版，不起 WebView）。
///
/// 每个公式只排一次版，画成一张遮罩（Retina 分辨率）；画的时候按当时的外观取文字颜色、透过遮罩填色。
/// 切换深浅色不用重新排版，滚动重画只是贴一张小图。排版结果按公式和字号全局缓存。
enum MathAttachment {
    static let displayKey = NSAttributedString.Key("TimelineMarkdownMathDisplay")
    /// 拉丁现代体和正文的苹方 / SF 放在一起显得小一点，稍微放大。
    static let fontScale: CGFloat = 1.1

    final class Rendered {
        let size: NSSize
        /// 基线离图片底边的距离（和 SwiftMath 摆放公式的算法一致）。
        let baseline: CGFloat
        let mask: CGImage

        init?(formula: MarkdownMath.Formula, fontSize: CGFloat) {
            var math = MathImage(latex: MathCompat.normalize(formula.latex), fontSize: fontSize, textColor: .black,
                                 labelMode: formula.display ? .display : .text, textAlignment: .left)
            let (error, image, info) = math.asImage()
            guard error == nil, let image, let info, image.size.width > 0, image.size.height > 0 else { return nil }
            let scale = max(2, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
            let width = Int((image.size.width * scale).rounded(.up)), height = Int((image.size.height * scale).rounded(.up))
            // NSImage 只能画进 RGBA 画布；再用 CoreGraphics 把它画进只有透明度的画布，那一层直接当灰度遮罩：值大的地方是字形。
            guard let color = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let coverage = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
                  let pixels = coverage.data else { return nil }
            color.scaleBy(x: scale, y: scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: color, flipped: false)
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
            guard let drawn = color.makeImage() else { return nil }
            coverage.draw(drawn, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let provider = CGDataProvider(data: Data(bytes: pixels, count: width * height) as CFData),
                  let mask = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
            self.mask = mask
            size = image.size
            baseline = (image.size.height - max(info.ascent + info.descent, fontSize / 2)) / 2 + info.descent
        }

        func draw(in rect: NSRect, color: NSColor, flipped: Bool = false) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            if flipped {
                context.translateBy(x: 0, y: rect.minY + rect.maxY)
                context.scaleBy(x: 1, y: -1)
            }
            context.clip(to: rect, mask: mask)
            context.setFillColor(color.cgColor)
            context.fill(rect)
            context.restoreGState()
        }
    }

    private static var cache: [String: Rendered] = [:]
    private static var failed: Set<String> = []

    /// 宽公式最多缩到这么小；独立公式再宽就保持这个大小，在自己那一条里左右滑动（`InteractiveTaskText` 放滑动条）。
    static let minimumScale: CGFloat = 0.75

    /// 画公式的格子：比一行宽的公式（窄窗口、侧栏）按比例缩小到正好放得下；独立公式缩到 `minimumScale` 还放不下，
    /// 就占满一行宽、自己不画，由文字视图在这里放一条能左右滑动的公式。
    final class Cell: NSTextAttachmentCell {
        let rendered: Rendered
        let color: NSColor
        let display: Bool

        init(_ rendered: Rendered, color: NSColor, display: Bool) {
            self.rendered = rendered
            self.color = color
            self.display = display
            super.init(imageCell: nil)
        }

        required init(coder: NSCoder) { fatalError() }

        override func cellSize() -> NSSize { rendered.size }
        override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -rendered.baseline) }

        override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                                glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
            let natural = NSRect(x: 0, y: -rendered.baseline, width: rendered.size.width, height: rendered.size.height)
            let available = lineFrag.width - position.x - textContainer.lineFragmentPadding
            guard available > 20, natural.width > available else { return natural }
            let fit = available / natural.width
            let scale = display ? max(fit, MathAttachment.minimumScale) : fit
            return NSRect(x: 0, y: natural.minY * scale, width: min(available, natural.width * scale), height: natural.height * scale)
        }

        /// 这个宽度下放不下、要左右滑动。
        func scrolls(in width: CGFloat) -> Bool { width < rendered.size.width * MathAttachment.minimumScale - 0.5 }

        override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
            guard !scrolls(in: cellFrame.width) else { return }
            rendered.draw(in: cellFrame, color: color, flipped: controlView?.isFlipped ?? true)
        }

        override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
            draw(withFrame: cellFrame, in: controlView)
        }
    }

    static func rendered(_ formula: MarkdownMath.Formula, fontSize: CGFloat) -> Rendered? {
        let size = (fontSize * fontScale * 2).rounded() / 2
        let key = "\(formula.display ? "D" : "I")\(size)|\(formula.latex)"
        if let cached = cache[key] { return cached }
        if failed.contains(key) { return nil }
        guard let rendered = Rendered(formula: formula, fontSize: size) else {
            failed.insert(key)
            return nil
        }
        if cache.count > 600 { cache.removeAll() }
        cache[key] = rendered
        return rendered
    }

    /// 公式附件。排不出来（语法错误、不支持的命令）时返回 nil，调用方显示原文。
    static func string(_ formula: MarkdownMath.Formula, fontSize: CGFloat, color: NSColor, font: NSFont) -> NSMutableAttributedString? {
        guard let rendered = rendered(formula, fontSize: fontSize) else { return nil }
        let attachment = NSTextAttachment()
        // 颜色在画的时候才取：动态颜色按当时的外观解析。
        attachment.attachmentCell = Cell(rendered, color: color, display: formula.display)
        attachment.bounds = NSRect(x: 0, y: -rendered.baseline, width: rendered.size.width, height: rendered.size.height)
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes([.font: font, .foregroundColor: color, .toolTip: formula.source], range: NSRange(location: 0, length: result.length))
        if formula.display { result.addAttribute(displayKey, value: true, range: NSRange(location: 0, length: result.length)) }
        return result
    }
}
