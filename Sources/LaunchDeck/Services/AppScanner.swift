import Foundation
import AppKit
import CoreServices

/// Discovers installed applications, mirroring what Launchpad would show.
enum AppScanner {
    /// Directories that macOS treats as application locations.
    static var searchRoots: [String] {
        var roots = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices/Applications",
            "/Applications/Utilities",
            // Where cryptex apps (Safari and friends) actually live.
            "/System/Cryptexes/App/System/Applications",
        ]
        let home = NSHomeDirectory()
        roots.append(home + "/Applications")
        return roots
    }

    /// Scan all roots and return a de-duplicated, name-sorted list.
    static func scan() -> [AppInfo] {
        var seenPaths = Set<String>()
        var seenBundleIDs = Set<String>()
        var result: [AppInfo] = []

        for root in searchRoots {
            for url in appBundles(in: root) {
                let path = url.path
                guard !seenPaths.contains(path) else { continue }

                guard let info = makeAppInfo(url: url) else { continue }

                // Prefer the first occurrence of a given bundle id.
                if let bid = info.bundleID {
                    if seenBundleIDs.contains(bid) { continue }
                    seenBundleIDs.insert(bid)
                }
                seenPaths.insert(path)
                result.append(info)
            }
        }

        return result.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Enumerate `.app` bundles up to two levels deep under `root`.
    private static func appBundles(in root: String) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else { return [] }
        var found: [URL] = []

        // Deliberately *not* `.skipsHiddenFiles`: Foundation resolves symlinks
        // while applying that option, and on macOS 26 several system apps are
        // symlinks into the Cryptex volume (Safari among them), so they were
        // silently dropped from the scan. Dot-files are filtered by name instead.
        func children(of dir: URL) -> [URL] {
            let entries = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )) ?? []
            return entries.filter { !$0.lastPathComponent.hasPrefix(".") }
        }

        let rootURL = URL(fileURLWithPath: root)
        for entry in children(of: rootURL) {
            if entry.pathExtension == "app" {
                found.append(entry)
            } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                // One level of nesting, e.g. /Applications/Adobe/Photoshop.app
                for sub in children(of: entry) where sub.pathExtension == "app" {
                    found.append(sub)
                }
            }
        }
        return found
    }

    private static func makeAppInfo(url: URL) -> AppInfo? {
        guard let bundle = Bundle(url: url) else { return nil }
        let info = bundle.infoDictionary ?? [:]

        // Note: LSUIElement apps are deliberately *not* filtered out. Launchpad
        // shows them (Mission Control, Screenshot, Tips and friends all live in
        // the standard Applications folders with that flag set), and dropping
        // them both diverged from Launchpad and made layout imports lose apps.

        // Some bundles ship an empty CFBundleDisplayName/CFBundleName, so an
        // empty string must fall through to the filename too.
        let candidates = [
            info["CFBundleDisplayName"] as? String,
            info["CFBundleName"] as? String,
            url.deletingPathExtension().lastPathComponent,
        ]
        let name = candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? url.deletingPathExtension().lastPathComponent

        // One metadata read backs "date added" and the bundle half of the
        // freshness signature `IconCache` compares to notice an app updated in
        // place.
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        // The manifest is read separately and best-effort: its mtime also moves
        // when an updater rewrites `Info.plist` without replacing the bundle's own
        // entries. A missing manifest yields `nil`, which `IconSignature` treats as
        // a stable value rather than a cache miss.
        let manifest = url.appendingPathComponent("Contents/Info.plist")
        let manifestModified = (try? manifest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

        return AppInfo(
            path: url.path,
            bundleID: bundle.bundleIdentifier,
            name: name,
            addedDate: values?.creationDate,
            lastUsedDate: lastUsedDate(for: url),
            iconSignature: IconSignature(
                bundleModified: values?.contentModificationDate,
                manifestModified: manifestModified
            )
        )
    }

    /// Read `kMDItemLastUsedDate` from Spotlight metadata, when indexed.
    private static func lastUsedDate(for url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
