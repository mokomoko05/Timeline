import AppKit
import SwiftUI
import TimelineCore
import ImageIO

struct ZoomableImage: NSViewRepresentable {
    let url: URL
    @ObservedObject var model: ImageViewerModel

    func makeNSView(context: Context) -> ImageZoomScrollView { ImageZoomScrollView() }
    static func dismantleNSView(_ view: ImageZoomScrollView, coordinator: ()) { view.clear() }
    func updateNSView(_ view: ImageZoomScrollView, context: Context) {
        view.onZoom = { [weak model] in model?.setZoom($0) }
        view.display(url, zoom: model.zoom)
    }
}

/// AppKit handles panning, scroll bars and trackpad magnification; the mouse wheel zooms
/// toward the pointer. Loading is tied to the file URL, so zooming does not decode the
/// original image on each SwiftUI update.
final class ImageZoomScrollView: NSScrollView {
    private let picture = PannableImageView()
    private var url: URL?
    private var relativeZoom: CGFloat = 1
    private var fitting = false
    private var loadingURL: URL?
    private var imageObserver: NSObjectProtocol?
    private let missingLabel = NSTextField(labelWithString: AppLocalized("找不到这张图片的文件"))
    var onZoom: ((CGFloat) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        contentView = CenteredImageClipView()
        contentView.drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.001
        maxMagnification = 32
        picture.imageScaling = .scaleAxesIndependently
        picture.setAccessibilityLabel(AppLocalized("图片 · 可缩放并滚动查看"))
        documentView = picture
        missingLabel.textColor = .secondaryLabelColor
        missingLabel.alignment = .center
        missingLabel.isHidden = true
        addSubview(missingLabel)
        imageObserver = NotificationCenter.default.addObserver(forName: JournalStore.imageAvailable, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let url = self.url, notification.object as? URL == url else { return }
                self.loadingURL = nil
                self.loadOriginal(url)
            }
        }
    }

    deinit { if let imageObserver { NotificationCenter.default.removeObserver(imageObserver) } }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func clear() {
        url = nil
        loadingURL = nil
        picture.image = nil
    }

    func display(_ url: URL, zoom: CGFloat) {
        if self.url != url {
            self.url = url
            picture.image = nil
            loadOriginal(url)
            picture.frame = NSRect(origin: .zero, size: NSSize(width: 1, height: 1))
            picture.toolTip = picture.image == nil ? AppLocalized("找不到这张图片的文件") : nil
            missingLabel.isHidden = picture.image != nil
        }
        relativeZoom = zoom
        fitIfNeeded()
    }

    private func loadOriginal(_ url: URL) {
        guard loadingURL != url else { return }
        loadingURL = url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            let decoded = source.flatMap { source -> CGImage? in
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 1
                let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 1
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
            }
            DispatchQueue.main.async {
                guard let self, self.url == url else { return }
                self.picture.image = decoded.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                self.picture.frame = NSRect(origin: .zero, size: self.picture.image?.size ?? NSSize(width: 1, height: 1))
                self.missingLabel.isHidden = self.picture.image != nil
                self.picture.toolTip = self.picture.image == nil ? AppLocalized("找不到这张图片的文件") : nil
                self.needsLayout = true
                self.layoutSubtreeIfNeeded()
                self.fitIfNeeded()
            }
        }
    }

    /// 按整个滚动视图算：接着鼠标时滚动条占位，用 contentView 算的话放大出滚动条后这个值会变，下一次布局就把图片拉回去。
    private var fitScale: CGFloat {
        guard picture.frame.width > 0, picture.frame.height > 0 else { return 1 }
        return max(0.001, min(bounds.width / picture.frame.width, bounds.height / picture.frame.height))
    }

    private func fitIfNeeded() {
        guard !fitting, picture.image != nil, bounds.width > 0, bounds.height > 0 else { return }
        fitting = true
        defer { fitting = false }
        let target = min(maxMagnification, max(minMagnification, fitScale * relativeZoom))
        if abs(target - magnification) > 0.00001 {
            setMagnification(target, centeredAt: NSPoint(x: picture.bounds.midX, y: picture.bounds.midY))
        }
    }

    override func layout() {
        super.layout()
        missingLabel.frame = NSRect(x: 8, y: max(0, bounds.midY - 10), width: max(0, bounds.width - 16), height: 20)
        fitIfNeeded()
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        relativeZoom = min(8, max(0.25, magnification / fitScale))
        fitIfNeeded()
        onZoom?(relativeZoom)
    }

    /// 鼠标滚轮缩放；触控板双指（带手势阶段）仍是平移，捏合缩放走 `magnify`。
    override func scrollWheel(with event: NSEvent) {
        guard event.phase.isEmpty, event.momentumPhase.isEmpty else { return super.scrollWheel(with: event) }
        let lines = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10 : event.scrollingDeltaY
        guard lines != 0, picture.image != nil else { return }
        // 按手指实际转动的方向算：滚轮向前总是放大，不随「自然滚动」设置反过来。
        let forward = event.isDirectionInvertedFromDevice ? -lines : lines
        zoom(by: pow(1.1, min(5, max(-5, forward))), keeping: event.locationInWindow)
    }

    /// 缩放时让窗口坐标 `point` 下的那个像素留在原地（图片比视口小时仍居中）。
    func zoom(by factor: CGFloat, keeping point: NSPoint) {
        let clip = contentView
        let before = clip.convert(point, from: nil)
        let fraction = NSPoint(x: (before.x - clip.bounds.minX) / clip.bounds.width,
                               y: (before.y - clip.bounds.minY) / clip.bounds.height)
        relativeZoom = min(8, max(0.25, relativeZoom * factor))
        magnification = min(maxMagnification, max(minMagnification, fitScale * relativeZoom))
        let origin = NSPoint(x: before.x - fraction.x * clip.bounds.width,
                             y: before.y - fraction.y * clip.bounds.height)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        reflectScrolledClipView(clip)
        onZoom?(relativeZoom)
    }
}

private final class CenteredImageClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return bounds }
        if documentView.frame.width < bounds.width { bounds.origin.x = (documentView.frame.width - bounds.width) / 2 }
        if documentView.frame.height < bounds.height { bounds.origin.y = (documentView.frame.height - bounds.height) / 2 }
        return bounds
    }
}

private final class PannableImageView: NSImageView {
    private var previousPoint: NSPoint?
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        previousPoint = event.locationInWindow
        NSCursor.closedHand.push()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let previousPoint, let scroll = enclosingScrollView else { return }
        let point = event.locationInWindow
        let clip = scroll.contentView
        let origin = NSPoint(x: clip.bounds.origin.x - (point.x - previousPoint.x) / scroll.magnification,
                             y: clip.bounds.origin.y - (point.y - previousPoint.y) / scroll.magnification)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
        self.previousPoint = point
    }
    override func mouseUp(with event: NSEvent) {
        if previousPoint != nil { NSCursor.pop() }
        previousPoint = nil
    }
}
