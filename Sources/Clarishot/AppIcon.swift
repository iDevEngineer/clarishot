import AppKit

/// Clarishot's icon, drawn in code: a viewfinder on a blue-to-violet rounded square.
/// Set as the app icon at launch, so alerts and panels show it.
@MainActor
enum AppIcon {
    /// The bundled icon (from Resources/Brand) if there is one, otherwise the drawn fallback.
    static var current: NSImage {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: url) {
            return image
        }
        return make()
    }

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

    /// Single-colour menu-bar version: viewfinder corners around a shutter, like the app icon.
    /// A template image, so macOS tints it for light and dark menu bars.
    static func menuBar() -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: CGSize(width: size, height: size), flipped: false) { rect in
            NSColor.black.set()
            let inset: CGFloat = 1.5, arm: CGFloat = 4.5
            let r = rect.insetBy(dx: inset, dy: inset)
            let corners = NSBezierPath()
            corners.lineWidth = 1.6
            corners.lineCapStyle = .round
            corners.lineJoinStyle = .round
            for (x, y, dx, dy) in [(r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0),
                                   (r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0)] {
                corners.move(to: CGPoint(x: x, y: y + dy * arm))
                corners.line(to: CGPoint(x: x, y: y))
                corners.line(to: CGPoint(x: x + dx * arm, y: y))
            }
            corners.stroke()
            let config = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .semibold)
            if let shutter = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let s = shutter.size
                shutter.draw(in: CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2,
                                        width: s.width, height: s.height))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Clarishot"
        return image
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
