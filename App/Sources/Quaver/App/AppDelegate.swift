import AppKit

@MainActor
final class QuaverApp: NSObject, NSApplicationDelegate {
    var windowController: QuaverWindowController?
    private var nowPlayingController: NowPlayingInfoController?
    private var eventMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = NSApp.setActivationPolicy(.regular)
        quaverEarlyLog("willFinish — activationPolicy=\(NSApp.activationPolicy().rawValue) (0=regular) isActive=\(NSApp.isActive)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSApp.activationPolicy() != .regular {
            _ = NSApp.setActivationPolicy(.regular)
        }
        quaverEarlyLog("didFinish — activationPolicy=\(NSApp.activationPolicy().rawValue) isActive=\(NSApp.isActive)")

        // Build full menu before window so shortcuts target correctly.
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = QuaverMenuBuilder.buildMainMenu()
        } else {
            // Rebuild to ensure our expanded menu replaces the minimal placeholder.
            NSApp.mainMenu = QuaverMenuBuilder.buildMainMenu()
        }

        installGlobalKeyHandling()

        // === Create and present window — exact diagnostic sequence requested ===
        let controller = QuaverWindowController()
        windowController = controller // retain for lifetime

        // Media integration — single engine, single nowPlaying controller.
        nowPlayingController = NowPlayingInfoController(engine: controller.rootSplit.engine)

        logExact(controller: controller, label: "INIT after QuaverWindowController() — window.center() already called in init")

        // Explicit before/after for each step the user requested
        logExact(controller: controller, label: "BEFORE window.center()")
        controller.window?.center()
        logExact(controller: controller, label: "AFTER window.center()")

        logExact(controller: controller, label: "BEFORE showWindow(nil)")
        controller.showWindow(nil)
        logExact(controller: controller, label: "AFTER showWindow(nil)")

        logExact(controller: controller, label: "BEFORE makeKeyAndOrderFront(nil)")
        controller.window?.makeKeyAndOrderFront(nil)
        logExact(controller: controller, label: "AFTER makeKeyAndOrderFront(nil)")

        logExact(controller: controller, label: "BEFORE orderFrontRegardless()")
        controller.window?.orderFrontRegardless()
        logExact(controller: controller, label: "AFTER orderFrontRegardless()")

        // Ensure Space/frame fix before activation
        logExact(controller: controller, label: "BEFORE ensureVisibleOnActiveScreen()")
        controller.ensureVisibleOnActiveScreen()
        logExact(controller: controller, label: "AFTER ensureVisibleOnActiveScreen()")

        logExact(controller: controller, label: "BEFORE NSApp.activate(ignoringOtherApps: true)")
        NSApp.activate(ignoringOtherApps: true)
        logExact(controller: controller, label: "AFTER NSApp.activate")

        NSApp.unhide(nil)
        // Re-assert key after activation (common AppKit fix)
        controller.window?.makeKeyAndOrderFront(nil)
        logExact(controller: controller, label: "FINAL after activate + makeKeyAndOrderFront")

        // Retention and global state
        quaverEarlyLog("retention: windowController.window != nil=\(controller.window != nil) self.windowController retained=\(self.windowController != nil) NSApp.delegate retained=\(NSApp.delegate != nil)")
        quaverEarlyLog("global: NSApp.isActive=\(NSApp.isActive) keyWindow=\(String(describing: NSApp.keyWindow?.title)) mainWindow=\(String(describing: NSApp.mainWindow?.title)) windows.count=\(NSApp.windows.count) screens.count=\(NSScreen.screens.count)")

        // Delayed checks — window could be moved/hidden after RunLoop
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak controller] in
            guard let c = controller else { quaverEarlyLog("DELAYED 0.7s: controller deallocated!"); return }
            self.logExact(controller: c, label: "DELAYED 0.7s")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak controller] in
            guard let c = controller else { quaverEarlyLog("DELAYED 2.0s: controller deallocated!"); return }
            self.logExact(controller: c, label: "DELAYED 2.0s")
            if let w = c.window {
                let isZero = w.frame.width < 10 || w.frame.height < 10
                let isOff = NSScreen.screens.first.map { !$0.frame.intersects(w.frame) } ?? (w.screen == nil)
                quaverEarlyLog("DIAGNOSIS: isZero=\(isZero) offScreen≈\(isOff) screenNil=\(w.screen == nil) — if isVisible true but not rendered, check AppKit presentation (level/collection/order).")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
        nowPlayingController?.invalidate()
        nowPlayingController = nil
    }

    // MARK: - Global keyboard

    private func installGlobalKeyHandling() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Allow text editing to handle its own keys.
            if self.isInTextEditingContext() { return event }

            // Cmd+K → Search
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "k" {
                if let win = NSApp.keyWindow, let wc = win.windowController as? QuaverWindowController {
                    if let field = Self.findSearchField(in: wc.rootSplit.sidebarVC.view) {
                        win.makeFirstResponder(field)
                        return nil
                    }
                }
            }
            // Cmd+numbers → Views (fallback if menu accelerators not hit when field focused)
            if event.modifierFlags.contains(.command), let chars = event.charactersIgnoringModifiers {
                switch chars {
                case "1": self.viewAllSongs(nil); return nil
                case "2": self.viewLikedSongs(nil); return nil
                case "3": self.viewRecentlyPlayed(nil); return nil
                case "4": self.viewArtists(nil); return nil
                case "5": self.viewAlbums(nil); return nil
                case "l", "L": self.toggleLyrics(nil); return nil
                default: break
                }
            }
            // Space → Play/Pause (only when not typing, no modifiers)
            if event.keyCode == 49 && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                // Space often goes to button; we handle it as play/pause for convenience.
                // Only if window is key and we are in content context.
                if NSApp.keyWindow != nil {
                    self.togglePlay(nil)
                    return nil
                }
            }
            return event
        }
    }

    private func isInTextEditingContext() -> Bool {
        guard let win = NSApp.keyWindow, let first = win.firstResponder else { return false }
        if first is NSTextView { return true }
        if first is NSTextField { return true }
        if first is NSSearchField { return true }
        // Check via class name to avoid missing custom editors
        let clsName = String(describing: type(of: first))
        if clsName.contains("Text") { return true }
        return false
    }

    // MARK: - Menu actions (all funnel to single engine / RootSplit)

    @objc func addMusicFolder(_ sender: Any?) {
        windowController?.rootSplit.handleAddFolderRequest()
    }
    @objc func createPlaylist(_ sender: Any?) {
        windowController?.rootSplit.handleCreatePlaylistRequest()
    }
    @objc func togglePlay(_ sender: Any?) {
        windowController?.rootSplit.engine.togglePlay()
    }
    @objc func nextTrack(_ sender: Any?) {
        windowController?.rootSplit.engine.next()
    }
    @objc func previousTrack(_ sender: Any?) {
        windowController?.rootSplit.engine.previous()
    }
    @objc func toggleShuffle(_ sender: Any?) {
        guard let eng = windowController?.rootSplit.engine else { return }
        eng.setShuffle(!eng.state.isShuffle)
    }
    @objc func cycleRepeat(_ sender: Any?) {
        guard let eng = windowController?.rootSplit.engine else { return }
        let next: RepeatMode
        switch eng.state.repeatMode {
        case .off: next = .all
        case .all: next = .one
        case .one: next = .off
        }
        eng.setRepeatMode(next)
    }
    @objc func viewAllSongs(_ sender: Any?) { navigate(to: .all) }
    @objc func viewLikedSongs(_ sender: Any?) { navigate(to: .liked) }
    @objc func viewRecentlyPlayed(_ sender: Any?) { navigate(to: .recent) }
    @objc func viewArtists(_ sender: Any?) { navigate(to: .artists) }
    @objc func viewAlbums(_ sender: Any?) { navigate(to: .albums) }
    @objc func toggleLyrics(_ sender: Any?) { windowController?.rootSplit.toggleLyrics() }
    @objc func find(_ sender: Any?) {
        guard let win = NSApp.keyWindow, let wc = win.windowController as? QuaverWindowController else { return }
        if let field = Self.findSearchField(in: wc.rootSplit.sidebarVC.view) {
            win.makeFirstResponder(field)
        }
    }
    @objc func showPreferences(_ sender: Any?) { NSSound.beep() }
    @objc func showHelp(_ sender: Any?) {
        if let url = URL(string: "https://github.com/gaminbhoot/quaver") {
            NSWorkspace.shared.open(url)
        }
    }

    private func navigate(to view: LibraryView) {
        windowController?.rootSplit.navigate(to: view)
    }

    // MARK: - Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let title = menuItem.title
        // Playback items require a track to be meaningful — but we keep them enabled
        // and they gracefully no-op if no track, similar to Apple Music.
        if ["Shuffle", "Repeat"].contains(title) { return true }
        // Preference / help always enabled
        return true
    }

    // MARK: - Diagnostics

    private func logExact(controller: QuaverWindowController?, label: String) {
        let w = controller?.window
        let hasWindow = w != nil
        let frame = w?.frame ?? .zero
        let screenFrame = w?.screen?.frame ?? .zero
        let visibleFrame = w?.screen?.visibleFrame ?? .zero
        let screenDesc = w?.screen != nil ? "screen exists" : "screen nil (main=\(String(describing: NSScreen.main?.frame)))"
        let cvFrame = w?.contentView?.frame ?? .zero
        let cvBounds = w?.contentView?.bounds ?? .zero
        let policy = NSApp.activationPolicy().rawValue
        let isActive = NSApp.isActive
        // Use quaverEarlyLog so it goes to both stdout and /tmp/quaver-startup.log
        quaverEarlyLog("\(label):")
        quaverEarlyLog("  window.frame=\(frame) screen.frame=\(screenFrame) screen.visibleFrame=\(visibleFrame) (\(screenDesc))")
        quaverEarlyLog("  isVisible=\(w?.isVisible ?? false) isKeyWindow=\(w?.isKeyWindow ?? false) isMainWindow=\(w?.isMainWindow ?? false) orderedIndex=\(w?.orderedIndex ?? -1) level=\(w?.level.rawValue ?? -1) collectionBehavior=\(w?.collectionBehavior.rawValue ?? 0) styleMask=\(w?.styleMask.rawValue ?? 0)")
        quaverEarlyLog("  contentView.frame=\(cvFrame) bounds=\(cvBounds) windowController.window != nil=\(hasWindow) NSApp.activationPolicy()=\(policy) NSApp.isActive=\(isActive)")
    }

    private static func findSearchField(in view: NSView) -> NSSearchField? {
        if let f = view as? NSSearchField { return f }
        for sub in view.subviews { if let hit = findSearchField(in: sub) { return hit } }
        return nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
