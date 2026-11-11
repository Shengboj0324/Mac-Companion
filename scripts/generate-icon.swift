// Renders the original Companion app icon (no third-party artwork) into an .iconset.
// Usage: swift scripts/generate-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.62, alpha: 1), NSColor(calibratedRed: 0.13, green: 0.27, blue: 0.45, alpha: 1)])!
        .draw(in: bg, angle: -90)
    // Companion face: a soft circle with two eyes.
    let face = NSRect(x: s * 0.27, y: s * 0.25, width: s * 0.46, height: s * 0.46)
    NSColor(calibratedRed: 1, green: 0.93, blue: 0.9, alpha: 1).setFill()
    NSBezierPath(ovalIn: face).fill()
    NSColor(calibratedRed: 0.2, green: 0.15, blue: 0.3, alpha: 1).setFill()
    for dx in [-0.08, 0.08] {
        NSBezierPath(ovalIn: NSRect(x: s * (0.5 + dx) - s * 0.035, y: s * 0.47, width: s * 0.07, height: s * 0.095)).fill()
    }
    NSColor(calibratedRed: 0.6, green: 0.2, blue: 0.3, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.46, y: s * 0.37, width: s * 0.08, height: s * 0.022), xRadius: s * 0.011, yRadius: s * 0.011).fill()
    // Orbit ring hinting at "files around you".
    NSColor(calibratedWhite: 1, alpha: 0.85).setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: s * 0.2, y: s * 0.18, width: s * 0.6, height: s * 0.6))
    ring.lineWidth = max(1, s * 0.025)
    ring.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128),
                   ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("\(name).png"))
}
