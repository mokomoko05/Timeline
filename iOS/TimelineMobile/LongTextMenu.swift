import ObjectiveC
import SwiftUI
import UIKit

/// 日志文字的长按菜单。SwiftUI 的 `contextMenu` 总是把整块文字浮起来：比屏幕还高的一块先往上弹、再缩成预览，很跳。
/// 这里短的一块照样整块浮起来；长的只把手指附近的一段（不超过屏幕高度的四成）原地浮起来，菜单贴在旁边。
///
/// 放在文字块的背景里只用来量位置；长按由所在滚动视图上的一个菜单交互统一接住，按位置找到是哪一块。
struct LongTextMenu: UIViewRepresentable {
    let items: () -> [LogActions.MenuItem]

    func makeUIView(context: Context) -> LongTextMenuAnchor {
        let view = LongTextMenuAnchor()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: LongTextMenuAnchor, context: Context) {
        view.items = items
    }
}

final class LongTextMenuAnchor: UIView {
    var items: (() -> [LogActions.MenuItem])?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, let scroll = sequence(first: superview, next: { $0?.superview }).first(where: { $0 is UIScrollView }) as? UIScrollView
        else { return }
        LongTextMenuHub.on(scroll).anchors.add(self)
    }
}

/// 一个滚动视图上的长按菜单：认得这个滚动视图里所有很长的文字块。
final class LongTextMenuHub: NSObject, UIContextMenuInteractionDelegate {
    private static var key = 0
    let anchors = NSHashTable<LongTextMenuAnchor>.weakObjects()
    private weak var scroll: UIScrollView?
    private(set) weak var interaction: UIContextMenuInteraction?
    /// 这次浮起来的那一段，在滚动视图的坐标里；上下边是不是截在文字中间。
    private var band: CGRect?
    private var cut: (top: Bool, bottom: Bool) = (false, false)

    static func on(_ scroll: UIScrollView) -> LongTextMenuHub {
        if let hub = objc_getAssociatedObject(scroll, &key) as? LongTextMenuHub { return hub }
        let hub = LongTextMenuHub()
        hub.scroll = scroll
        let interaction = UIContextMenuInteraction(delegate: hub)
        scroll.addInteraction(interaction)
        hub.interaction = interaction
        objc_setAssociatedObject(scroll, &key, hub, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return hub
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let scroll,
              let anchor = anchors.allObjects.first(where: { $0.window != nil && $0.bounds.contains($0.convert(location, from: scroll)) }),
              let items = anchor.items?(), !items.isEmpty
        else { return nil }
        // 文字块往外留一点边（和短日志浮起来的圆角块一样），再截到手指上下一段、屏幕看得到的范围里。
        let block = anchor.convert(anchor.bounds, to: scroll).insetBy(dx: -6, dy: -6)
        let visible = scroll.bounds.inset(by: scroll.adjustedContentInset)
        let height = min(block.height, visible.height * 0.4)
        var top = min(max(location.y - height / 2, block.minY), block.maxY - height)
        top = min(max(top, visible.minY), visible.maxY - height)
        let band = CGRect(x: block.minX, y: top, width: block.width, height: height).intersection(block)
        self.band = band
        cut = (band.minY > block.minY + 1, band.maxY < block.maxY - 1)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            var groups: [[UIMenuElement]] = [[]]
            for item in items {
                if item.separated { groups.append([]) }
                var attributes: UIMenuElement.Attributes = []
                if item.disabled { attributes.insert(.disabled) }
                if item.destructive { attributes.insert(.destructive) }
                let action = UIAction(title: item.title, image: UIImage(systemName: item.symbol), attributes: attributes) { _ in item.run() }
                groups[groups.count - 1].append(action)
            }
            return UIMenu(children: groups.map { UIMenu(options: .displayInline, children: $0) })
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        preview()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        preview()
    }

    /// 那一段的实时快照，放回它原来的位置浮起来。截在文字中间的那条边淡出去，不露出半行字。
    private func preview() -> UITargetedPreview? {
        guard let scroll, let band, !band.isEmpty,
              let snapshot = scroll.resizableSnapshotView(from: band, afterScreenUpdates: false, withCapInsets: .zero)
        else { return nil }
        let view = UIView(frame: CGRect(origin: .zero, size: band.size))
        view.addSubview(snapshot)
        if cut.top || cut.bottom {
            let fade = min(28, band.height / 4) / band.height
            let mask = CAGradientLayer()
            mask.frame = view.bounds
            mask.colors = [cut.top ? UIColor.clear.cgColor : UIColor.black.cgColor, UIColor.black.cgColor,
                           UIColor.black.cgColor, cut.bottom ? UIColor.clear.cgColor : UIColor.black.cgColor]
            mask.locations = [0, NSNumber(value: fade), NSNumber(value: 1 - fade), 1]
            view.layer.mask = mask
        }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = UIColor(Palette.background)
        parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: 10)
        return UITargetedPreview(view: view, parameters: parameters,
                                 target: UIPreviewTarget(container: scroll, center: CGPoint(x: band.midX, y: band.midY)))
    }
}
