import AppKit

final class QuaverApp: NSObject, NSApplicationDelegate {
    var windowController: QuaverWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = NSApp.setActivationPolicy(.regular)
        quaverEarlyLog("willFinish — activationPolicy=\(NSApp.activationPolicy().rawValue) (0=regular) isActive=\(NSApp.isActive)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSApp.activationPolicy() != .regular {
            _ = NSApp.setActivationPolicy(.regular)
        }
        quaverEarlyLog("didFinish — activationPolicy=\(NSApp.activationPolicy().rawValue) isActive=\(NSApp.isActive)")

        if NSApp.mainMenu == nil {
            let mainMenu = NSMenu()
            let appMenuItem = NSMenuItem()
            mainMenu.addItem(appMenuItem)
            let appMenu = NSMenu()
            appMenu.addItem(NSMenuItem(title: "About Quaver", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
            appMenu.addItem(.separator())
            appMenu.addItem(NSMenuItem(title: "Hide Quaver", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
            appMenu.addItem(NSMenuItem(title: "Quit Quaver", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            appMenuItem.submenu = appMenu
            let editMenuItem = NSMenuItem()
            mainMenu.addItem(editMenuItem)
            let editMenu = NSMenu(title: "Edit")
            editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
            editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
            editMenu.addItem(.separator())
            editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
            editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
            editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
            editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
            editMenuItem.submenu = editMenu
            let findMenuItem = NSMenuItem()
            mainMenu.addItem(findMenuItem)
            let findMenu = NSMenu(title: "Find")
            findMenu.addItem(NSMenuItem(title: "Find…", action: #selector(NSSearchField.performClick(_:)), keyEquivalent: "k"))
            findMenuItem.submenu = findMenu
            NSApp.mainMenu = mainMenu
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "k" {
                if let win = NSApp.keyWindow, let wc = win.windowController as? QuaverWindowController {
                    if let field = Self.findSearchField(in: wc.rootSplit.sidebarVC.view) {
                        win.makeFirstResponder(field)
                        return nil
                    }
                }
            }
            return event
        }

        // === Create and present window — exact diagnostic sequence requested ===
        let controller = QuaverWindowController()
        windowController = controller // retain for lifetime
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
