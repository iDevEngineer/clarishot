import AppKit

/// App-wide look: light/dark theme and the optional Liquid Glass surfaces.
@MainActor
enum AppAppearance {
    enum Theme: String, CaseIterable {
        case system, light, dark
        var title: String { rawValue.capitalized }
    }

    /// Applies the theme from Settings to every window. Call at launch and when it changes.
    static func apply() {
        switch Settings.shared.theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Liquid Glass is on in Settings and this Mac supports it (macOS 26+).
    static var usesGlass: Bool {
        if #available(macOS 26.0, *) { return Settings.shared.liquidGlass }
        return false
    }

    /// A floating surface: Liquid Glass when that's on, otherwise `fallback`.
    /// Add content to `inner`; use `outer` as the surface itself.
    static func surface(cornerRadius: CGFloat, fallback: NSView) -> (outer: NSView, inner: NSView) {
        if #available(macOS 26.0, *), Settings.shared.liquidGlass {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            let inner = NSView()
            glass.contentView = inner
            return (glass, inner)
        }
        return (fallback, fallback)
    }
}
