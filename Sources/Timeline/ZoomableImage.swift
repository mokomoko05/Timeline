import AppKit
import SwiftUI

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

/// AppKit handles panning, scroll bars and trackpad magnification. Loading is tied to
/// the file URL, so zooming does not decode the original image on each SwiftUI update.
final class ImageZoomScrollView: NSScrollView {
    private let picture = PannableImageView()
    private var url: URL?
    private var relativeZoom: CGFloat = 1
    private var fitting = false
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func clear() {
        url = nil
        picture.image = nil
    }

    func display(_ url: URL, zoom: CGFloat) {
        if self.url != url {
            self.url = url
            picture.image = NSImage(contentsOf: url)
            picture.frame = NSRect(origin: .zero, size: picture.image?.size ?? NSSize(width: 1, height: 1))
            picture.toolTip = picture.image == nil ? AppLocalized("找不到这张图片的文件") : nil
            missingLabel.isHidden = picture.image != nil
        }
        relativeZoom = zoom
        fitIfNeeded()
    }

    private var fitScale: CGFloat {
        guard picture.frame.width > 0, picture.frame.height > 0 else { return 1 }
        return max(0.001, min(contentView.frame.width / picture.frame.width, contentView.frame.height / picture.frame.height))
    }

    private func fitIfNeeded() {
        guard !fitting, contentView.frame.width > 0, contentView.frame.height > 0 else { return }
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
