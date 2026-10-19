import AppKit
import SwiftUI

/// 非激活面板中的模式按钮应在第一次按下时响应，且不抢正文编辑焦点。
struct QuickCaptureModePicker: NSViewRepresentable {
    let mode: QuickCaptureMode
    let select: (QuickCaptureMode) -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
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
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.backgroundColor = NSColor(Palette.background).cgColor
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

    override func draw(_ dirtyRect: NSRect) {
        if selected || hovered {
            NSGraphicsContext.saveGraphicsState()
            if hovered {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
                shadow.shadowBlurRadius = 3
                shadow.shadowOffset = NSSize(width: 0, height: -1.5)
                shadow.set()
            }
            NSColor(Palette.soft).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            NSGraphicsContext.restoreGraphicsState()
            if hovered {
                NSColor(Palette.line).setStroke()
                let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
                border.lineWidth = 0.75
                border.stroke()
            }
        }
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(selected ? Palette.accent : Palette.muted)
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}
