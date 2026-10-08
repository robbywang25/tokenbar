#!/usr/bin/env swift
import AppKit
import Foundation

// Original quota-bar artwork drawn with native paths; no SF Symbols or downloaded assets.
// SF Symbols are appropriate for interface controls, but not for an app's brand icon.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift scripts/generate-icon.swift OUTPUT.iconset\n", stderr)
    exit(2)
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

let mint = NSColor(srgbRed: 0.40, green: 0.91, blue: 0.79, alpha: 1)
let master = NSImage(size: NSSize(width: 1024, height: 1024))
master.lockFocus()
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
let tileRect = NSRect(x: 72, y: 72, width: 880, height: 880)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 196, yRadius: 196)
let gradient = NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.22, blue: 0.25, alpha: 1),
                          ending: NSColor(srgbRed: 0.025, green: 0.065, blue: 0.085, alpha: 1))!
gradient.draw(in: tile, angle: -60)
NSColor.white.withAlphaComponent(0.12).setStroke()
tile.lineWidth = 3
tile.stroke()

// Three independent tracks are deliberately distinct from an SF Symbol silhouette.
// Their offset token end-caps form a small diagonal across the quota bars.
let rows: [(CGFloat, CGFloat, CGFloat)] = [(660, 390, 1.0), (478, 272, 0.78), (296, 330, 0.56)]
for (y, fillWidth, opacity) in rows {
    NSColor.white.withAlphaComponent(0.08).setFill()
    NSBezierPath(roundedRect: NSRect(x: 216, y: y, width: 592, height: 98),
                 xRadius: 34, yRadius: 34).fill()
    mint.withAlphaComponent(opacity).setFill()
    NSBezierPath(roundedRect: NSRect(x: 216, y: y, width: fillWidth, height: 98),
                 xRadius: 34, yRadius: 34).fill()
    NSColor(srgbRed: 0.80, green: 1.0, blue: 0.94, alpha: 1).withAlphaComponent(opacity).setFill()
    NSBezierPath(roundedRect: NSRect(x: 216 + fillWidth + 14, y: y + 13, width: 38, height: 72),
                 xRadius: 12, yRadius: 12).fill()
}
master.unlockFocus()

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fputs("Unable to create icon bitmap.\n", stderr)
            exit(1)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        master.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                    from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
