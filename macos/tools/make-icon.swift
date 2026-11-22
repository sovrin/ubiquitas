// Draws the app icon and writes it into Assets.xcassets. Run from macos/: swift tools/make-icon.swift
import AppKit

let assets = URL(fileURLWithPath: "ubiquitas/Assets.xcassets")
let iconSet = assets.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, alpha: 1)
}

/// macOS icon grid: an 824 pt rounded tile centred on a 1024 pt canvas.
func icon(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = Double(px) / 1024
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    NSGradient(starting: color(0x2BC4E8), ending: color(0x3A55DE))!
        .draw(in: NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s), angle: -60)
    let config = NSImage.SymbolConfiguration(pointSize: 380 * s, weight: .medium).applying(.init(paletteColors: [.white]))
    let symbol = NSImage(systemSymbolName: "display.2", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    symbol.draw(in: NSRect(x: tile.midX - symbol.size.width / 2, y: tile.midY - symbol.size.height / 2,
                           width: symbol.size.width, height: symbol.size.height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try icon(points * scale).write(to: iconSet.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let info = ["author": "xcode", "version": 1] as [String: Any]
try JSONSerialization.data(withJSONObject: ["images": images, "info": info], options: [.prettyPrinted, .sortedKeys])
    .write(to: iconSet.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": info], options: [.prettyPrinted])
    .write(to: assets.appendingPathComponent("Contents.json"))
print("wrote \(iconSet.path)")
