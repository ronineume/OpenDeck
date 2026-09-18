// Generates Resources/AppIcon.icns: a rounded gradient tile with a 3x3 app grid.
import AppKit
import Foundation

let sizes = [16, 32, 64, 128, 256, 512]
let outDir = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: outDir)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let inset = size * 0.06
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = size * 0.22

    // Backdrop with a vertical gradient.
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.24, green: 0.42, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.09, green: 0.16, blue: 0.48, alpha: 1),
    ])!
    gradient.draw(in: path, angle: -90)

    // A 3x3 grid of rounded "app" tiles.
    let cols = 3
    let pad = rect.width * 0.16
    let inner = rect.insetBy(dx: pad, dy: pad)
    let gap = inner.width * 0.10
    let tile = (inner.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
    let tileRadius = tile * 0.28

    for row in 0 ..< cols {
        for col in 0 ..< cols {
            let x = inner.minX + CGFloat(col) * (tile + gap)
            let y = inner.minY + CGFloat(row) * (tile + gap)
            let tileRect = NSRect(x: x, y: y, width: tile, height: tile)
            let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: tileRadius, yRadius: tileRadius)
            NSColor(calibratedWhite: 1.0, alpha: 0.92).setFill()
            tilePath.fill()
        }
    }

    return image
}

for size in sizes {
    for scale in [1, 2] {
        let pixel = size * scale
        let image = drawIcon(size: CGFloat(pixel))
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { continue }
        let suffix = scale == 1 ? "" : "@2x"
        let name = "icon_\(size)x\(size)\(suffix).png"
        try png.write(to: outDir.appendingPathComponent(name))
    }
}
print("iconset written to \(outDir.path)")
