import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift tools/make-icon.swift OUTPUT.iconset\n", stderr)
    exit(1)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for (name, size) in sizes {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.24, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 56, y: 56, width: 912, height: 912),
        xRadius: 205, yRadius: 205).fill()

    NSColor(calibratedRed: 0.57, green: 0.85, blue: 0.43, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 244, y: 230, width: 536, height: 346),
        xRadius: 70, yRadius: 70).fill()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 244, y: 610))
    head.curve(to: NSPoint(x: 780, y: 610), controlPoint1: NSPoint(x: 244, y: 940),
        controlPoint2: NSPoint(x: 780, y: 940))
    head.close()
    head.fill()

    NSColor(calibratedRed: 0.57, green: 0.85, blue: 0.43, alpha: 1).setStroke()
    let antennas = NSBezierPath()
    antennas.lineWidth = 25
    antennas.lineCapStyle = .round
    antennas.move(to: NSPoint(x: 358, y: 804))
    antennas.line(to: NSPoint(x: 310, y: 868))
    antennas.move(to: NSPoint(x: 666, y: 804))
    antennas.line(to: NSPoint(x: 714, y: 868))
    antennas.stroke()

    NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.24, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 363, y: 683, width: 41, height: 41)).fill()
    NSBezierPath(ovalIn: NSRect(x: 620, y: 683, width: 41, height: 41)).fill()
    NSBezierPath(roundedRect: NSRect(x: 316, y: 291, width: 392, height: 205),
        xRadius: 30, yRadius: 30).fill()

    NSColor.white.setStroke()
    let prompt = NSBezierPath()
    prompt.lineWidth = 25
    prompt.lineCapStyle = .round
    prompt.lineJoinStyle = .round
    prompt.move(to: NSPoint(x: 368, y: 350))
    prompt.line(to: NSPoint(x: 418, y: 393))
    prompt.line(to: NSPoint(x: 368, y: 436))
    prompt.move(to: NSPoint(x: 464, y: 350))
    prompt.line(to: NSPoint(x: 585, y: 350))
    prompt.stroke()

    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
