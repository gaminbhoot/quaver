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
        // Ensure window appears on the active Space and is managed by Mission Control.
        // This was missing — plain executable has no Info.plist, so collectionBehavior
        // defaulted to 0 and the window could be ordered onto a non-visible Space
        // (visible=true in System Events but no window on current desktop).
        collectionBehavior = [.managed, .canJoinAllSpaces]
        backgroundColor = NSColor(named: "QuaverBackground") ?? NSColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1.0)
        minSize = NSSize(width: 800, height: 500)
        // Content view will be set by the root view controller in Phase 4+.
        // For Phase 1: placeholder that proves no WebView exists.
        let placeholder = NSView(frame: contentRect(forFrameRect: frame))
        placeholder.wantsLayer = true
        placeholder.layer?.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1.0).cgColor
        contentView = placeholder
        // Verify: no WKWebView in the hierarchy.
        assert(!String(describing: type(of: contentView as Any)).contains("WKWebView"),
               "QuaverWindow must not contain WKWebView")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
