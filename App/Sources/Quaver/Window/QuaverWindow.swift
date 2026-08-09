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
        // Liquid Glass needs the window itself to be transparent where glass shows
        // desktop blur. An opaque windowBackgroundColor behind a .behindWindow glass
        // would defeat depth and make the sidebar read as a flat dark slab. Use
        // clear + non-opaque and let each pane (sidebar glass vs library opaque)
        // define its own background. Library's own view will still be opaque for
        // list readability; sidebar's glass will show desktop through the clear,
        // giving genuine depth instead of an opaque rectangle.
        backgroundColor = .clear
        isOpaque = false
        minSize = NSSize(width: 800, height: 500)
        // Placeholder that proves no WebView exists — also clear so glass shows through.
        let placeholder = NSView(frame: contentRect(forFrameRect: frame))
        placeholder.wantsLayer = true
        placeholder.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = placeholder
        assert(!String(describing: type(of: contentView as Any)).contains("WKWebView"),
               "QuaverWindow must not contain WKWebView")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
