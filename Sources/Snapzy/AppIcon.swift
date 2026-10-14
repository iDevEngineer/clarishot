import AppKit

/// Snapzy's icon, drawn in code: a viewfinder on a blue-to-violet rounded square.
/// Set as the app icon at launch, so alerts and panels show it.
@MainActor
enum AppIcon {
    static func make(size: CGFloat = 512) -> NSImage {
        NSImage(size: CGSize(width: size, height: size), flipped: false) { rect in
            // macOS icon grid: the tile sits inside ~10% margins.
            let tile = rect.insetBy(dx: size * 0.1, dy: size * 0.1)
            let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
            NSGraphicsContext.current?.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = size * 0.03
            shadow.shadowOffset = CGSize(width: 0, height: -size * 0.012)
            shadow.set()
            NSGradient(colors: [NSColor(srgbRed: 0.24, green: 0.52, blue: 1, alpha: 1),
                                NSColor(srgbRed: 0.53, green: 0.30, blue: 0.98, alpha: 1)])?
                .draw(in: path, angle: -60)
            NSGraphicsContext.current?.restoreGraphicsState()

            let config = NSImage.SymbolConfiguration(pointSize: tile.width * 0.5, weight: .medium)
                .applying(.init(paletteColors: [.white]))
            if let symbol = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let s = symbol.size
                symbol.draw(in: CGRect(x: tile.midX - s.width / 2, y: tile.midY - s.height / 2,
                                       width: s.width, height: s.height))
            }
            return true
        }
    }

    /// The PNG sizes macOS expects in an .iconset folder.
    static func writeIconset(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = base * scale
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                make(size: CGFloat(pixels)).draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
                NSGraphicsContext.restoreGraphicsState()
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
            }
        }
    }
}
