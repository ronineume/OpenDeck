import AppKit
import Foundation

/// Adds an app to the Dock — the way LaunchOS does it (report 56 §1).
///
/// Decoded from LaunchOS: `LaunchpadAppView.addAppToDock` (`0x1000eb8a0`) →
/// `FUN_1000eb7a8` (take the app's URL) → `FUN_10006fadc`:
///
/// 1. `_CFPreferencesCopyAppValue("persistent-apps", "com.apple.dock")`
///    (the two strings are the lazy initialisers at `0x10006d550` /
///    `0x10006d514` — immediates decode to `persistent-apps` and
///    `com.apple.dock`)
/// 2. append `url.standardizedFileURL.absoluteString`
/// 3. `_CFPreferencesSetAppValue` + `_CFPreferencesAppSynchronize`
/// 4. `FUN_10006fa44` — an `NSTask` whose launch path is the literal pool
///    entry for `/usr/bin/killall` (`0x10006fa68`), i.e. **`killall Dock`**
///
/// The tile written here is the Dock's own minimal form
/// (`tile-data/file-data/_CFURLString` + `tile-type`), the shape `defaults
/// read com.apple.dock persistent-apps` shows for every hand-added entry;
/// the Dock fills in the label and bookkeeping when it restarts.
///
/// The array surgery is pure; the read/write/restart is the production half.
enum DockSync {
    /// The Dock domain and key LaunchOS reads and writes.
    static let dockDomain = "com.apple.dock" as CFString
    static let persistentAppsKey = "persistent-apps" as CFString

    /// The new `persistent-apps` with `urlString` appended as a file tile.
    ///
    /// Idempotent: an app already in the Dock (matched by its
    /// `_CFURLString`) leaves the array untouched — LaunchOS's own guard is
    /// the same idea, arrived at from the other side.
    static func addingApp(urlString: String, to apps: [[String: Any]]) -> [[String: Any]] {
        if contains(urlString: urlString, in: apps) { return apps }
        var updated = apps
        updated.append([
            "tile-data": [
                "file-data": [
                    "_CFURLString": urlString,
                    "_CFURLStringType": 15,
                ] as [String: Any],
            ] as [String: Any],
            "tile-type": "file-tile",
        ])
        return updated
    }

    /// Whether the Dock already holds this app.
    static func contains(urlString: String, in apps: [[String: Any]]) -> Bool {
        apps.contains { entry in
            guard let tileData = entry["tile-data"] as? [String: Any],
                  let fileData = tileData["file-data"] as? [String: Any],
                  let existing = fileData["_CFURLString"] as? String else {
                return false
            }
            return sameApp(existing, urlString)
        }
    }

    /// The Dock stores a trailing slash (`file:///Applications/Foo.app/`);
    /// the same app written without one is still the same app.
    static func sameApp(_ a: String, _ b: String) -> Bool {
        a == b || a.hasSuffix("/") && String(a.dropLast()) == b
            || b.hasSuffix("/") && String(b.dropLast()) == a
    }

    /// Adds the app to the Dock and restarts the Dock so it takes effect.
    ///
    /// Returns false when the write could not be made — the caller's cue to
    /// say so rather than pretend. A headless run never touches the Dock:
    /// this is a real change to the user's system, the same contract
    /// `DeckSettings.applyDockIcon` keeps.
    @discardableResult
    static func addToDock(app: AppInfo) -> Bool {
        guard DeckSettings.shared.mayPersist else { return false }
        let urlString = URL(fileURLWithPath: app.path).standardizedFileURL.absoluteString
        let existing = CFPreferencesCopyAppValue(persistentAppsKey, dockDomain)
            as? [[String: Any]] ?? []
        let updated = addingApp(urlString: urlString, to: existing)
        // `addingApp` is idempotent, so an unchanged count means "already
        // there" — no write, no Dock restart.
        guard updated.count != existing.count else { return true }
        CFPreferencesSetAppValue(persistentAppsKey, updated as CFPropertyList, dockDomain)
        guard CFPreferencesAppSynchronize(dockDomain) else { return false }
        restartDock()
        return true
    }

    /// `killall Dock` — the decoded step 4. The Dock relaunches itself and
    /// picks the new tile up.
    static func restartDock() {
        let task = Process()
        task.launchPath = "/usr/bin/killall"
        task.arguments = ["Dock"]
        try? task.run()
    }
}
