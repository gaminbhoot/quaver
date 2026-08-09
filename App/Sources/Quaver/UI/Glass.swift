import AppKit

// MARK: - Quaver Glass — native AppKit materials (NSVisualEffectView / NSGlassEffectView)
// Visual-only phase. No layout redesign, no state change, no timers, no polling.
// Minimum number of surfaces. Respects reduced transparency and appearance.

@MainActor
enum QuaverGlass {

    enum Surface { case sidebar, playerBar, header, lyrics }

    /// Returns a background view that provides native translucency.
    /// - On macOS 26+: genuine NSGlassEffectView (Liquid Glass).
    /// - Earlier: NSVisualEffectView with appropriate material.
    /// - If reduced transparency is enabled: solid fallback (no blur).
    static func backgroundView(for surface: Surface) -> NSView {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            return solidFallback(for: surface)
        }
        if #available(macOS 26.0, *) {
            // Use genuine Liquid Glass where the SDK provides it.
            return glassEffectView(for: surface)
        } else {
            return visualEffectView(for: surface)
        }
    }

    /// Convenience for callers that need NSVisualEffectView specifically
    /// (e.g., to adjust alpha or blending without casting).
    static func visualEffectView(for surface: Surface) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.state = .active
        // Blending: sidebar/player show desktop behind window (native sidebar/hud style);
        // lyrics/header show content within window (artwork/header background).
        switch surface {
        case .sidebar, .playerBar: v.blendingMode = .behindWindow
        case .header, .lyrics: v.blendingMode = .withinWindow
        }
        v.isEmphasized = true
        v.wantsLayer = true
        // No hard opaque boundary where translucent should exist — keep corners 0
        // for edge-to-edge surfaces, rely on window's own rounding.
        switch surface {
        case .sidebar:
            if #available(macOS 10.14, *) {
                v.material = .sidebar
            } else {
                v.material = .windowBackground
            }
        case .playerBar:
            v.material = .hudWindow
            // Keep bar visually distinct but translucent; hudWindow is designed for
            // overlay bars and remains interactive.
        case .header:
            v.material = .headerView
        case .lyrics:
            v.material = .hudWindow
            // Lyrics dimming is layered over artwork; keep slight translucency
            // without making entire overlay transparent.
            v.alphaValue = 0.92
        }
        return v
    }

    @available(macOS 26.0, *)
    private static func glassEffectView(for surface: Surface) -> NSView {
        let g = NSGlassEffectView()
        g.translatesAutoresizingMaskIntoConstraints = false
        // Style: regular for bars/sidebar, clear for immersive lyrics so artwork shows through.
        switch surface {
        case .lyrics: g.style = .clear
        case .sidebar, .playerBar, .header: g.style = .regular
        }
        // Corner radius 0 preserves seamless edge-to-edge transition; window owns corners.
        g.cornerRadius = 0
        // Subtle tints keep Quaver's dark aesthetic while letting vibrancy show.
        switch surface {
        case .sidebar:
            g.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.35)
        case .playerBar:
            g.tintColor = NSColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 0.55)
        case .header:
            g.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.3)
        case .lyrics:
            g.tintColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 0.35)
        }
        // Glass needs a contentView to render correctly per header docs; an empty
        // view is sufficient when we use the glass as a background sibling.
        let placeholder = NSView()
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.wantsLayer = true
        placeholder.layer?.backgroundColor = NSColor.clear.cgColor
        g.contentView = placeholder
        return g
    }

    private static func solidFallback(for surface: Surface) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        switch surface {
        case .sidebar:
            v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        case .playerBar:
            v.layer?.backgroundColor = NSColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1.0).cgColor
        case .header:
            v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        case .lyrics:
            v.layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 0.85).cgColor
        }
        return v
    }
}
