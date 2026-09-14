import AppKit

let size = NSSize(width: 660, height: 420)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1320, pixelsHigh: 840,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

NSColor(srgbRed: 0.99, green: 0.97, blue: 0.985, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
let ink = NSColor(srgbRed: 0.19, green: 0.14, blue: 0.22, alpha: 1)
let secondary = NSColor(srgbRed: 0.39, green: 0.32, blue: 0.43, alpha: 1)

func text(_ value: String, top: CGFloat, font: NSFont, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    (value as NSString).draw(in: NSRect(x: 30, y: size.height - top - 40, width: 600, height: 40),
        withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
}

let titleFont = NSFont.systemFont(ofSize: 30, weight: .semibold)
text("Install Yapper", top: 38, font: titleFont, color: ink)
text("Drag Yapper into Applications", top: 86, font: .systemFont(ofSize: 16), color: secondary)

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 294, y: 210))
arrow.line(to: NSPoint(x: 364, y: 210))
arrow.move(to: NSPoint(x: 345, y: 228))
arrow.line(to: NSPoint(x: 364, y: 210))
arrow.line(to: NSPoint(x: 345, y: 192))
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(srgbRed: 0.67, green: 0.40, blue: 0.55, alpha: 1).setStroke()
arrow.stroke()

text("Then open Yapper from Applications.", top: 321,
    font: .systemFont(ofSize: 15, weight: .medium), color: ink)
text("Choose a model and approve permissions on first launch.", top: 347,
    font: .systemFont(ofSize: 12), color: secondary)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
