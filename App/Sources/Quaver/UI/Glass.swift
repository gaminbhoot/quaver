import AppKit

// MARK: - Quaver Glass — native AppKit materials (NSVisualEffectView / NSGlassEffectView)
// Visual-only phase. No layout redesign, no state change, no timers, no polling.
// Minimum number of surfaces. Respects reduced transparency and appearance.
// Tahoe (macOS 26) uses genuine NSGlassEffectView with subtle tints and proper
// container grouping so sidebar → library and PlayerBar → content transitions are
// seamless, not hard opaque rectangles.

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
            return glassEffectView(for: surface)
        } else {
            return visualEffectView(for: surface)
        }
    }

    /// Container that groups Liquid Glass surfaces for correct depth + batching.
    /// On Tahoe, ancestor NSGlassEffectContainerView merges descendant glass views
    /// when they are similar and within `spacing`. Use at the window/root level
    /// so sidebar, header, playerBar share a single glass context. On older OS,
    /// returns a plain transparent container.
    static func containerView(spacing: CGFloat = 12) -> NSView {
        if #available(macOS 26.0, *) {
            let c = NSGlassEffectContainerView()
            c.spacing = spacing
            c.wantsLayer = true
            c.layer?.backgroundColor = NSColor.clear.cgColor
            return c
        } else {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.clear.cgColor
            return v
        }
    }

    /// Convenience for callers that need NSVisualEffectView specifically.
    static func visualEffectView(for surface: Surface) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.state = .active
        // All in-window surfaces sample the *window's own* content/background,
        // not the desktop. .behindWindow would punch through to the wallpaper
        // and make the sidebar/PlayerBar look like transparent cutouts over
        // the desktop (the c28bb40 bug). .withinWindow keeps glass integrated
        // with the application's coherent background → LIST → GLASS → CONTROLS
        // hierarchy, preserving translucency/vibrancy without desktop bleed.
        v.blendingMode = .withinWindow
        v.isEmphasized = true
        v.wantsLayer = true
        switch surface {
        case .sidebar:
            if #available(macOS 10.14, *) {
                v.material = .sidebar
            } else {
                v.material = .windowBackground
            }
        case .playerBar:
            v.material = .hudWindow
        case .header:
            v.material = .headerView
        case .lyrics:
            v.material = .hudWindow
            v.alphaValue = 0.88
        }
        return v
    }

    @available(macOS 26.0, *)
    private static func glassEffectView(for surface: Surface) -> NSView {
        let g = NSGlassEffectView()
        g.translatesAutoresizingMaskIntoConstraints = false
        // Style: .clear is more translucent (vibrant, shows desktop/content behind
        // with depth); .regular is slightly more opaque for bars that need readability.
        switch surface {
        case .sidebar, .lyrics: g.style = .clear
        case .playerBar, .header: g.style = .regular
        }
        // CornerRadius 0 keeps edge-to-edge surfaces seamless; the window's own
        // rounded corners clip. Floating surfaces (if any) would use non-zero.
        g.cornerRadius = 0
        // Subtle tints — enough to preserve Quaver's dark aesthetic but light enough
        // that vibrancy/depth shows through. Previous tints (0.35–0.55) were so dark
        // the glass read as an opaque slab; these are 60–70% lighter.
        switch surface {
        case .sidebar:
            // Very subtle — sidebar should show desktop blur with depth, not a dark rectangle.
            g.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.10)
        case .playerBar:
            // Bottom bar needs a touch more opacity for control legibility, but still
            // translucent so it blends into library content rather than floating as a slab.
            g.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.16)
        case .header:
            // Header floats over scroll content; subtle so list shows through with blur.
            g.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.09)
        case .lyrics:
            // Immersive lyrics over artwork — artwork must remain visible through glass.
            g.tintColor = NSColor.black.withAlphaComponent(0.18)
        }
        // Glass needs a contentView per header docs; an empty clear view is sufficient
        // when we use the glass as a background sibling (controls stay interactive above).
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
            v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        case .header:
            v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        case .lyrics:
            v.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        }
        return v
    }
}
