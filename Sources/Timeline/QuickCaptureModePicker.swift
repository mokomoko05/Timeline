import AppKit
import SwiftUI

/// 非激活面板中的模式按钮应在第一次按下时响应，且不抢正文编辑焦点。
struct QuickCaptureModePicker: NSViewRepresentable {
    let mode: QuickCaptureMode
    let select: (QuickCaptureMode) -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSView {
        let view = CaptureModeTrack()
        for (index, choice) in [QuickCaptureMode.todo, .log].enumerated() {
            let button = CaptureModeButton()
            button.choice = choice
            button.frame = NSRect(x: 4 + index * 65, y: 4, width: 62, height: 26)
            button.setAccessibilityIdentifier("quick-mode-" + choice.rawValue)
            view.addSubview(button)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        view.needsDisplay = true
        for case let button as CaptureModeButton in view.subviews {
            button.title = AppLocalized(button.choice == .todo ? "待办" : "日志")
            button.selected = mode == button.choice
            button.state = button.selected ? .on : .off
            let choice = button.choice
            button.choose = { select(choice) }
            button.needsDisplay = true
        }
    }
}

/// 分段控件的底槽。颜色在每次绘制时按当前外观取值（之前在创建时转成 CGColor，切换深浅色后不变）。
final class CaptureModeTrack: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium)
        NativePalette.background.setFill()
        path.fill()
        NativePalette.line.withAlphaComponent(0.7).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium)
        border.lineWidth = Metrics.hairline
        border.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        subviews.forEach { $0.needsDisplay = true }
    }
}

final class CaptureModeButton: NSButton {
    var choice: QuickCaptureMode = .todo
    var selected = false
    var choose: () -> Void = {}
    private var hovered = false
    private var hoverTracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { choose() }
    override func performClick(_ sender: Any?) { choose() }
    override func accessibilityPerformPress() -> Bool { choose(); return true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    /// 选中的一段像浮在底槽上的卡片（卡片色、细边、轻阴影）；悬停的未选中段只加一层浅底。
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusSmall, yRadius: Metrics.radiusSmall)
        if selected {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            NativePalette.card.setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            NativePalette.line.setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Metrics.radiusSmall, yRadius: Metrics.radiusSmall)
            border.lineWidth = Metrics.hairline
            border.stroke()
        } else if hovered {
            NativePalette.soft.withAlphaComponent(0.6).setFill()
            shape.fill()
        }
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .medium),
            .foregroundColor: selected ? NativePalette.ink : NativePalette.muted
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}
