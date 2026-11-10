// Рисует иконку Сугроба: ночное небо, снежинка, шапка снега по верхней кромке.
//   ./scripts/make-icon.sh
import AppKit

let out = CommandLine.arguments[1]
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Подложка по сетке macOS: квадрат 824 со скруглением ~185 в центре холста 1024.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.current?.saveGraphicsState()
shape.addClip()
NSGradient(colors: [NSColor(red: 0.07, green: 0.12, blue: 0.27, alpha: 1),
                    NSColor(red: 0.18, green: 0.36, blue: 0.55, alpha: 1)])!.draw(in: tile, angle: -90)

// Редкие снежинки на фоне.
var seed: UInt64 = 7
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 40) / CGFloat(1 << 24) }
for _ in 0..<38 {
    let r = 3 + rnd() * 7
    let p = NSPoint(x: tile.minX + rnd() * tile.width, y: tile.minY + 120 + rnd() * (tile.height - 260))
    NSColor(white: 1, alpha: 0.35 + rnd() * 0.5).setFill()
    NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
}

// Сугроб внизу.
let drift = NSBezierPath()
drift.move(to: NSPoint(x: tile.minX, y: tile.minY))
drift.line(to: NSPoint(x: tile.minX, y: tile.minY + 150))
drift.curve(to: NSPoint(x: tile.midX - 60, y: tile.minY + 120),
            controlPoint1: NSPoint(x: tile.minX + 180, y: tile.minY + 215),
            controlPoint2: NSPoint(x: tile.midX - 180, y: tile.minY + 110))
drift.curve(to: NSPoint(x: tile.maxX, y: tile.minY + 175),
            controlPoint1: NSPoint(x: tile.midX + 110, y: tile.minY + 135),
            controlPoint2: NSPoint(x: tile.maxX - 160, y: tile.minY + 230))
drift.line(to: NSPoint(x: tile.maxX, y: tile.minY))
drift.close()
NSGradient(colors: [NSColor(red: 0.80, green: 0.86, blue: 0.95, alpha: 1), NSColor.white])!.draw(in: drift, angle: 90)
NSGraphicsContext.current?.restoreGraphicsState()

// Снежинка.
let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .light)
    .applying(.init(paletteColors: [NSColor.white]))
if let flake = NSImage(systemSymbolName: "snowflake", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = flake.size
    flake.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 + 40, width: s.width, height: s.height))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
