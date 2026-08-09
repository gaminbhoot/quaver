import AppKit
import Foundation

// MARK: - Earliest diagnostic logging
// Logs to both stdout and /tmp/quaver-startup.log so we can diagnose
// even when stdout is not connected (plain Mach-O vs .app bundle).

func quaverEarlyLog(_ msg: String) {
    let line = "[Quaver] \(msg)"
    // stdout — may be unavailable when launched via Finder/open
    print(line)
    fflush(stdout)
    fflush(stderr)
    // file fallback — always available
    let url = URL(fileURLWithPath: "/tmp/quaver-startup.log")
    let data = (line + "\n").data(using: .utf8)!
    if FileManager.default.fileExists(atPath: url.path) {
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        }
    } else {
        try? data.write(to: url, options: .atomic)
    }
}

@main
struct QuaverMain {
    static func main() {
        // Clear previous log
        try? FileManager.default.removeItem(atPath: "/tmp/quaver-startup.log")
        quaverEarlyLog("PROCESS START pid=\(ProcessInfo.processInfo.processIdentifier) arg0=\(CommandLine.arguments.first ?? "") cwd=\(FileManager.default.currentDirectoryPath)")
        quaverEarlyLog("CommandLine.arguments=\(CommandLine.arguments)")

        // Static/global initialization check — if we hang before here, PROCESS START would not appear
        // Check for @MainActor blocking — none should run before NSApplication.shared
        let app = NSApplication.shared
        quaverEarlyLog("NSApplication.shared created \(app) activationPolicy=\(app.activationPolicy().rawValue) isActive=\(app.isActive)")

        let delegate = QuaverApp()
        app.delegate = delegate
        quaverEarlyLog("delegate assigned \(String(describing: delegate)) delegate class=\(type(of: delegate))")

        // Ensure regular even before run — plain Mach-O defaults to prohibited
        let setOK = app.setActivationPolicy(.regular)
        quaverEarlyLog("setActivationPolicy(.regular) -> \(setOK) now \(app.activationPolicy().rawValue)")

        quaverEarlyLog("entering NSApp.run — delegate will receive willFinish/didFinish next")
        // This blocks — delegate callbacks happen inside run
        app.run()
        quaverEarlyLog("NSApp.run returned — app terminated")
    }
}
