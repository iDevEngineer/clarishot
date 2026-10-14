import AppKit
import CoreImage

/// Soft multi-colour "mesh" backgrounds: a base colour with blurred glows of other colours.
/// Each is drawn once into a small picture, blurred, cached, then stretched to fill.
enum MeshBackground {
    /// One glow: centre (0…1, top-left origin), radius as a fraction of the longer side, colour.
    struct Glow {
        let x, y, r: CGFloat
        let color: NSColor
        init(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ l: Double, _ c: Double, _ h: Double) {
            self.x = x; self.y = y; self.r = r
            color = NSColor(oklch: l, c, h)
        }
    }

    struct Design {
        let base: NSColor
        let glows: [Glow]
        init(_ l: Double, _ c: Double, _ h: Double, _ glows: [Glow]) {
            base = NSColor(oklch: l, c, h)
            self.glows = glows
        }
    }

    /// Twenty designs, in sidebar order (the first ten show before "Show more").
    static let designs: [Design] = [
        // Row 1
        Design(0.72, 0.10, 350, [Glow(0.1, 0.1, 0.6, 0.55, 0.16, 300), Glow(0.9, 0.2, 0.5, 0.78, 0.10, 330),
                                Glow(0.7, 0.95, 0.6, 0.80, 0.12, 55)]),                        // pink haze, orange glow
        Design(0.52, 0.20, 285, [Glow(0.2, 0.2, 0.6, 0.45, 0.20, 275), Glow(0.85, 0.85, 0.55, 0.70, 0.15, 340),
                                Glow(0.5, 0.5, 0.4, 0.62, 0.18, 300)]),                        // indigo, pink corner
        Design(0.28, 0.12, 270, [Glow(0.55, 0.55, 0.55, 0.55, 0.16, 265), Glow(0.15, 0.85, 0.5, 0.30, 0.14, 300),
                                Glow(0.9, 0.1, 0.4, 0.22, 0.08, 260)]),                        // deep navy, blue core
        Design(0.82, 0.07, 175, [Glow(0.2, 0.2, 0.6, 0.88, 0.06, 160), Glow(0.85, 0.9, 0.55, 0.62, 0.11, 240),
                                Glow(0.75, 0.3, 0.4, 0.80, 0.08, 200)]),                       // mint to blue
        Design(0.74, 0.13, 30, [Glow(0.2, 0.3, 0.6, 0.70, 0.15, 10), Glow(0.85, 0.8, 0.6, 0.82, 0.12, 60),
                               Glow(0.5, 0.95, 0.4, 0.72, 0.12, 350)]),                        // coral, peach
        // Row 2
        Design(0.62, 0.17, 290, [Glow(0.15, 0.85, 0.5, 0.75, 0.13, 345), Glow(0.8, 0.2, 0.55, 0.55, 0.18, 265),
                                Glow(0.5, 0.5, 0.35, 0.82, 0.06, 280)]),                       // violet swirl, pink
        Design(0.90, 0.005, 260, [Glow(0.3, 0.3, 0.6, 0.96, 0.004, 260), Glow(0.85, 0.85, 0.6, 0.82, 0.01, 250),
                                 Glow(0.1, 0.9, 0.4, 0.86, 0.008, 300)]),                      // silver
        Design(0.82, 0.015, 60, [Glow(0.3, 0.25, 0.6, 0.90, 0.01, 70), Glow(0.85, 0.85, 0.55, 0.74, 0.02, 40),
                                Glow(0.1, 0.9, 0.4, 0.80, 0.02, 20)]),                         // warm grey
        Design(0.75, 0.10, 275, [Glow(0.3, 0.7, 0.55, 0.92, 0.03, 260), Glow(0.85, 0.15, 0.55, 0.62, 0.15, 265),
                                Glow(0.1, 0.1, 0.4, 0.70, 0.12, 300)]),                        // periwinkle, white
        Design(0.16, 0.06, 275, [Glow(0.7, 0.75, 0.55, 0.32, 0.16, 290), Glow(0.2, 0.2, 0.5, 0.12, 0.04, 260),
                                Glow(0.9, 0.2, 0.35, 0.25, 0.10, 270)]),                       // midnight, purple glow
        // Row 3
        Design(0.70, 0.08, 255, [Glow(0.5, 0.0, 0.7, 0.55, 0.12, 260), Glow(0.4, 1.0, 0.7, 0.86, 0.08, 55),
                                Glow(0.9, 0.7, 0.4, 0.80, 0.07, 20)]),                         // blue sky to peach
        Design(0.80, 0.07, 290, [Glow(0.2, 0.2, 0.6, 0.86, 0.05, 260), Glow(0.85, 0.8, 0.6, 0.74, 0.10, 310),
                                Glow(0.5, 0.5, 0.4, 0.90, 0.03, 300)]),                        // lavender
        Design(0.70, 0.12, 300, [Glow(0.1, 0.35, 0.45, 0.88, 0.04, 300), Glow(0.6, 0.6, 0.45, 0.58, 0.17, 295),
                                Glow(0.95, 0.15, 0.45, 0.82, 0.08, 330)]),                     // lilac wave
        Design(0.32, 0.06, 30, [Glow(0.25, 0.3, 0.55, 0.40, 0.09, 20), Glow(0.8, 0.8, 0.55, 0.22, 0.05, 330),
                               Glow(0.8, 0.15, 0.35, 0.48, 0.10, 50)]),                        // dark cocoa
        Design(0.18, 0.08, 270, [Glow(0.75, 0.7, 0.45, 0.48, 0.20, 0), Glow(0.4, 0.4, 0.45, 0.30, 0.15, 290),
                                Glow(0.1, 0.9, 0.4, 0.20, 0.10, 260)]),                        // navy, red glow
        // Row 4
        Design(0.75, 0.12, 310, [Glow(0.15, 0.15, 0.5, 0.70, 0.14, 270), Glow(0.85, 0.85, 0.55, 0.80, 0.12, 0),
                                Glow(0.5, 0.6, 0.4, 0.84, 0.07, 300)]),                        // lilac, pink, blue
        Design(0.62, 0.20, 25, [Glow(0.2, 0.25, 0.55, 0.55, 0.22, 15), Glow(0.8, 0.75, 0.55, 0.78, 0.16, 60),
                               Glow(0.6, 0.15, 0.4, 0.68, 0.18, 350)]),                        // fiery red-orange
        Design(0.78, 0.10, 250, [Glow(0.2, 0.2, 0.5, 0.62, 0.14, 260), Glow(0.7, 0.75, 0.5, 0.84, 0.15, 75),
                                Glow(0.9, 0.3, 0.4, 0.76, 0.14, 40)]),                         // blue, orange, yellow
        Design(0.22, 0.06, 280, [Glow(0.25, 0.7, 0.4, 0.62, 0.20, 40), Glow(0.7, 0.4, 0.4, 0.55, 0.20, 10),
                                Glow(0.8, 0.85, 0.35, 0.50, 0.15, 255), Glow(0.4, 0.2, 0.3, 0.70, 0.14, 350)]), // dark, mixed glows
        Design(0.74, 0.11, 10, [Glow(0.2, 0.2, 0.55, 0.72, 0.15, 20), Glow(0.85, 0.8, 0.55, 0.76, 0.10, 300),
                               Glow(0.6, 0.4, 0.4, 0.82, 0.08, 40)])                           // coral, lavender
    ]

    @MainActor private static var cache: [Int: CGImage] = [:]

    /// The design rendered and blurred (small; it's smooth, so stretching looks fine).
    @MainActor
    static func image(_ index: Int) -> CGImage? {
        let i = min(max(index, 0), designs.count - 1)
        if let cached = cache[i] { return cached }
        let design = designs[i]
        let size = CGSize(width: 480, height: 320)
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(design.base.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        let longest = max(size.width, size.height)
        for glow in design.glows {
            let center = CGPoint(x: glow.x * size.width, y: (1 - glow.y) * size.height)
            let colors = [glow.color.cgColor, glow.color.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { continue }
            ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                   endRadius: glow.r * longest, options: [])
        }
        guard let raw = ctx.makeImage() else { return nil }
        let input = CIImage(cgImage: raw)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 22).cropped(to: input.extent)
        guard let result = CIContext(options: [.workingColorSpace: space]).createCGImage(blurred, from: input.extent,
                                                                                         format: .RGBA8, colorSpace: space)
        else { return raw }
        cache[i] = result
        return result
    }
}
