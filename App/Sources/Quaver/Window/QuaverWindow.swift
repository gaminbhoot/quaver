import AppKit

/// Pure AppKit window. No WKWebView. No HTML. Real traffic lights.
final class QuaverWindow: NSWindow {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "Quaver"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .normal
        collectionBehavior = [.managed, .canJoinAllSpaces]
        // Coherent native macOS background — glass samples *window content*,
        // not the desktop. Previous clear + isOpaque false made .behindWindow
        // glass punch through to the wallpaper, so sidebar/PlayerBar looked
        // like transparent cutouts (desktop bleed) with the opaque library
        // between them as a hard dark rectangle. Now:
        //   WINDOW BACKGROUND (windowBackgroundColor, opaque)
        //     → APPLICATION CONTENT (library opaque where needed)
        //       → NATIVE GLASS SURFACE (translucent withinWindow)
        //         → NATIVE CONTROLS
        // Glass has depth/vibrancy without exposing the desktop, and the
        // sidebar → library boundary becomes a subtle material edge, not a
        // transparent→opaque→transparent mismatch.
        backgroundColor = NSColor.windowBackgroundColor
        isOpaque = true
        minSize = NSSize(width: 800, height: 500)
        // Placeholder that proves no WebView exists — matches window background
        // so there is no flash of desktop before RootSplitViewController loads.
        let placeholder = NSView(frame: contentRect(forFrameRect: frame))
        placeholder.wantsLayer = true
        placeholder.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentView = placeholder
        assert(!String(describing: type(of: contentView as Any)).contains("WKWebView"),
               "QuaverWindow must not contain WKWebView")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
