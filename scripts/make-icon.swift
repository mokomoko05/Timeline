import AppKit

let destination = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(srgbRed: 36.0 / 255, green: 41.0 / 255, blue: 47.0 / 255, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 205, yRadius: 205).fill()
let accent = NSColor(srgbRed: 83.0 / 255, green: 159.0 / 255, blue: 247.0 / 255, alpha: 1)
let rail = NSBezierPath()
rail.move(to: NSPoint(x: 318, y: 280))
rail.line(to: NSPoint(x: 318, y: 744))
rail.lineWidth = 18
rail.lineCapStyle = .round
accent.withAlphaComponent(0.5).setStroke()
rail.stroke()
for (height, width) in [(744.0, 300.0), (512.0, 242.0), (280.0, 334.0)] {
    NSColor(srgbRed: 36.0 / 255, green: 41.0 / 255, blue: 47.0 / 255, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 264, y: height - 54, width: 108, height: 108)).fill()
    accent.setFill()
    NSBezierPath(ovalIn: NSRect(x: 286, y: height - 32, width: 64, height: 64)).fill()
    NSColor.white.withAlphaComponent(height == 512 ? 1 : 0.65).setFill()
    NSBezierPath(roundedRect: NSRect(x: 424, y: height - 18, width: width, height: 36), xRadius: 18, yRadius: 18).fill()
}
accent.setStroke()
let current = NSBezierPath(ovalIn: NSRect(x: 270, y: 464, width: 96, height: 96))
current.lineWidth = 5
current.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
