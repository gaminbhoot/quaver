import AppKit

// MARK: - Quaver Glass — Apple Music-like restrained materials
// Visual priority: 1 Content 2 Navigation 3 Player controls 4 Material/depth 5 Glass
// NOT: 1 Glass 2 Blur 3 Transparency. Glass supports the UI; it does not announce itself.
//
// Apple Music principles used as reference (no branding copied):
// - coherent dark window/content background (windowBackgroundColor, opaque)
// - sidebar is subtly distinct but *attached* to the window, not a floating sheet
// - library is the dominant stable surface — header belongs to it, no glass panels
// - player bar is an integrated dark refined surface, not a transparent window
// - minimal borders / minimal noise / artwork is important
// - no desktop wallpaper bleed — withinWindow sampling of window content only
// - reduced-transparency falls back to solid (no blur)
// Lyrics is the exception: artwork IS the visual background -> glass remains.

@MainActor
enum QuaverGlass {

    enum Surface { case sidebar, playerBar, header, lyrics }

    /// Returns the appropriate background view for a surface.
    /// On Apple Music hierarchy we use glass *selectively*:
    /// sidebar = subtle material, lyrics = artwork-through glass,
    /// header/playerBar = solid window background (no glass) for a coherent app.
    static func backgroundView(for surface: Surface) -> NSView {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            return solidFallback(for: surface)
        }
        switch surface {
        case .sidebar:
            // Only sidebar and lyrics warrant true translucency.
            if #available(macOS 26.0, *) {
                return glassEffectView(for: .sidebar)
            } else {
                return visualEffectView(for: .sidebar)
            }
        case .lyrics:
            if #available(macOS 26.0, *) {
                return glassEffectView(for: .lyrics)
            } else {
                return visualEffectView(for: .lyrics)
            }
        case .header, .playerBar:
            // Apple Music: header belongs to library, player is integrated dark bar.
            // A glass panel here would read as an obvious rectangle and make the
            // library feel like a dark card beside translucent sheets. Solid keeps
            // WINDOW → COHERENT DARK CONTENT → SUBTLE SIDEBAR → LIBRARY →
            // SUBTLE PLAYER hierarchy.
            return solidFallback(for: surface)
        }
    }

    /// Container for the window's root. On 43bacca this was a clear
    /// NSGlassEffectContainerView(spacing:12) grouping sidebar+header+playerBar so
    /// they shared a single "demo" depth context — the source of the
    /// "Liquid Glass applied everywhere" look. Apple Music has ONE coherent dark
    /// window; the container is therefore a normal opaque view in the window
    /// background color. We keep a plain NSView so glass (sidebar/lyrics only)
    /// samples the window's own content via .withinWindow, not the desktop.
    static func containerView(spacing: CGFloat = 12) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        return v
    }

    static func visualEffectView(for surface: Surface) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.state = .active
        // All in-window — never sample the desktop/wallpaper. This is what removed
        // the c28bb40/43bacca wallpaper bleed. Kept here for sidebar/lyrics.
        v.blendingMode = .withinWindow
        // Sidebar in Apple Music is restrained — not emphasized vibrancy.
        v.isEmphasized = false
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
        switch surface {
        case .sidebar:
            // Apple Music sidebar: .regular with a *restrained* tint. Previous
            // attempts: 0.35-0.55 read as opaque slab, 0.10 was a transparent sheet
            // that exposed the desktop. 0.82 over the opaque window background gives
            // depth/vibrancy but the sidebar still reads as dark, attached, and
            // subtly distinct from the library — not a demo panel.
            g.style = .regular
            g.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.82)
        case .lyrics:
            // Immersive lyrics over artwork — artwork must remain visible.
            g.style = .clear
            g.tintColor = NSColor.black.withAlphaComponent(0.18)
        case .playerBar, .header:
            // Not used — header/playerBar intentionally return solidFallback, but
            // keep valid case for completeness.
            g.style = .regular
            g.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.84)
        }
        g.cornerRadius = 0
        // NSGlassEffectView requires a contentView — clear placeholder when used as
        // a background sibling (controls stay interactive above).
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
        // All solid surfaces share the same windowBackgroundColor so the app reads
        // as ONE dark app. The subtle sidebar glass above this is the only
        // material separation; library + header are continuous; player is an
        // integrated bottom surface with a faint hairline (handled in its VC).
        switch surface {
        case .sidebar, .playerBar, .header:
            v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        case .lyrics:
            v.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        }
        return v
    }
}
