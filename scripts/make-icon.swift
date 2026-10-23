import AppKit
import ImageIO

// Mac: make-icon.swift <iconset> [output.icns]
// iOS: make-icon.swift --ios <AppIcon.appiconset>
let arguments = Array(CommandLine.arguments.dropFirst())
let isIOS = arguments.first == "--ios"
let paths = isIOS ? Array(arguments.dropFirst()) : arguments
guard paths.count == 1 || (!isIOS && paths.count == 2) else {
    fatalError("Usage: make-icon.swift <iconset> [output.icns] | --ios <AppIcon.appiconset>")
}
let destination = URL(fileURLWithPath: paths[0], isDirectory: true)
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
        if isIOS && (size != 512 || scale != 2) { continue }
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let unit = CGFloat(pixels) / 1024
        NSColor(calibratedRed: 0.20, green: 0.39, blue: 0.30, alpha: 1).setFill()
        if isIOS {
            // iOS owns the corner mask. Fill the square, with no transparent Mac-style padding.
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: pixels, height: pixels)).fill()
        } else {
            NSBezierPath(roundedRect: NSRect(x: 52 * unit, y: 52 * unit, width: 920 * unit, height: 920 * unit),
                         xRadius: 212 * unit, yRadius: 212 * unit).fill()
        }
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
        let filename = isIOS ? "AppIcon.png" : "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let png: Data
        if isIOS {
            // Keep AppKit's RGBA drawing context; flatten to an opaque RGB PNG only when encoding.
            let opaque = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            opaque.draw(bitmap.cgImage!, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
            let data = NSMutableData()
            let output = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(output, opaque.makeImage()!, nil)
            precondition(CGImageDestinationFinalize(output), "Could not encode the iOS icon.")
            png = data as Data
        } else {
            png = bitmap.representation(using: .png, properties: [:])!
        }
        try png.write(to: destination.appendingPathComponent(filename))
        if !isIOS { elements.append(chunk(elementTypes[size]![scale - 1], png)) }
    }
}
if isIOS {
    let contents: [String: Any] = [
        "images": [["filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]],
        "info": ["author": "xcode", "version": 1],
    ]
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        .write(to: destination.appendingPathComponent("Contents.json"), options: .atomic)
} else if paths.count > 1 {
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
    try icon.write(to: URL(fileURLWithPath: paths[1]), options: .atomic)
}
