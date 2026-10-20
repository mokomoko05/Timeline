import AppKit
import SwiftUI

struct TimelineMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let axis = rect.minX + rect.width * 0.2
        let radius = rect.width * 0.09
        for fraction in [0.2, 0.5, 0.8] {
            let height = rect.minY + rect.height * fraction
            path.addEllipse(in: CGRect(x: axis - radius, y: height - radius, width: radius * 2, height: radius * 2))
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.48, y: height))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * (fraction == 0.5 ? 0.8 : 0.95), y: height))
            if fraction < 0.8 {
                path.move(to: CGPoint(x: axis, y: height + radius))
                path.addLine(to: CGPoint(x: axis, y: height + rect.height * 0.3 - radius))
            }
        }
        return path
    }

    static func menuImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let path = TimelineMark().path(in: rect.insetBy(dx: 1, dy: 1)).cgPath
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(path)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1.3)
            context.setLineCap(.round)
            context.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Timeline"
        return image
    }
}
