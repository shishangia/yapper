import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let blue = NSColor(srgbRed: 0.08, green: 0.33, blue: 0.77, alpha: 1)
let pink = NSColor(srgbRed: 1, green: 0.82, blue: 0.86, alpha: 1)

func render(size: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(size) / 1024)
    transform.concat()
    pink.setFill()
    NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 210, yRadius: 210).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 190, y: 238, width: 644, height: 596), xRadius: 200, yRadius: 200).fill()
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 296, y: 314))
    tail.line(to: NSPoint(x: 278, y: 164))
    tail.line(to: NSPoint(x: 468, y: 275))
    tail.close()
    tail.fill()
    blue.setFill()
    NSBezierPath(ovalIn: NSRect(x: 348, y: 555, width: 66, height: 124)).fill()
    NSBezierPath(ovalIn: NSRect(x: 610, y: 565, width: 66, height: 112)).fill()
    let mouth = NSBezierPath()
    mouth.move(to: NSPoint(x: 342, y: 494))
    mouth.curve(to: NSPoint(x: 688, y: 494), controlPoint1: NSPoint(x: 354, y: 301), controlPoint2: NSPoint(x: 670, y: 309))
    mouth.curve(to: NSPoint(x: 342, y: 494), controlPoint1: NSPoint(x: 620, y: 444), controlPoint2: NSPoint(x: 414, y: 444))
    mouth.close()
    mouth.fill()
    pink.setFill()
    NSBezierPath(ovalIn: NSRect(x: 464, y: 361, width: 126, height: 60)).fill()
    blue.setStroke()
    for (x, y, dx) in [(126.0, 510.0, -38.0), (850.0, 585.0, 45.0), (847.0, 702.0, 33.0)] {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x, y: y))
        line.line(to: NSPoint(x: x + dx, y: y + 24))
        line.lineWidth = 23
        line.lineCapStyle = .round
        line.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

let assets = root.appendingPathComponent("Yapper/Assets.xcassets")
for size in [16, 32, 64, 128, 256, 512, 1024] {
    try render(size: size).write(to: assets.appendingPathComponent("AppIcon.appiconset/icon_\(size)x\(size).png"))
}
try render(size: 256).write(to: assets.appendingPathComponent("AppLogo.imageset/logo.png"))
