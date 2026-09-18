import AppKit

/// How a leftover file was attributed to an app. The distinction is the whole
/// point, because one of the two ways is a guess.
///
/// A bundle-identifier hit is authoritative: `com.apple.Safari` in the path
/// means it is Safari's. A display-name hit is a substring match, and
/// substrings cross vendors — "Code" matches `com.tencent.codebuddycn`,
/// `CodeBuddyExtension` and `Codex`; "Preview" matches `MobileSMSPreview`;
/// the classic pair is **Photos ↔ Photoshop**. Only the authoritative kind is
/// allowed to be checked by default.
enum UninstallMatch: String, Hashable {
    /// The entry's name contains the app's bundle identifier.
    case identifier
    /// The entry's name merely contains the app's display name.
    case nameOnly

    var label: String {
        switch self {
        case .identifier: return "matches identifier"
        case .nameOnly: return "name match only"
        }
    }
}

/// A file or folder that belongs to an installed application.
struct UninstallCandidate: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let isDirectory: Bool
    let size: Int64
    /// Why this entry was attributed to the app.
    let matchKind: UninstallMatch

    var url: URL { URL(fileURLWithPath: path) }

    var displayName: String { (path as NSString).lastPathComponent }

    /// Path with the home directory collapsed to `~` for readability.
    var displayPath: String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Finds and removes an application together with its leftover files.
enum AppUninstaller {
    /// Locations that hold per-app state, paired with whether they need
    /// Full Disk Access to enumerate.
    private static var searchRoots: [String] {
        let home = NSHomeDirectory()
        return [
            home + "/Library/Application Support",
            home + "/Library/Caches",
            home + "/Library/Preferences",
            home + "/Library/Logs",
            home + "/Library/Saved Application State",
            home + "/Library/Containers",
            home + "/Library/Group Containers",
            home + "/Library/WebKit",
            home + "/Library/HTTPStorages",
            home + "/Library/Cookies",
            home + "/Library/LaunchAgents",
            home + "/Library/Application Scripts",
        ]
    }

    /// Collect files whose name matches the app's bundle identifier or name,
    /// tagged with **why** each one matched.
    ///
    /// The tag matters more than the list does. A display-name hit is a substring
    /// match, and substrings cross vendors — "Code" hits `Codex`, "Preview" hits
    /// `MobileSMSPreview`, "Photos" hits `Photoshop`. Callers get both kinds so
    /// that nothing is hidden behind the scenes, but they must not treat them as
    /// equivalent: only identifier matches may be pre-selected for deletion.
    static func relatedFiles(for app: AppInfo) -> [UninstallCandidate] {
        let fm = FileManager.default
        var identifiers: [String] = []
        if let bid = app.bundleID?.lowercased(), bid.count > 3 { identifiers.append(bid) }
        // Also match the display name, which is how many vendors name their folders.
        let nameNeedle = app.name.count > 3 ? app.name.lowercased() : nil

        var results: [UninstallCandidate] = []
        for root in searchRoots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries {
                let lower = entry.lowercased()
                // Identifier wins: an entry that names the bundle id belongs to
                // this app, whatever else it happens to look like.
                let kind: UninstallMatch
                if identifiers.contains(where: { lower.contains($0) }) {
                    kind = .identifier
                } else if let nameNeedle, lower.contains(nameNeedle) {
                    kind = .nameOnly
                } else {
                    continue
                }
                let full = root + "/" + entry
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                results.append(
                    UninstallCandidate(
                        path: full,
                        isDirectory: isDir.boolValue,
                        size: size(of: full, isDirectory: isDir.boolValue),
                        matchKind: kind
                    )
                )
            }
        }

        // Authoritative matches first, then biggest first: the list is read
        // top-down, so the entries the user can trust should be the ones on top.
        return results.sorted {
            if $0.matchKind != $1.matchKind { return $0.matchKind == .identifier }
            return $0.size > $1.size
        }
    }

    /// Recursively total the size of a file or directory.
    static func size(of path: String, isDirectory: Bool) -> Int64 {
        let fm = FileManager.default
        if !isDirectory {
            let attrs = try? fm.attributesOfItem(atPath: path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        for case let child as String in enumerator {
            let full = path + "/" + child
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let bytes = attrs[.size] as? NSNumber else { continue }
            total += bytes.int64Value
        }
        return total
    }

    /// Move the selected files to the Trash.
    /// - Returns: paths that could not be removed.
    @discardableResult
    static func trash(_ candidates: [UninstallCandidate]) -> [String] {
        var failures: [String] = []
        for candidate in candidates {
            do {
                try FileManager.default.trashItem(at: candidate.url, resultingItemURL: nil)
            } catch {
                NSLog("LaunchDeck: could not trash \(candidate.path): \(error.localizedDescription)")
                failures.append(candidate.path)
            }
        }
        return failures
    }

    /// Remove a stubborn item (typically an app in /Applications owned by root)
    /// by asking for administrator rights through Finder.
    ///
    /// Returns whether the files are **actually gone**. The AppleScript's own
    /// error is not enough: it reports "the source didn't compile / didn't run",
    /// not "the file was deleted", so a silent no-op used to be reported as
    /// success. Each path is re-checked after the script runs.
    static func trashWithAuthorization(_ candidates: [UninstallCandidate]) -> Bool {
        let list = candidates
            .map { "\"\($0.path.appleScriptLiteral)\"" }
            .joined(separator: ", ")
        guard !list.isEmpty else { return true }

        let script = """
        set theFiles to {\(list)}
        repeat with f in theFiles
            tell application "Finder" to delete (POSIX file (f as text) as alias)
        end repeat
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            NSLog("LaunchDeck: authorized delete failed: \(error)")
        }
        let remaining = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !remaining.isEmpty {
            NSLog("LaunchDeck: authorized delete left \(remaining.count) of \(candidates.count) item(s) in place")
        }
        return remaining.isEmpty
    }

    /// Rough, human readable byte count.
    static func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
