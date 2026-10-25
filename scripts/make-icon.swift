import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform()
        transform.scale(by: factor)
        transform.concat()

        let base = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 196, yRadius: 196)
        let gradient = NSGradient(starting: NSColor(srgbRed: 0.10, green: 0.56, blue: 0.46, alpha: 1),
                                  ending: NSColor(srgbRed: 0.05, green: 0.34, blue: 0.29, alpha: 1))!
        gradient.draw(in: base, angle: -65)
        NSGraphicsContext.saveGraphicsState()
        base.addClip()
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(ovalIn: NSRect(x: 120, y: 400, width: 650, height: 650)).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Original geometric artwork; app branding does not embed a system glyph.
        func card(_ rect: NSRect, fill: NSColor, foreground: NSColor) {
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 65, yRadius: 65).fill()
            foreground.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - 47, y: rect.maxY - 144, width: 94, height: 94)).fill()
            NSBezierPath(roundedRect: NSRect(x: rect.midX - 84, y: rect.maxY - 234, width: 168, height: 67),
                         xRadius: 33, yRadius: 33).fill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX + 62, y: rect.minY + 67, width: rect.width - 124, height: 17),
                         xRadius: 8, yRadius: 8).fill()
        }
        card(NSRect(x: 445, y: 215, width: 345, height: 445),
             fill: NSColor.white.withAlphaComponent(0.35), foreground: NSColor.white.withAlphaComponent(0.8))
        card(NSRect(x: 235, y: 360, width: 345, height: 445),
             fill: NSColor.white, foreground: NSColor(srgbRed: 0.08, green: 0.45, blue: 0.37, alpha: 1))
        image.unlockFocus()

        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        let path = directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: path)
    }
}
