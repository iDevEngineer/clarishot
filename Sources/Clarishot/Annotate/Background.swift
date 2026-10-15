import AppKit
import ScreenCaptureKit

/// What fills the space around the screenshot.
enum BackgroundFill {
    case gradient(NSColor, NSColor)
    case solid(NSColor)
    case wallpaper
    /// A picture file chosen by the user.
    case picture(URL)
    /// The wallpaper, blurred: 0 soft, 1 frosted dark, 2 dim.
    case blurredWallpaper(Int)
    /// One of the soft multi-colour designs in `MeshBackground`.
    case mesh(Int)

    /// The sidebar's gradients, defined in OKLCH (the first ten show before "Show more").
    static let gradients: [(NSColor, NSColor)] = [
        (NSColor(oklch: 0.70, 0.17, 10), NSColor(oklch: 0.84, 0.13, 65)),
        (NSColor(oklch: 0.60, 0.20, 270), NSColor(oklch: 0.62, 0.22, 310)),
        (NSColor(oklch: 0.77, 0.13, 185), NSColor(oklch: 0.58, 0.19, 262)),
        (NSColor(oklch: 0.84, 0.18, 135), NSColor(oklch: 0.62, 0.12, 175)),
        (NSColor(oklch: 0.90, 0.15, 95), NSColor(oklch: 0.73, 0.17, 50)),
        (NSColor(oklch: 0.30, 0.10, 280), NSColor(oklch: 0.55, 0.20, 330)),
        (NSColor(oklch: 0.82, 0.08, 230), NSColor(oklch: 0.92, 0.05, 330)),
        (NSColor(oklch: 0.65, 0.20, 20), NSColor(oklch: 0.45, 0.17, 300)),
        (NSColor(oklch: 0.88, 0.10, 160), NSColor(oklch: 0.75, 0.12, 230)),
        (NSColor(oklch: 0.27, 0.02, 265), NSColor(oklch: 0.48, 0.03, 265)),
        (NSColor(oklch: 0.20, 0.08, 270), NSColor(oklch: 0.40, 0.18, 290)),
        (NSColor(oklch: 0.78, 0.15, 75), NSColor(oklch: 0.62, 0.22, 25)),
        (NSColor(oklch: 0.70, 0.15, 330), NSColor(oklch: 0.80, 0.12, 250)),
        (NSColor(oklch: 0.60, 0.13, 160), NSColor(oklch: 0.35, 0.08, 220)),
        (NSColor(oklch: 0.93, 0.03, 85), NSColor(oklch: 0.82, 0.05, 60))
    ]

    /// Plain colours, defined in OKLCH: a dark-to-light row, then soft tints.
    static let plainColors: [NSColor] = [
        NSColor(oklch: 0.16, 0, 0), NSColor(oklch: 1, 0, 0), NSColor(oklch: 0.58, 0.17, 25), NSColor(oklch: 0.70, 0.14, 60),
        NSColor(oklch: 0.80, 0.14, 90), NSColor(oklch: 0.62, 0.12, 150), NSColor(oklch: 0.62, 0.14, 258),
        NSColor(oklch: 0.55, 0.22, 295),
        NSColor(oklch: 0.30, 0, 0), NSColor(oklch: 0.93, 0, 0), NSColor(oklch: 0.85, 0.05, 30), NSColor(oklch: 0.88, 0.07, 75),
        NSColor(oklch: 0.94, 0.07, 100), NSColor(oklch: 0.90, 0.06, 150), NSColor(oklch: 0.88, 0.05, 250),
        NSColor(oklch: 0.85, 0.07, 300)
    ]

    /// Aspect-fills an image into `rect`.
    @MainActor
    private static func drawFilled(_ image: CGImage, _ rect: CGRect, _ ctx: CGContext, flipped: Bool) {
        let size = CGSize(width: image.width, height: image.height)
        let scale = max(rect.width / size.width, rect.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let target = CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height)
        ctx.saveGState()
        ctx.clip(to: rect)
        if flipped { AnnotationRenderer.drawImage(image, in: target, ctx: ctx) } else { ctx.draw(image, in: target) }
        ctx.restoreGState()
    }

    @MainActor private static var pictureCache: [URL: CGImage] = [:]
    @MainActor private static var blurCache: [Int: (generation: Int, result: CGImage)] = [:]

    @MainActor
    static func pictureImage(_ url: URL) -> CGImage? {
        MemoryTrim.soon { pictureCache.removeAll() }
        if let cached = pictureCache[url] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 3000,
                                                                          kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        pictureCache[url] = image
        return image
    }

    /// The wallpaper blurred (and for 1 and 2, darkened), cached until the wallpaper changes.
    @MainActor
    static func blurredWallpaper(_ variant: Int) -> CGImage? {
        guard let wallpaper = Wallpaper.image else { return nil }
        if let cached = blurCache[variant], cached.generation == Wallpaper.generation { return cached.result }
        let small = min(1, 1200 / CGFloat(max(wallpaper.width, wallpaper.height)))
        var input = CIImage(cgImage: wallpaper).transformed(by: .init(scaleX: small, y: small))
        let extent = input.extent
        input = input.clampedToExtent().applyingGaussianBlur(sigma: variant == 0 ? 18 : 28).cropped(to: extent)
        if variant > 0 {
            input = input.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: variant == 1 ? -0.12 : -0.3,
                                                                       kCIInputSaturationKey: variant == 1 ? 1.1 : 0.7])
        }
        guard let result = CIContext().createCGImage(input, from: extent) else { return nil }
        blurCache[variant] = (Wallpaper.generation, result)
        return result
    }

    /// Defined in OKLCH (lightness, chroma, hue) and drawn in Display P3.
    static let presets: [BackgroundFill] = [
        .gradient(NSColor(oklch: 0.70, 0.17, 10), NSColor(oklch: 0.84, 0.13, 65)),    // pink → peach
        .gradient(NSColor(oklch: 0.60, 0.20, 270), NSColor(oklch: 0.62, 0.22, 310)),  // blue → violet
        .gradient(NSColor(oklch: 0.77, 0.13, 185), NSColor(oklch: 0.58, 0.19, 262)),  // teal → blue
        .gradient(NSColor(oklch: 0.84, 0.18, 135), NSColor(oklch: 0.62, 0.12, 175)),  // green → teal
        .gradient(NSColor(oklch: 0.90, 0.15, 95), NSColor(oklch: 0.73, 0.17, 50)),    // yellow → orange
        .gradient(NSColor(oklch: 0.27, 0.02, 265), NSColor(oklch: 0.48, 0.03, 265)),  // slate
        .solid(NSColor(oklch: 0.96, 0.003, 265)),                                     // light
        .solid(NSColor(oklch: 0.19, 0.004, 265)),                                     // dark
        .wallpaper
    ]

    /// Fills `rect` in the given context (any orientation).
    @MainActor
    func fill(_ rect: CGRect, in ctx: CGContext, flipped: Bool) {
        switch self {
        case .solid(let color):
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)
        case .gradient(let a, let b):
            let colors = [a.cgColor, b.cgColor] as CFArray
            // Display P3 so wide-gamut custom colours keep their vividness.
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.displayP3), colors: colors, locations: [0, 1])
            else { return }
            let top = flipped ? rect.minY : rect.maxY
            let bottom = flipped ? rect.maxY : rect.minY
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: top), end: CGPoint(x: rect.maxX, y: bottom), options: [])
            ctx.restoreGState()
        case .picture(let url):
            guard let image = Self.pictureImage(url) else { return BackgroundFill.presets[1].fill(rect, in: ctx, flipped: flipped) }
            Self.drawFilled(image, rect, ctx, flipped: flipped)
        case .mesh(let index):
            guard let image = MeshBackground.image(index) else { return }
            Self.drawFilled(image, rect, ctx, flipped: flipped)
        case .blurredWallpaper(let variant):
            guard let image = Self.blurredWallpaper(variant) else { return BackgroundFill.presets[5].fill(rect, in: ctx, flipped: flipped) }
            Self.drawFilled(image, rect, ctx, flipped: flipped)
        case .wallpaper:
            guard let image = Wallpaper.image else {
                BackgroundFill.presets[1].fill(rect, in: ctx, flipped: flipped)
                return
            }
            // Aspect-fill the wallpaper into the rect.
            let size = CGSize(width: image.width, height: image.height)
            let scale = max(rect.width / size.width, rect.height / size.height)
            let drawn = CGSize(width: size.width * scale, height: size.height * scale)
            let target = CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                                width: drawn.width, height: drawn.height)
            ctx.saveGState()
            ctx.clip(to: rect)
            if flipped {
                AnnotationRenderer.drawImage(image, in: target, ctx: ctx)
            } else {
                ctx.draw(image, in: target)
            }
            ctx.restoreGState()
        }
    }
}

/// The wallpaper picture: the custom one from Settings, else what's actually on the desktop.
///
/// macOS's "desktop picture URL" is often stale or a default for dynamic and moving
/// wallpapers, so Clarishot captures the live wallpaper from the screen instead and keeps it
/// up to date when you switch Spaces or displays change. The file URL is only a fallback.
@MainActor
enum Wallpaper {
    private static var fileCache: (url: URL, image: CGImage)?
    /// The live wallpaper per display, kept compressed (a few MB instead of ~20 MB per Retina
    /// screen). It's decoded when needed and the decoded copy is dropped after a short idle spell.
    private static var live: [CGDirectDisplayID: Data] = [:]
    private static var decoded: [CGDirectDisplayID: CGImage] = [:]
    /// Goes up whenever the wallpaper changes, so caches built from it know to rebuild.
    private(set) static var generation = 0
    private static var observers: [NSObjectProtocol] = []

    /// Starts keeping the live wallpaper up to date. Call once at launch.
    static func startWatching() {
        guard observers.isEmpty else { return }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if Settings.shared.wallpaperFollowsSpaces { refreshSoon() } }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { refreshSoon() }
        })
        Task { await refresh() }
    }

    /// Waits for the Space switch animation to finish, then captures the wallpaper again.
    private static func refreshSoon() {
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            await refresh()
        }
    }

    /// Captures the wallpaper (only the desktop picture, no windows or icons) on every display.
    static func refresh() async {
        guard Settings.shared.customWallpaper == nil,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return }
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let belowIcons = content.windows.filter { $0.windowLayer < iconLevel }
        // Only the windows that draw the picture. The Dock also keeps an invisible "Fullscreen
        // Backdrop" above it that captures as solid black, so it must be left out.
        let wallpapers = belowIcons.filter {
            ($0.title ?? "").hasPrefix("Wallpaper") || $0.owningApplication?.bundleIdentifier == "com.apple.wallpaper.agent"
        }
        let pictures = wallpapers.isEmpty ? belowIcons.filter { $0.title != "Fullscreen Backdrop" } : wallpapers
        for screen in NSScreen.screens {
            let id = ScreenCapturer.displayID(for: screen)
            guard let display = content.displays.first(where: { $0.displayID == id }), !pictures.isEmpty else { continue }
            let filter = SCContentFilter(display: display, including: pictures)
            let config = SCStreamConfiguration()
            config.width = Int(CGFloat(display.width) * screen.backingScaleFactor)
            config.height = Int(CGFloat(display.height) * screen.backingScaleFactor)
            config.showsCursor = false
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
               let data = compress(image) {
                live[id] = data
                decoded[id] = nil
                generation += 1
            }
        }
    }

    /// HEIC at high quality: visually the same for a background, a fraction of the memory.
    private static func compress(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func url(for screen: NSScreen? = NSScreen.main) -> URL? {
        if let custom = Settings.shared.customWallpaper { return custom }
        guard let screen else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: screen)
    }

    static func image(for screen: NSScreen? = NSScreen.main) -> CGImage? {
        MemoryTrim.soon { decoded.removeAll(); fileCache = nil }
        if Settings.shared.customWallpaper == nil, let screen {
            let id = ScreenCapturer.displayID(for: screen)
            if let image = decoded[id] { return image }
            if let data = live[id], let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
                decoded[id] = image
                return image
            }
        }
        guard let url = url(for: screen) else { return nil }
        if let fileCache, fileCache.url == url { return fileCache.image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceThumbnailMaxPixelSize: 2400] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        fileCache = (url, image)
        return image
    }

    static var image: CGImage? { image() }
}

struct BackgroundStyle: Codable, Equatable {
    var enabled = false
    var fillIndex = 0
    // A new background starts with nothing set: no padding, square corners, no shadow.
    var padding: CGFloat = 0       // points
    var cornerRadius: CGFloat = 0  // points
    var shadow = false
    /// Index into `aspects`: 0 = fit the screenshot, otherwise a fixed shape.
    var aspect = 0

    static let aspects: [(title: String, ratio: CGFloat?)] = [
        ("Auto", nil), ("1:1 Square", 1), ("4:3", 4.0 / 3), ("16:9", 16.0 / 9), ("9:16 Portrait", 9.0 / 16)
    ]

    /// Custom colours chosen with the OKLCH picker (saved as P3); used when `fillIndex` is -1.
    var customFrom: String?
    var customTo: String?
    /// Sidebar choice, overriding the older fields: "gradient:N", "solid:<P3>", "wallpaper",
    /// "picture:<path>", "blur:N" or "mesh:N".
    var fillSpec: String?
    /// Border of the screenshot's own edge colour around it, in points.
    var inset: CGFloat?
    /// Shadow strength 0…1 (older styles: `shadow` on = 0.5).
    var shadowAmount: CGFloat?
    /// Where the screenshot sits when the ratio leaves extra space: 0…8, left-to-right, top-to-bottom (4 = centre).
    var alignment: Int?
    /// Centre the screenshot's visible content, ignoring empty single-colour space at its edges.
    var autoBalance: Bool?

    var effectiveInset: CGFloat { inset ?? 0 }
    var effectiveShadow: CGFloat { shadowAmount ?? (shadow ? 0.5 : 0) }

    var fill: BackgroundFill {
        if let spec = fillSpec {
            let parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            switch parts.first {
            case "gradient":
                let i = Int(parts.last ?? "") ?? 0
                let g = BackgroundFill.gradients[min(max(i, 0), BackgroundFill.gradients.count - 1)]
                return .gradient(g.0, g.1)
            case "solid": return .solid(NSColor(saved: parts.last ?? "") ?? .white)
            case "wallpaper": return .wallpaper
            case "picture": return .picture(URL(fileURLWithPath: parts.last ?? ""))
            case "blur": return .blurredWallpaper(Int(parts.last ?? "") ?? 0)
            case "mesh": return .mesh(Int(parts.last ?? "") ?? 0)
            default: break
            }
        }
        if fillIndex < 0 {
            let from = customFrom.flatMap(NSColor.init(saved:)) ?? .systemIndigo
            let to = customTo.flatMap(NSColor.init(saved:)) ?? from
            return from == to ? .solid(from) : .gradient(from, to)
        }
        return BackgroundFill.presets[min(max(fillIndex, 0), BackgroundFill.presets.count - 1)]
    }

    /// Space left and right (width) and above and below (height) the content,
    /// widened on one side if needed to reach the chosen aspect ratio.
    /// The whole canvas, and where the screenshot's top-left goes in it (points, top-left origin).
    /// `content` is the screenshot; inset and padding go around it, and any extra room from the
    /// ratio is shared out according to `alignment`.
    func layout(for content: CGSize, balance: CGVector = .zero) -> (canvas: CGSize, origin: CGPoint) {
        let framed = CGSize(width: content.width + 2 * effectiveInset, height: content.height + 2 * effectiveInset)
        var w = framed.width + 2 * padding, h = framed.height + 2 * padding
        if let ratio = Self.aspects[min(max(aspect, 0), Self.aspects.count - 1)].ratio {
            if w / h < ratio { w = h * ratio } else { h = w / ratio }
        }
        let a = min(max(alignment ?? 4, 0), 8)
        let fx = CGFloat(a % 3) / 2, fy = CGFloat(a / 3) / 2
        // Centre keeps padding even on every side. Any other choice pushes the screenshot flush
        // against that edge or corner, the way a window peeks in from the side.
        let spareX = w - framed.width, spareY = h - framed.height
        // Auto-balance nudges the screenshot so its content, not its rectangle, sits where chosen,
        // without letting it leave the background.
        let x = min(max(spareX * fx + balance.dx, 0), spareX)
        let y = min(max(spareY * fy + balance.dy, 0), spareY)
        return (CGSize(width: w, height: h), CGPoint(x: x + effectiveInset, y: y + effectiveInset))
    }

    func insets(for content: CGSize) -> CGSize {
        var w = content.width + 2 * padding, h = content.height + 2 * padding
        if let ratio = Self.aspects[min(max(aspect, 0), Self.aspects.count - 1)].ratio {
            if w / h < ratio { w = h * ratio } else { h = w / ratio }
        }
        return CGSize(width: (w - content.width) / 2, height: (h - content.height) / 2)
    }
}

/// Saved background styles, by name.
@MainActor
enum BackgroundPresets {
    private static let key = "backgroundPresets"

    static var all: [(name: String, style: BackgroundStyle)] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: BackgroundStyle].self, from: data) else { return [] }
        return dict.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }.map { ($0.key, $0.value) }
    }

    static func style(named name: String) -> BackgroundStyle? { all.first { $0.name == name }?.style }

    static func save(_ style: BackgroundStyle, as name: String) {
        var dict = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0.style) })
        var s = style
        s.enabled = true
        dict[name] = s
        if let data = try? JSONEncoder().encode(dict) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func delete(_ name: String) {
        var dict = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0.style) })
        dict[name] = nil
        if let data = try? JSONEncoder().encode(dict) { UserDefaults.standard.set(data, forKey: key) }
        if Settings.shared.autoBackgroundPreset == name { Settings.shared.autoBackgroundPreset = nil }
    }
}

enum BackgroundRenderer {
    /// Window captures: adds a soft shadow (following the window's rounded shape),
    /// optionally on the wallpaper. Returns nil for "transparent".
    @MainActor
    static func frameWindow(_ image: CGImage, scale: CGFloat, style: Settings.WindowStyle) -> CGImage? {
        guard style != .transparent else { return nil }
        let pad = Int(((style == .background ? CGFloat(Settings.shared.windowPadding) : 40) * scale).rounded())
        let width = image.width + 2 * pad, height = image.height + 2 * pad
        guard let ctx = AnnotationRenderer.makeContext(width: width, height: height, like: image) else { return nil }
        if style == .background {
            BackgroundFill.wallpaper.fill(CGRect(x: 0, y: 0, width: width, height: height), in: ctx, flipped: false)
        }
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 36 * scale,
                      color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.draw(image, in: CGRect(x: pad, y: pad, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// Places the flattened screenshot on the background at full resolution.
    @MainActor
    static func compose(_ image: CGImage, scale: CGFloat, style: BackgroundStyle) -> CGImage? {
        let content = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let balance = style.autoBalance == true
            ? ContentBalance.offset(for: image, crop: CGRect(origin: .zero, size: content), pointSize: content) : .zero
        let layout = style.layout(for: content, balance: balance)
        let width = Int((layout.canvas.width * scale).rounded()), height = Int((layout.canvas.height * scale).rounded())
        guard let ctx = AnnotationRenderer.makeContext(width: width, height: height, like: image) else { return nil }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        // Bottom-left origin here, so flip the top-left layout position.
        let x = (layout.origin.x * scale).rounded()
        let y = CGFloat(height) - (layout.origin.y * scale).rounded() - CGFloat(image.height)
        let imageRect = CGRect(x: x, y: y, width: CGFloat(image.width), height: CGFloat(image.height))
        style.fill.fill(full, in: ctx, flipped: false)
        drawFramedImage(image, in: imageRect, radius: style.cornerRadius * scale, shadow: style.effectiveShadow,
                        inset: style.effectiveInset * scale, shadowScale: scale, ctx: ctx, flipped: false)
        return ctx.makeImage()
    }

    /// The screenshot's edge colour (its top-left pixel), used to fill the inset border.
    static func edgeColor(of image: CGImage) -> CGColor {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let corner = image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)) else { return NSColor.white.cgColor }
        ctx.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return CGColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }

    /// Draws the image with rounded corners and an optional soft shadow.
    /// Draws the screenshot with rounded corners, an optional edge-coloured inset border around it,
    /// and a soft shadow of the given strength (0 = none).
    static func drawFramedImage(_ image: CGImage, in rect: CGRect, radius: CGFloat, shadow: CGFloat, inset: CGFloat = 0,
                                shadowScale: CGFloat, ctx: CGContext, flipped: Bool) {
        let outer = rect.insetBy(dx: -inset, dy: -inset)
        let r = min(radius, outer.width / 2, outer.height / 2)
        let path = CGPath(roundedRect: outer, cornerWidth: r, cornerHeight: r, transform: nil)
        if shadow > 0 {
            ctx.saveGState()
            let dy = -8 * shadowScale * (0.5 + shadow) // shadow offsets ignore the flip: negative is always down
            ctx.setShadow(offset: CGSize(width: 0, height: dy), blur: 40 * shadowScale * shadow + 6 * shadowScale,
                          color: NSColor.black.withAlphaComponent(0.15 + 0.5 * shadow).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if inset > 0 {
            ctx.setFillColor(edgeColor(of: image))
            ctx.fill(outer)
        }
        if flipped {
            AnnotationRenderer.drawImage(image, in: rect, ctx: ctx)
        } else {
            ctx.draw(image, in: rect)
        }
        ctx.restoreGState()
    }
}

/// Popover with the background options.
@MainActor
final class BackgroundViewController: NSViewController {
    private var style: BackgroundStyle
    private let onChange: (BackgroundStyle) -> Void
    private var swatches: [FillSwatch] = []
    private let toggle = NSSwitch()

    init(style: BackgroundStyle, onChange: @escaping (BackgroundStyle) -> Void) {
        self.style = style
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        view = makeView()
    }

    /// Rebuilt when a preset is applied so every control shows the new values.
    private func makeView() -> NSView {
        toggle.state = style.enabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggled(_:))
        let header = NSStackView(views: [label("Background", bold: true), NSView(), toggle])

        swatches = BackgroundFill.presets.indices.map { index in
            let swatch = FillSwatch(fill: BackgroundFill.presets[index])
            swatch.isSelected = index == style.fillIndex
            swatch.onClick = { [weak self] in self?.pickFill(index) }
            return swatch
        }
        let row1 = NSStackView(views: Array(swatches.prefix(5)))
        let row2 = NSStackView(views: Array(swatches.dropFirst(5)))
        for row in [row1, row2] { row.spacing = 6 }
        // Custom: any two colours (or the same one twice for a solid) from the OKLCH picker.
        let from = OklchColorButton(color: style.customFrom.flatMap(NSColor.init(saved:)) ?? .systemIndigo,
                                    size: CGSize(width: 36, height: 22))
        let to = OklchColorButton(color: style.customTo.flatMap(NSColor.init(saved:)) ?? .systemPink,
                                  size: CGSize(width: 36, height: 22))
        from.onChange = { [weak self, weak to] color in self?.pickCustom(from: color, to: to?.color) }
        to.onChange = { [weak self, weak from] color in self?.pickCustom(from: from?.color, to: color) }
        let customLabel = label("Custom")
        let arrow = NSImageView(image: NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil) ?? NSImage())
        arrow.contentTintColor = .tertiaryLabelColor
        let row3 = NSStackView(views: [customLabel, from, arrow, to])
        row3.spacing = 6
        let grid = NSStackView(views: [row1, row2, row3])
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 6

        let padding = slider(value: style.padding, max: 200, action: #selector(paddingChanged(_:)))
        let radius = slider(value: style.cornerRadius, max: 40, action: #selector(radiusChanged(_:)))
        let shadow = NSButton(checkboxWithTitle: "Shadow", target: self, action: #selector(shadowToggled(_:)))
        shadow.state = style.shadow ? .on : .off
        let aspect = NSPopUpButton(frame: .zero, pullsDown: false)
        aspect.addItems(withTitles: BackgroundStyle.aspects.map(\.title))
        aspect.selectItem(at: style.aspect)
        aspect.target = self
        aspect.action = #selector(aspectChanged(_:))
        let presets = NSButton(title: "Presets ▾", target: self, action: #selector(showPresets(_:)))
        presets.bezelStyle = .rounded

        let stack = NSStackView(views: [header, grid,
                                        row(label("Padding"), padding),
                                        row(label("Corners"), radius),
                                        row(label("Shape"), aspect),
                                        NSStackView(views: [shadow, NSView(), presets])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalToConstant: 232).isActive = true
        if let last = stack.views.last {
            last.translatesAutoresizingMaskIntoConstraints = false
            last.widthAnchor.constraint(equalToConstant: 232).isActive = true
        }
        return stack
    }

    @objc private func aspectChanged(_ sender: NSPopUpButton) {
        update { $0.aspect = sender.indexOfSelectedItem; $0.enabled = true }
        toggle.state = .on
    }

    @objc private func showPresets(_ sender: NSButton) {
        let menu = NSMenu()
        let saved = BackgroundPresets.all
        for preset in saved {
            menu.addItem(ClosureMenuItem(title: preset.name) { [weak self] in
                guard let self else { return }
                self.style = preset.style
                self.onChange(self.style)
                self.view = self.makeView()
            })
        }
        if !saved.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem(title: "Save Current as Preset…") { [weak self] in self?.savePreset() })
        if !saved.isEmpty {
            let delete = NSMenuItem(title: "Delete Preset", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for preset in saved { sub.addItem(ClosureMenuItem(title: preset.name) { BackgroundPresets.delete(preset.name) }) }
            delete.submenu = sub
            menu.addItem(delete)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    private func savePreset() {
        let alert = NSAlert()
        alert.messageText = "Save background preset"
        alert.informativeText = "Name this style so you can reuse it, or apply it to every screenshot in Preferences → Screenshots."
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "e.g. Blog post"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        BackgroundPresets.save(style, as: name)
        Toast.show("Saved preset “\(name)”")
    }

    private func label(_ text: String, bold: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = bold ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 12)
        if !bold { field.textColor = .secondaryLabelColor }
        return field
    }

    private func slider(value: CGFloat, max: Double, action: Selector) -> NSSlider {
        let slider = NSSlider(value: Double(value), minValue: 0, maxValue: max, target: self, action: action)
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        return slider
    }

    private func row(_ title: NSView, _ control: NSView) -> NSStackView {
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalToConstant: 60).isActive = true
        return NSStackView(views: [title, control])
    }

    private func update(_ change: (inout BackgroundStyle) -> Void) {
        change(&style)
        onChange(style)
    }

    private func pickCustom(from: NSColor?, to: NSColor?) {
        for s in swatches { s.isSelected = false }
        update {
            $0.fillIndex = -1
            $0.customFrom = (from ?? .systemIndigo).p3String
            $0.customTo = (to ?? from ?? .systemIndigo).p3String
            $0.enabled = true
        }
        toggle.state = .on
    }

    private func pickFill(_ index: Int) {
        for (i, s) in swatches.enumerated() { s.isSelected = i == index }
        update { $0.fillIndex = index; $0.enabled = true }
        toggle.state = .on
    }

    @objc private func toggled(_ sender: NSSwitch) { update { $0.enabled = sender.state == .on } }
    @objc private func paddingChanged(_ sender: NSSlider) { update { $0.padding = CGFloat(sender.doubleValue).rounded() } }
    @objc private func radiusChanged(_ sender: NSSlider) { update { $0.cornerRadius = CGFloat(sender.doubleValue).rounded() } }
    @objc private func shadowToggled(_ sender: NSButton) { update { $0.shadow = sender.state == .on } }
}

/// A small rounded square previewing one background fill.
final class FillSwatch: NSButton {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }
    private let fill: BackgroundFill

    init(fill: BackgroundFill) {
        self.fill = fill
        super.init(frame: .zero)
        isBordered = false
        title = ""
        target = self
        action = #selector(clicked)
        if case .wallpaper = fill { toolTip = "Desktop wallpaper" }
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 40).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        fill.fill(rect, in: ctx, flipped: isFlipped)
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(isSelected ? NSColor.controlAccentColor.cgColor : NSColor.separatorColor.cgColor)
        ctx.setLineWidth(isSelected ? 2 : 1)
        ctx.strokePath()
    }

    @objc private func clicked() { onClick?() }
}

/// Auto-balance: finds the empty, single-colour space along each edge of a screenshot so the
/// visible content can be centred on the background instead of the raw rectangle.
@MainActor
enum ContentBalance {
    private static var cache: [String: CGVector] = [:]

    /// How far to move the screenshot (points, top-left origin) so its content looks centred.
    /// `crop` is in points; `pointSize` is the image's size in points.
    static func offset(for image: CGImage, crop: CGRect, pointSize: CGSize) -> CGVector {
        let scale = CGFloat(image.width) / max(pointSize.width, 1)
        let key = "\(ObjectIdentifier(image).hashValue)-\(crop.integral)"
        if let cached = cache[key] { return cached }
        let pixelCrop = CGRect(x: crop.minX * scale, y: crop.minY * scale,
                               width: crop.width * scale, height: crop.height * scale).integral
        guard let cropped = image.cropping(to: pixelCrop) else { return .zero }
        // Work on a small copy: margins don't need full resolution.
        let shrink = min(1, 400 / CGFloat(max(cropped.width, cropped.height)))
        let w = max(Int(CGFloat(cropped.width) * shrink), 2), h = max(Int(CGFloat(cropped.height) * shrink), 2)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .zero }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Memory row 0 is the top of the picture.
        func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
        func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
            abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) < 30
        }
        func uniformRow(_ y: Int, _ ref: (Int, Int, Int)) -> Bool { (0..<w).allSatisfy { near(px($0, y), ref) } }
        func uniformCol(_ x: Int, _ ref: (Int, Int, Int)) -> Bool { (0..<h).allSatisfy { near(px(x, $0), ref) } }
        let maxX = Int(Double(w) * 0.4), maxY = Int(Double(h) * 0.4)
        var top = 0, bottom = 0, left = 0, right = 0
        let tRef = px(w / 2, 0), bRef = px(w / 2, h - 1), lRef = px(0, h / 2), rRef = px(w - 1, h / 2)
        while top < maxY, uniformRow(top, tRef) { top += 1 }
        while bottom < maxY, uniformRow(h - 1 - bottom, bRef) { bottom += 1 }
        while left < maxX, uniformCol(left, lRef) { left += 1 }
        while right < maxX, uniformCol(w - 1 - right, rRef) { right += 1 }
        // Back to points.
        let toPoints = 1 / (shrink * scale)
        let result = CGVector(dx: CGFloat(right - left) / 2 * toPoints, dy: CGFloat(bottom - top) / 2 * toPoints)
        if cache.count > 40 { cache.removeAll() }
        cache[key] = result
        return result
    }
}


/// Frees big decoded images (wallpapers, background pictures) once Clarishot has been idle for a
/// while, so a menu-bar app doesn't sit on tens of MB between captures. Each use pushes it back.
@MainActor
enum MemoryTrim {
    private static var actions: [String: () -> Void] = [:]
    private static var pending: DispatchWorkItem?
    private static let delay: TimeInterval = 60

    /// Runs `action` after `delay` seconds without another call. Calls from the same place replace
    /// each other.
    static func soon(file: String = #fileID, line: Int = #line, _ action: @escaping () -> Void) {
        actions["\(file):\(line)"] = action
        pending?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let all = actions
                actions.removeAll()
                all.values.forEach { $0() }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
