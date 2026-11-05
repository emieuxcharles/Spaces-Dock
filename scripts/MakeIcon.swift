import AppKit
import Foundation

// Original vector artwork: three desktop panes with one selected Space.
// No system symbol, screenshot or Apple artwork is incorporated.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
func draw(pixels: Int, destination: URL) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    let tile = rounded(100, 100, 824, 824, 188)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 22
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.set()
    color(0.18, 0.24, 0.61).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0.24, 0.40, 0.83), ending: color(0.15, 0.20, 0.52))!
        .draw(in: tile, angle: -65)
    color(1, 1, 1, 0.18).setStroke()
    tile.lineWidth = 2
    tile.stroke()
    // A light rail ties the spaces together without depicting a replacement Dock.
    color(0.83, 0.91, 1, 0.23).setFill()
    rounded(270, 239, 484, 12, 6).fill()
    let panes: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (205, 405, 184, 276, 0.35), (420, 365, 184, 356, 1.0), (635, 405, 184, 276, 0.55)
    ]
    for (x, y, width, height, opacity) in panes {
        NSGraphicsContext.saveGraphicsState()
        let pane = rounded(x, y, width, height, 30)
        let paneShadow = NSShadow()
        paneShadow.shadowOffset = NSSize(width: 0, height: -8)
        paneShadow.shadowBlurRadius = 12
        paneShadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
        paneShadow.set()
        color(0.93, 0.97, 1, opacity).setFill()
        pane.fill()
        NSGraphicsContext.restoreGraphicsState()
        color(0.24, 0.40, 0.78, opacity == 1 ? 0.19 : 0.16).setFill()
        rounded(x + 20, y + 24, width - 40, height - 87, 15).fill()
        color(0.19, 0.32, 0.67, opacity == 1 ? 0.5 : 0.32).setFill()
        rounded(x + 23, y + height - 38, width - 46, 8, 4).fill()
    }
    color(0.91, 0.97, 1).setFill()
    rounded(482, 224, 60, 42, 21).fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
}
for size in [16, 32, 128, 256, 512] {
    try draw(pixels: size, destination: directory.appendingPathComponent("icon_\(size)x\(size).png"))
    try draw(pixels: size * 2, destination: directory.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
// ICNS is a big-endian chunk container. Modern macOS reads PNG representations
// directly; writing them here avoids iconutil's host image-conversion service.
func bigEndian(_ value: Int) -> Data {
    var value = UInt32(value).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
let entries = [
    ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"),
    ("ic14", "icon_256x256@2x.png")
]
var chunks = Data()
for (type, filename) in entries {
    let png = try Data(contentsOf: directory.appendingPathComponent(filename))
    chunks.append(type.data(using: .ascii)!)
    chunks.append(bigEndian(png.count + 8))
    chunks.append(png)
}
var icon = Data("icns".utf8)
icon.append(bigEndian(chunks.count + 8))
icon.append(chunks)
let iconURL = directory.appendingPathComponent("AppIcon.icns")
try icon.write(to: iconURL)
guard let decoded = NSImage(contentsOf: iconURL), !decoded.representations.isEmpty else {
    fatalError("macOS could not decode generated ICNS")
}
