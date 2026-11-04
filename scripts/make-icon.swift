#!/usr/bin/env swift
// Renders Resources/AppIcon.icns and docs/icon.png from original vector artwork.
// (No SF Symbols — Apple's license doesn't allow them in app icons.)
// Usage: swift scripts/make-icon.swift [repo-root]
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func draw(in s: CGFloat) {
    // Tile on the macOS icon grid (824/1024, centered).
    let inset = s * 100 / 1024
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.35)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    color(0x1B1F3B).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    NSGradient(colors: [color(0x2B5BFF), color(0x6A3DF0), color(0x9B3FE0)])!.draw(in: tile, angle: -65)
    // Soft top sheen
    NSGradient(colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)])!
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let u = tile.width // unit
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: tile.minX + x * u, y: tile.minY + y * u) }

    let objectShadow = NSShadow()
    objectShadow.shadowColor = color(0x120A40, 0.45)
    objectShadow.shadowBlurRadius = s * 0.03
    objectShadow.shadowOffset = NSSize(width: 0, height: -s * 0.015)

    // Earbud: stem
    NSGraphicsContext.saveGraphicsState()
    objectShadow.set()
    let stem = NSBezierPath()
    let stemWidth = 0.105 * u
    let stemStart = p(0.40, 0.56), stemEnd = p(0.50, 0.20)
    stem.lineWidth = stemWidth
    stem.lineCapStyle = .round
    stem.move(to: stemStart)
    stem.line(to: stemEnd)
    color(0xF4F5FA).setStroke()
    stem.stroke()

    // Earbud: shell
    let shellRect = NSRect(x: p(0.22, 0.50).x, y: p(0.22, 0.50).y, width: 0.34 * u, height: 0.32 * u)
    let shell = NSBezierPath(ovalIn: shellRect)
    NSGradient(colors: [color(0xFFFFFF), color(0xDCDFEA)])!.draw(in: shell, angle: -70)
    NSGraphicsContext.restoreGraphicsState()

    // Ear tip
    let tipRect = NSRect(x: p(0.17, 0.57).x, y: p(0.17, 0.57).y, width: 0.15 * u, height: 0.14 * u)
    NSGradient(colors: [color(0xE9EBF2), color(0xC4C8D6)])!.draw(in: NSBezierPath(ovalIn: tipRect), angle: -70)

    // Stem tip
    let capCenter = stemEnd
    color(0xB7BCCB).setFill()
    NSBezierPath(ovalIn: NSRect(x: capCenter.x - stemWidth / 2, y: capCenter.y - stemWidth / 2, width: stemWidth, height: stemWidth)).fill()

    // Cursor arrow (tip at top-left), with motion lines
    let ax = 0.58, ay = 0.52, sc = 0.30
    func a(_ x: CGFloat, _ y: CGFloat) -> NSPoint { p(ax + x * sc, ay - y * sc) }
    let arrow = NSBezierPath()
    arrow.move(to: a(0, 0))
    arrow.line(to: a(0, 1.0))
    arrow.line(to: a(0.25, 0.78))
    arrow.line(to: a(0.42, 1.14))
    arrow.line(to: a(0.58, 1.07))
    arrow.line(to: a(0.41, 0.71))
    arrow.line(to: a(0.73, 0.71))
    arrow.close()
    arrow.lineJoinStyle = .round

    NSGraphicsContext.saveGraphicsState()
    objectShadow.set()
    color(0xFFFFFF).setFill()
    arrow.fill()
    NSGraphicsContext.restoreGraphicsState()
    arrow.lineWidth = 0.022 * u
    color(0x1B1F3B).setStroke()
    arrow.stroke()

}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(in: CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let docs = root.appendingPathComponent("docs")
try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
try render(512).write(to: docs.appendingPathComponent("icon.png"))

let out = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
exit(task.terminationStatus)
