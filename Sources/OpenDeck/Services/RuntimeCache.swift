import AppKit

/// Caches app icons.
///
/// `NSWorkspace.icon(forFile:)` hits the filesystem and re-reads the bundle's
/// icon resources; calling it from a SwiftUI body (once per cell, per render)
/// is what made the grid feel sluggish.
/// Freshness signature for a bundle's icon: the modification dates that change
/// when an app is updated.
///
/// Two parts are combined because either one alone misses a real update path:
/// the *bundle directory* mtime changes when the bundle's own entries are
/// replaced (drag-install, Sparkle-style whole-bundle swap), while the
/// *manifest* (`Contents/Info.plist`) mtime also moves when an updater rewrites
/// that file in place — a case the directory mtime alone does not reflect.
///
/// Both parts are optional, and a missing part is stored as `nil` (never as
/// "now"): since `nil == nil` compares equal, a bundle that lacks one of the two
/// still gets a *stable* signature. The cache therefore degrades to "reuse the
/// icon", never to "miss on every render".
struct IconSignature: Hashable, Codable {
    let bundleModified: Date?
    let manifestModified: Date?

    /// A bundle with neither part readable. Still a valid, stable signature.
    static let unknown = IconSignature(bundleModified: nil, manifestModified: nil)
}

enum IconCache {
    /// One entry per bundle path, tagged with the freshness signature it was
    /// captured at. The signature lives *inside* the entry rather than in the
    /// key, so an out-of-date icon is replaced instead of accumulating.
    private struct Entry {
        let signature: IconSignature
        let image: NSImage
    }

    private static var cache: [String: Entry] = [:]
    private static let lock = NSLock()

    /// Icon loader seam. Production reads through `NSWorkspace`; the headless
    /// self-test substitutes a counter so "same signature ⇒ cache hit" and
    /// "signature changed ⇒ re-read" can be asserted without a window server.
    static var loadIcon: (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) }

    /// - Parameters:
    ///   - path: the bundle path.
    ///   - signature: freshness signature captured at scan time. While it matches
    ///     the cached entry the icon is reused, so a normal render still never
    ///     re-reads the icon; once it differs — the app was updated in place — the
    ///     icon is re-read exactly once.
    static func icon(for path: String, signature: IconSignature) -> NSImage {
        lock.lock()
        if let hit = cache[path], hit.signature == signature {
            lock.unlock()
            return hit.image
        }
        lock.unlock()

        let image = loadIcon(path)

        lock.lock()
        cache[path] = Entry(signature: signature, image: image)
        lock.unlock()
        return image
    }

    static func clear() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}

/// Tracks which applications are currently running.
///
/// Querying `NSWorkspace.shared.runningApplications` per cell per frame is
/// expensive (it builds a fresh array of every running process), so the set is
/// maintained once and refreshed only when an app launches or quits.
enum RunningApps {
    private static var bundleIDs: Set<String> = []
    private static var paths: Set<String> = []
    private static var observers: [NSObjectProtocol] = []
    private static let lock = NSLock()

    static func start() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                refresh()
            }
        }
    }

    static func refresh() {
        let running = NSWorkspace.shared.runningApplications
        var ids = Set<String>()
        var urls = Set<String>()
        for app in running {
            if let id = app.bundleIdentifier { ids.insert(id) }
            if let path = app.bundleURL?.path { urls.insert(path) }
        }
        lock.lock()
        bundleIDs = ids
        paths = urls
        lock.unlock()
    }

    static func isRunning(bundleID: String?, path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let bundleID, bundleIDs.contains(bundleID) { return true }
        return paths.contains(path)
    }

    /// Snapshot for callers that need to react to a change.
    static func runningBundleIDs() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return bundleIDs
    }
}
