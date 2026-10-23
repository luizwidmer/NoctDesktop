// SPDX-License-Identifier: AGPL-3.0-only
// Rebuild the code-drawn icon with: swift tools/MakeIcon.swift
import AppKit

let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
var entries = [[String: String]]()
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
        let tile = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 200, yRadius: 200)
        NSGradient(starting: NSColor(srgbRed: 0.26, green: 0.13, blue: 0.18, alpha: 1), ending: NSColor(srgbRed: 0.10, green: 0.06, blue: 0.08, alpha: 1))!.draw(in: tile, angle: -70)
        NSColor(srgbRed: 0.79, green: 0.42, blue: 0.38, alpha: 0.5).setStroke()
        tile.lineWidth = 3; tile.stroke()
        let n = NSBezierPath()
        n.move(to: NSPoint(x: 316, y: 310)); n.line(to: NSPoint(x: 316, y: 660))
        n.curve(to: NSPoint(x: 708, y: 310), controlPoint1: NSPoint(x: 450, y: 660), controlPoint2: NSPoint(x: 573, y: 310))
        n.line(to: NSPoint(x: 708, y: 710))
        NSColor(srgbRed: 0.98, green: 0.95, blue: 0.92, alpha: 1).setStroke()
        n.lineWidth = 72; n.lineCapStyle = .round; n.lineJoinStyle = .round; n.stroke()
        NSColor(srgbRed: 0.79, green: 0.42, blue: 0.38, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 659, y: 661, width: 98, height: 98)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let file = "Noct-\(size)@\(scale)x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(file))
        entries.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": file])
    }
}
let contents: [String: Any] = ["images": entries, "info": ["author": "Noct Desktop", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("Contents.json"))
