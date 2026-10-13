import AppKit
import ImageIO

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
// ICNS stores each PNG in a typed, length-prefixed element. Keep packaging
// self-contained: iconutil can fail even when all source PNGs are valid.
let elementTypes = [16: ["icp4", "ic11"], 32: ["icp5", "ic12"],
                    128: ["ic07", "ic13"], 256: ["ic08", "ic14"], 512: ["ic09", "ic10"]]
func chunk(_ type: String, _ payload: Data) -> Data {
    var length = UInt32(payload.count + 8).bigEndian
    var data = Data(type.utf8)
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(payload)
    return data
}
var elements = Data()
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
        bitmap.size = NSSize(width: size, height: size)
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: destination.appendingPathComponent(filename))
        elements.append(chunk(elementTypes[size]![scale - 1], png))
    }
}
if CommandLine.arguments.count > 2 {
    let icon = chunk("icns", elements)
    guard let source = CGImageSourceCreateWithData(icon as CFData, nil),
          CGImageSourceGetCount(source) == 10 else {
        fatalError("Could not decode the generated ICNS icon.")
    }
    var dimensions: [Int] = []
    for index in 0..<CGImageSourceGetCount(source) {
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil), image.width == image.height else {
            fatalError("Could not decode an icon representation.")
        }
        dimensions.append(image.width)
    }
    precondition(dimensions.sorted() == [16, 32, 32, 64, 128, 256, 256, 512, 512, 1024],
                 "The icon is missing a required resolution.")
    try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
}
