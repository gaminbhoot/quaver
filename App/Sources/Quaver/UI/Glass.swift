import AppKit

// MARK: - Quaver Glass — detached floating surfaces over coherent dark library
// Visual hierarchy (three deliberate layers):
//   COHERENT APPLICATION BACKGROUND (windowBackgroundColor, opaque)
//     → MAIN LIBRARY (dominant, calm, solid, non-glass)
//       → FLOATING SIDEBAR (independent rounded glass, detached, shadowed)
//       → FLOATING MINI-PLAYER PILL (capsule glass, detached, shadowed)
// Lyrics is the exception: immersive artwork-through glass.
// Goals: restraint, no desktop wallpaper bleed, no connected glass sheet,
// independent geometry/shadow/material for sidebar vs pill.

@MainActor
enum QuaverGlass {

    enum Surface { case sidebar, playerBar, header, lyrics }

    /// Selective glass: only floating surfaces (sidebar, pill, lyrics) are translucent.
    /// Header is solid and belongs to the library.
    static func backgroundView(for surface: Surface) -> NSView {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            return solidFallback(for: surface)
        }
        switch surface {
        case .sidebar:
            if #available(macOS 26.0, *) {
                return glassEffectView(for: .sidebar)
            } else {
                return visualEffectView(for: .sidebar)
            }
        case .playerBar:
            // Pill player — floating capsule, not a full-width bar.
            if #available(macOS 26.0, *) {
                return glassEffectView(for: .playerBar)
            } else {
                return visualEffectView(for: .playerBar)
            }
        case .lyrics:
            if #available(macOS 26.0, *) {
                return glassEffectView(for: .lyrics)
            } else {
                return visualEffectView(for: .lyrics)
            }
        case .header:
            if #available(macOS 26.0, *) {
                return glassEffectView(for: .header)
            } else {
                return visualEffectView(for: .header)
            }
        }
    }

    /// Coherent dark container — never a glass container. Previous clear
    /// NSGlassEffectContainerView(spacing:12) grouped every surface into one
    /// "connected sheet." Floating sidebar and pill must be independent objects
    /// with their own geometry/shadow/material, so the container is plain solid.
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
        v.blendingMode = .withinWindow
        v.isEmphasized = false
        v.wantsLayer = true
        // Independent rounded geometry — not edge-to-edge.
        switch surface {
        case .sidebar:
            v.material = .sidebar
            v.layer?.cornerRadius = 14
            v.layer?.masksToBounds = true
        case .playerBar:
            // Pill fallback on <26: hudWindow with capsule radius 34
            v.material = .hudWindow
            v.layer?.cornerRadius = 34
            v.layer?.masksToBounds = true
        case .header:
            v.material = .headerView
            v.blendingMode = .withinWindow
            v.state = .active
            v.wantsLayer = true
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
        g.wantsLayer = true
        g.layer?.masksToBounds = true
        switch surface {
        case .sidebar:
            // Floating sidebar: softly translucent, detached, rounded 14
            g.style = .regular
            g.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.78)
            g.cornerRadius = 14
        case .playerBar:
            // Floating pill: capsule, compact, premium controller
            g.style = .regular
            g.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.84)
            g.cornerRadius = 34 // pill: height 68 -> radius 34
        case .lyrics:
            g.style = .clear
            g.tintColor = NSColor.black.withAlphaComponent(0.18)
            g.cornerRadius = 0
        case .header:
            g.style = .regular
            g.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.72)
            g.cornerRadius = 0
        }
        // Pill/sidebar have shadow via host view's layer, not glass contentView.
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
        case .sidebar, .playerBar, .header:
            v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            // Floating surfaces need rounded fallback when reduced transparency
            if surface == .sidebar { v.layer?.cornerRadius = 14; v.layer?.masksToBounds = true }
            if surface == .playerBar { v.layer?.cornerRadius = 34; v.layer?.masksToBounds = true }
        case .lyrics:
            v.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        }
        return v
    }
}
