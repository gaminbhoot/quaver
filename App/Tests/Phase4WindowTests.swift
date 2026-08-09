import AppKit

// Phase 4: NSWindow / traffic lights / native chrome — pure AppKit, no WKWebView.

var windowFailures: [String] = []
func windowCheck(_ cond: Bool, _ msg: String) {
    if !cond { windowFailures.append(msg); print("FAIL: \(msg)") }
    else { print("PASS: \(msg)") }
}

@MainActor
func testQuaverWindowChrome() {
    let w = QuaverWindow()
    windowCheck(w.styleMask.contains(.titled), "window styleMask contains .titled")
    windowCheck(w.styleMask.contains(.closable), "window styleMask contains .closable")
    windowCheck(w.styleMask.contains(.miniaturizable), "window styleMask contains .miniaturizable")
    windowCheck(w.styleMask.contains(.resizable), "window styleMask contains .resizable")
    windowCheck(w.styleMask.contains(.fullSizeContentView), "window styleMask contains .fullSizeContentView")
    windowCheck(w.titleVisibility == .hidden, "titleVisibility == .hidden")
    windowCheck(w.titlebarAppearsTransparent == true, "titlebarAppearsTransparent == true")
    windowCheck(w.hasShadow == true, "hasShadow == true")
    windowCheck(w.minSize == NSSize(width: 800, height: 500), "minSize == 800x500 — got \(w.minSize)")
    windowCheck(w.backgroundColor != nil, "backgroundColor is set")
    windowCheck(w.canBecomeKey, "canBecomeKey == true")
    windowCheck(w.canBecomeMain, "canBecomeMain == true")
    // Real traffic lights — standardWindowButton must exist
    windowCheck(w.standardWindowButton(.closeButton) != nil, "closeButton traffic light exists")
    windowCheck(w.standardWindowButton(.miniaturizeButton) != nil, "miniaturizeButton traffic light exists")
    windowCheck(w.standardWindowButton(.zoomButton) != nil, "zoomButton traffic light exists")
    // No WKWebView anywhere in hierarchy
    let desc = String(describing: type(of: w.contentView as Any))
    windowCheck(!desc.contains("WKWebView") && !desc.contains("WebView"), "contentView is not WKWebView (got \(desc))")
    // Walk hierarchy for WebView
    var foundWebView = false
    func walk(_ view: NSView) {
        let t = String(describing: type(of: view))
        if t.contains("WKWebView") || t.contains("WebView") { foundWebView = true }
        for sub in view.subviews { walk(sub) }
    }
    if let cv = w.contentView { walk(cv) }
    windowCheck(!foundWebView, "no WKWebView in entire view hierarchy")
    // ContentView placeholder is plain NSView
    windowCheck(w.contentView != nil, "contentView is NSView")
    // isMovableByWindowBackground should be false (explicit, avoids drag bugs from Phase 1 audit)
    windowCheck(w.isMovableByWindowBackground == false, "isMovableByWindowBackground == false")
}

@MainActor
func testWindowController() {
    let c = QuaverWindowController()
    windowCheck(c.window is QuaverWindow, "WindowController hosts QuaverWindow")
    windowCheck(c.window?.contentView != nil, "WindowController window has contentView")
}


