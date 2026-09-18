import AppKit
import CoreImage
import ImageIO

/// Where the desktop picture actually comes from.
enum WallpaperResolution {
    /// A single static image file.
    case file(URL)
    /// A folder of images (macOS "shuffle" wallpaper); one is shown at a time.
    case folder(URL, [URL])
    case unavailable

    /// Human readable summary for the settings window.
    var description: String {
        switch self {
        case .file(let url):
            return "Single image: \(url.lastPathComponent)"
        case .folder(let dir, let images):
            return "Rotating: \(images.count) image(s) from \(dir.lastPathComponent)"
        case .unavailable:
            return "Not detected"
        }
    }
}

/// Supplies the desktop wallpaper for a screen, optionally frosted.
///
/// `NSWorkspace.desktopImageURL(for:)` is not enough on its own: when the
/// desktop is a *shuffling photo album* (very common) it returns the system
/// default picture instead of the user's photos, which is why the deck used to
/// show a stock wallpaper. The real source is described in the macOS wallpaper
/// store, so that is read first.
enum WallpaperProvider {
    /// A bounded cache of decoded bitmaps.
    ///
    /// Bounded on purpose. These are `static` and the process is resident for
    /// days, while the key contains the image path — and `currentImageURL`
    /// deliberately rotates through the user's photo album every 30 minutes.
    /// Nothing evicted an entry except a wallpaper/Space/mode change, so the
    /// dictionary grew with wall-clock time at several MB per full-screen bitmap,
    /// multiplied by the blur-radius slider's 19 steps for the glass cache.
    private struct ImageCache {
        private var storage: [String: NSImage] = [:]
        /// Generous: an ordinary session uses one screen, one wallpaper and one
        /// blur radius, so this is only reached after hours of album rotation.
        private static let limit = 12

        subscript(key: String) -> NSImage? {
            get { storage[key] }
            set {
                storage[key] = newValue
                // Clear wholesale rather than evict an LRU: the entries are
                // interchangeable (any one re-renders in a few milliseconds), so
                // the simplest thing that bounds memory is the one least likely
                // to be got wrong.
                if storage.count > Self.limit { storage.removeAll() }
            }
        }

        mutating func removeAll() { storage.removeAll() }
    }

    private static var imageCache = ImageCache()
    private static var glassCache = ImageCache()
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Resolution

    /// Read the desktop choice out of the macOS wallpaper store.
    static func resolve(for screen: NSScreen) -> WallpaperResolution {
        if let pinned = DeckSettings.shared.pinnedWallpaperPath {
            let url = URL(fileURLWithPath: pinned)
            if FileManager.default.fileExists(atPath: pinned) { return .file(url) }
        }

        if let folder = shuffleFolder() {
            let images = imageFiles(in: folder)
            if !images.isEmpty { return .folder(folder, images) }
        }

        if let url = NSWorkspace.shared.desktopImageURL(for: screen),
           FileManager.default.fileExists(atPath: url.path) {
            return .file(url)
        }
        return .unavailable
    }

    /// The folder behind a "shuffle" desktop, if the current choice is one.
    private static func shuffleFolder() -> URL? {
        let store = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let data = try? Data(contentsOf: store),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any] else { return nil }

        var candidates: [[String: Any]] = []
        if let displays = root["Displays"] as? [String: Any] {
            for value in displays.values {
                guard let display = value as? [String: Any],
                      let desktop = display["Desktop"] as? [String: Any] else { continue }
                candidates.append(desktop)
            }
        }
        if let all = root["AllSpacesAndDisplays"] as? [String: Any],
           let desktop = all["Desktop"] as? [String: Any] {
            candidates.append(desktop)
        }

        for candidate in candidates {
            guard let content = candidate["Content"] as? [String: Any],
                  let choices = content["Choices"] as? [[String: Any]] else { continue }
            for choice in choices {
                if let folder = folderURL(fromChoice: choice) { return folder }
            }
        }
        return nil
    }

    /// Decode a wallpaper choice's `Configuration` blob into a folder URL.
    private static func folderURL(fromChoice choice: [String: Any]) -> URL? {
        guard let blob = choice["Configuration"] as? Data,
              let config = try? PropertyListSerialization.propertyList(from: blob, options: [], format: nil),
              let dict = config as? [String: Any] else { return nil }

        // "userAddedPhotoShuffle" carries no URL; it always means this folder.
        if let type = dict["type"] as? String, type == "userAddedPhotoShuffle" {
            return defaultPhotosFolder()
        }
        if let urlField = dict["url"] as? [String: Any],
           let relative = urlField["relative"] as? String,
           let url = URL(string: relative) {
            return url
        }
        return nil
    }

    private static func defaultPhotosFolder() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/com.apple.desktop.photos")
    }

    /// Image files inside a folder.
    private static func imageFiles(in folder: URL) -> [URL] {
        // Not `.skipsHiddenFiles`: Foundation resolves symlinks while applying
        // it, and macOS stores some album entries as symlinks into ~/Pictures,
        // so those photos would be dropped. Filter dot-files by name instead.
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [] }

        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"]
        return entries
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .filter { FileManager.default.isReadableFile(atPath: $0.path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Choosing which image

    /// The image the desktop should be showing right now.
    ///
    /// macOS picks a shuffle image at random and records nothing, so an exact
    /// match is impossible without Screen Recording. Instead the choice is made
    /// deterministically per rotation slot, so the backdrop changes on the same
    /// cadence as the desktop and always shows one of the user's own photos.
    static func currentImageURL(for screen: NSScreen) -> URL? {
        switch resolve(for: screen) {
        case .file(let url):
            return url
        case .folder(_, let images):
            guard !images.isEmpty else { return nil }
            let interval = 30 * 60
            let slot = Int(Date().timeIntervalSince1970 / Double(interval))
            return images[abs(slot) % images.count]
        case .unavailable:
            return nil
        }
    }

    // MARK: - Images

    /// The desktop picture, downscaled to the screen's pixel size.
    ///
    /// Downscaling is not cosmetic: these photos can be 4000 px wide, and
    /// compositing a full-resolution image every frame is what made the deck
    /// feel like it was running at a low frame rate.
    static func wallpaper(for screen: NSScreen) -> NSImage? {
        guard let url = currentImageURL(for: screen) else { return nil }
        let key = cacheKey(url: url, screen: screen)
        if let hit = imageCache[key] { return hit }

        guard let image = downscaledImage(at: url, for: screen) else { return nil }
        imageCache[key] = image
        return image
    }

    /// A downscaled image loaded from an explicit path (a pinned backdrop).
    static func image(at path: String, for screen: NSScreen) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        let key = cacheKey(url: url, screen: screen)
        if let hit = imageCache[key] { return hit }
        guard let image = downscaledImage(at: url, for: screen) else { return nil }
        imageCache[key] = image
        return image
    }

    /// A blurred version of an explicit path.
    static func blurredFile(at path: String, radius: Double, for screen: NSScreen) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        let key = cacheKey(url: url, screen: screen) + "|blur|\(radius)"
        if let hit = glassCache[key] { return hit }
        guard let base = image(at: path, for: screen),
              let result = blur(base, radius: radius) else { return nil }
        glassCache[key] = result
        return result
    }

    /// A blurred version of the current desktop picture.
    static func blurredWallpaper(for screen: NSScreen, radius: Double) -> NSImage? {
        guard let url = currentImageURL(for: screen) else { return nil }
        let key = cacheKey(url: url, screen: screen) + "|blur|\(radius)"
        if let hit = glassCache[key] { return hit }
        guard let base = wallpaper(for: screen),
              let result = blur(base, radius: radius) else { return nil }
        glassCache[key] = result
        return result
    }

    private static func blur(_ base: NSImage, radius: Double) -> NSImage? {
        guard let tiff = base.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cg = bitmap.cgImage else { return nil }

        let input = CIImage(cgImage: cg)
        var output = input
        if let filter = CIFilter(name: "CIGaussianBlur") {
            filter.setValue(input, forKey: kCIInputImageKey)
            filter.setValue(radius, forKey: kCIInputRadiusKey)
            if let blurred = filter.outputImage {
                output = blurred.clampedToExtent().cropped(to: input.extent)
            }
        }
        guard let rendered = ciContext.createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: rendered, size: base.size)
    }

    /// The frosted version used behind the grid.
    static func glassWallpaper(for screen: NSScreen) -> NSImage? {
        guard let url = currentImageURL(for: screen) else { return nil }
        let key = cacheKey(url: url, screen: screen) + "|glass|\(DeckSettings.shared.blurRadius)"
        if let hit = glassCache[key] { return hit }

        guard let base = wallpaper(for: screen),
              let tiff = base.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cg = bitmap.cgImage else { return nil }

        let input = CIImage(cgImage: cg)
        var output = input

        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(input, forKey: kCIInputImageKey)
            blur.setValue(DeckSettings.shared.blurRadius, forKey: kCIInputRadiusKey)
            if let blurred = blur.outputImage {
                output = blurred.clampedToExtent().cropped(to: input.extent)
            }
        }
        // Frosted glass reads as slightly more saturated and dimmer than the
        // raw picture, which is what lets icons sit on top of it legibly.
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(output, forKey: kCIInputImageKey)
            controls.setValue(1.35, forKey: kCIInputSaturationKey)
            controls.setValue(-0.06, forKey: kCIInputBrightnessKey)
            controls.setValue(1.02, forKey: kCIInputContrastKey)
            if let adjusted = controls.outputImage { output = adjusted }
        }

        guard let rendered = ciContext.createCGImage(output, from: input.extent) else { return nil }
        let image = NSImage(cgImage: rendered, size: base.size)
        glassCache[key] = image
        return image
    }

    /// Decode only as many pixels as the screen can display.
    private static func downscaledImage(at url: URL, for screen: NSScreen) -> NSImage? {
        let maxPixel = max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return NSImage(contentsOf: url)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func cacheKey(url: URL, screen: NSScreen) -> String {
        "\(url.path)|\(Int(screen.frame.width))x\(Int(screen.frame.height))@\(screen.backingScaleFactor)"
    }

    /// Drop caches so a wallpaper change is picked up.
    static func invalidate() {
        imageCache.removeAll()
        glassCache.removeAll()
    }
}
