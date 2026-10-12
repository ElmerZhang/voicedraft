import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let unit = CGFloat(pixels) / 1024
        NSColor(calibratedRed: 0.20, green: 0.39, blue: 0.30, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 52 * unit, y: 52 * unit, width: 920 * unit, height: 920 * unit),
                     xRadius: 212 * unit, yRadius: 212 * unit).fill()
        NSColor(calibratedRed: 0.97, green: 0.97, blue: 0.91, alpha: 1).setStroke()
        for (index, height) in [180.0, 330.0, 510.0, 390.0, 230.0].enumerated() {
            let line = NSBezierPath()
            line.lineWidth = 52 * unit; line.lineCapStyle = .round
            let x = CGFloat(312 + index * 100) * unit
            line.move(to: NSPoint(x: x, y: (512 - height / 2) * unit))
            line.line(to: NSPoint(x: x, y: (512 + height / 2) * unit))
            line.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(filename))
    }
}
