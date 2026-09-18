import AppKit

extension String {
    /// Escaped for embedding inside an AppleScript double-quoted string literal.
    ///
    /// Backslashes are escaped **before** quotes, or the backslash inserted for a
    /// quote would itself be escaped again. Without this, a path containing `"`
    /// ends the literal early — the classic way to smuggle arbitrary AppleScript
    /// (up to `do shell script`) out of a file name. A bundle can be renamed to
    /// anything, so every interpolated path is untrusted input.
    var appleScriptLiteral: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Launches, reveals and quits applications.
enum LaunchService {
    static func launch(_ app: AppInfo) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, error in
            if let error {
                NSLog("LaunchDeck: failed to launch \(app.path): \(error.localizedDescription)")
            }
        }
    }

    static func revealInFinder(_ app: AppInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    static func showInfo(_ app: AppInfo) {
        // Finder's Get Info window. `app.path` is user-controlled data (a bundle
        // can be renamed to anything), so it is escaped rather than interpolated
        // raw. `AppUninstaller` already escaped the same kind of value; the two
        // now share one helper so they cannot drift apart again.
        let source = """
        tell application "Finder"
            open information window of (POSIX file "\(app.path.appleScriptLiteral)" as alias)
            activate
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            NSLog("LaunchDeck: Get Info failed: \(error)")
        }
    }

    static func quit(_ app: AppInfo, force: Bool) {
        guard let running = runningApplication(for: app) else { return }
        if force {
            running.forceTerminate()
        } else {
            running.terminate()
        }
    }

    /// Answered from the cached running-app set; this is called for every cell
    /// on every render, so it must not hit NSWorkspace.
    static func isRunning(_ app: AppInfo) -> Bool {
        RunningApps.isRunning(bundleID: app.bundleID, path: app.path)
    }

    static func runningApplication(for app: AppInfo) -> NSRunningApplication? {
        if let bid = app.bundleID,
           let match = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
            return match
        }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == app.path }
    }
}
