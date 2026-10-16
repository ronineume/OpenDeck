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
    /// Downscaled rasterisations, keyed by `path|maxPixel`. The full-size icons
    /// above are 1024 pt (a 2048 px rep); `AppCell` draws them at ~86 pt, so the
    /// compositor was resampling a 2048 px bitmap down to ~172 px **per icon, per
    /// frame** — the same full-resolution-per-frame cost the wallpaper path
    /// already pays to avoid (see `WallpaperProvider`). Caching a rep sized to
    /// the display removes that resampling while the deck is drawn.
    ///
    /// Keyed by the requested pixel budget so the raw-icon path (settings,
    /// search, etc.) keeps its own full-size entry. Sealed with the signature
    /// exactly like the raw cache, so an in-place app update lands fresh.
    private static var rasterCache: [String: Entry] = [:]
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

    /// A rasterised icon sized to at most `maxPixel` pixels on its longest edge,
    /// for a layer that will draw it at a fixed, small size.
    ///
    /// This is the delivery path `AppCell` and `FolderCell` render through. A
    /// 1024 pt `NSImage` (a 2048 px rep) resampled by the compositor once per
    /// icon per frame is what a full-screen deck of 100+ tiles pays for; the
    /// same rasterisation drawn from a small cached rep costs a texture blit
    /// instead. It reads the full-size icon through the same seam as
    /// `icon(for:signature:)`, so a slice out of the raw `NSImage` retains the
    /// retina/rounded-rect treatment `NSWorkspace` bakes in per tile.
    ///
    /// This is a rendering optimisation OpenDeck owns, not a decoded LaunchOS
    /// constant: it changes the *transport*, never the look — the resample is the
    /// same image scaled to the size the cell would have used regardless.
    static func raster(for path: String, signature: IconSignature,
                        maxPixel: CGFloat) -> NSImage {
        let pixel = max(Int(maxPixel.rounded(.up)), 1)
        let key = "\(path)|\(pixel)"

        lock.lock()
        if let hit = rasterCache[key], hit.signature == signature {
            lock.unlock()
            return hit.image
        }
        lock.unlock()

        // Read the full-size icon *outside* the lock: `icon(for:signature:)`
        // locks the same non-recursive `NSLock`, so holding it across that call
        // is a self-deadlock — the real render harness hangs on the very first
        // frame the grid draws. (The pure-model self-test never builds `AppCell`,
        // so it never reaches here and cannot catch it.)
        let full = Self.icon(for: path, signature: signature)
        let raster = resized(full, maxPixels: CGFloat(pixel))

        lock.lock()
        // Bounded: the icons are a handful of distinct sizes, so this only
        // clears after many hours of changing grid presets, exactly as
        // `WallpaperProvider`'s bitmap cache is bounded.
        if rasterCache.count > 512 { rasterCache.removeAll() }
        rasterCache[key] = Entry(signature: signature, image: raster)
        lock.unlock()
        return raster
    }

    /// Draws `image` down to at most `maxPixels` on its longest edge, producing
    /// a bitmap rep sized in the points the caller will draw it at.
    ///
    /// The rep is produced at high interpolation into a raw `NSBitmapImageRep`,
    /// then re-wrapped in an `NSImage` whose point size equals its pixel size —
    /// so a SwiftUI `.frame(iconSize)` draws the rep at a 1:1 scale on the tile
    /// and the compositor has nothing left to resample. Icons that are already
    /// within budget are returned untouched, so a low-DPI external display is
    /// never given an upscale it does not need.
    private static func resized(_ image: NSImage, maxPixels: CGFloat) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        let wide = CGFloat(cg.width), tall = CGFloat(cg.height)
        guard wide > 0, tall > 0 else { return image }

        // Never upscale: an icon smaller than the budget is returned as-is.
        guard max(wide, tall) > maxPixels else { return image }

        let scale = maxPixels / max(wide, tall)
        let pxWide = max(1, Int((wide * scale).rounded()))
        let pxHigh = max(1, Int((tall * scale).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pxWide,
            pixelsHigh: pxHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return image }

        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pxWide, height: pxHigh))
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: NSSize(width: pxWide, height: pxHigh))
        out.addRepresentation(rep)
        return out
    }

    static func clear() {
        lock.lock()
        cache.removeAll()
        rasterCache.removeAll()
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
