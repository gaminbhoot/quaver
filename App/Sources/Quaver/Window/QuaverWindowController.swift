import AppKit

final class QuaverWindowController: NSWindowController {

    let rootSplit: RootSplitViewController

    convenience init() {
        let window = QuaverWindow()
        self.init(window: window, rootSplit: RootSplitViewController())
    }

    init(window: QuaverWindow, rootSplit: RootSplitViewController) {
        self.rootSplit = rootSplit
        super.init(window: window)
        // Host the split controller in the window — replaces the placeholder contentView
        window.contentViewController = rootSplit
        // Early center (screen may still be nil at this point — AppDelegate will
        // re-center after ordering when screen is known; keep this for headless).
        window.center()
        quaverEarlyLog("WindowController init — frame=\(window.frame) screen=\(String(describing: window.screen)) center=\(window.frame.origin)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Ensure window is actually on the current Space/screen with a valid frame.
    /// Called from AppDelegate AFTER ordering when screen is known.
    @MainActor func ensureVisibleOnActiveScreen() {
        guard let window else { return }
        // If screen is still nil after ordering, fall back to main screen.
        let targetScreen = window.screen ?? NSScreen.main
        quaverEarlyLog("ensureVisible — before: frame=\(window.frame) screen=\(String(describing: window.screen)) targetScreen=\(String(describing: targetScreen)) screenCount=\(NSScreen.screens.count)")
        if let screen = targetScreen {
            let visible = screen.visibleFrame
            quaverEarlyLog("screen visibleFrame=\(visible) frame=\(screen.frame)")
            // Fix zero-sized or off-screen frames
            if window.frame.width < 100 || window.frame.height < 100 {
                quaverEarlyLog("FIX: frame too small \(window.frame) → resetting to 1280x800")
                window.setContentSize(NSSize(width: 1280, height: 800))
            }
            if !visible.intersects(window.frame) || window.frame.origin.x < visible.minX - window.frame.width || window.frame.origin.y < visible.minY - window.frame.height {
                quaverEarlyLog("FIX: frame \(window.frame) off-screen vs \(visible) → centering")
                window.center()
                // center() uses screen; if still off, force origin
                if !visible.intersects(window.frame) {
                    window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width/2, y: visible.midY - window.frame.height/2))
                }
            } else {
                quaverEarlyLog("frame already intersects visible — keeping, but ensuring centered if at 0,0")
                if window.frame.origin == .zero {
                    window.center()
                }
            }
        } else {
            quaverEarlyLog("WARNING: no screen available, forcing center")
            window.center()
        }
        quaverEarlyLog("ensureVisible — after: frame=\(window.frame) screen=\(String(describing: window.screen))")
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        quaverEarlyLog("windowDidLoad — frame=\(String(describing: window?.frame)) screen=\(String(describing: window?.screen))")
        window?.makeKeyAndOrderFront(nil)
    }
}
