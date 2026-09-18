import Foundation
import SQLite3

/// A layout read out of macOS's own Launchpad database.
struct ImportedLayout {
    enum Slot {
        case app(bundleID: String, title: String)
        case folder(name: String, members: [String])
    }

    let pages: [[Slot]]
    let databasePath: String

    var appCount: Int {
        pages.flatMap { $0 }.reduce(0) { total, slot in
            switch slot {
            case .app: return total + 1
            case .folder(_, let members): return total + members.count
            }
        }
    }

    var folderCount: Int {
        pages.flatMap { $0 }.filter { if case .folder = $0 { return true } else { return false } }.count
    }
}

/// Reads macOS's Launchpad layout so it can be recreated in LaunchDeck.
///
/// The database survives the removal of Launchpad in macOS 26; it lives in the
/// per-user temp directory rather than `~/Library/Application Support/Dock`.
/// Folders there are stored as *two* nested groups: an outer group carrying the
/// folder name and a single inner group holding the member apps.
enum LaunchpadImporter {
    /// Every place macOS has been observed to keep the database.
    ///
    /// On macOS 26 it sits in the per-user cache container *next to* TMPDIR
    /// (`…/<hash>/0/`), not inside it, so deriving it from `NSTemporaryDirectory()`
    /// alone is not enough.
    static func databaseCandidates() -> [URL] {
        var candidates: [URL] = []
        let relative = "com.apple.dock.launchpad/db/db"

        // …/<hash>/0/ and …/<hash>/C/, i.e. the siblings of TMPDIR.
        let container = URL(fileURLWithPath: NSTemporaryDirectory()).deletingLastPathComponent()
        for sub in ["0", "C", "T"] {
            candidates.append(container.appendingPathComponent("\(sub)/\(relative)"))
        }

        // Scan the per-user container roots as a fallback.
        for base in ["/private/var/folders", "/var/folders"] {
            guard let users = try? FileManager.default.contentsOfDirectory(atPath: base) else { continue }
            for user in users {
                let userDir = base + "/" + user
                guard let containers = try? FileManager.default.contentsOfDirectory(atPath: userDir) else { continue }
                for item in containers where item != "T" && item != "0" {
                    candidates.append(URL(fileURLWithPath: "\(userDir)/\(item)/\(relative)"))
                }
            }
        }

        // The classic location, still used on older releases.
        candidates.append(
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/Dock")
        )
        return candidates
    }

    /// Best-effort discovery of the live database.
    static func locateDatabase() -> URL? {
        let fm = FileManager.default
        for candidate in databaseCandidates() {
            // Decide by what is actually on disk: the database file itself has
            // no path extension, so pathExtension is not a usable signal.
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                // A folder: look for the newest .db inside.
                guard let entries = try? fm.contentsOfDirectory(
                    at: candidate,
                    includingPropertiesForKeys: [.contentModificationDateKey]
                ) else { continue }
                let dbs = entries
                    .filter { $0.pathExtension == "db" }
                    .sorted { a, b in
                        let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                        let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                        return da > db
                    }
                if let newest = dbs.first { return newest }
            } else {
                return candidate
            }
        }
        return nil
    }

    /// Parse the database at `url`.
    ///
    /// The file is copied to a temporary location first: SQLite may need to
    /// touch the write-ahead log, and the live database belongs to the Dock.
    static func load(from url: URL) -> ImportedLayout? {
        guard let copy = copyForReading(url) else { return nil }
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        return parse(databaseAt: copy.path, originalPath: url.path)
    }

    private static func copyForReading(_ url: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("launchdeck-import-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // The WAL and shared-memory sidecars travel with the database.
            for suffix in ["", "-wal", "-shm"] {
                let source = url.path + suffix
                if fm.fileExists(atPath: source) {
                    try fm.copyItem(atPath: source, toPath: dir.appendingPathComponent("db" + suffix).path)
                }
            }
        } catch {
            NSLog("LaunchDeck: could not stage the Launchpad database: \(error)")
            try? fm.removeItem(at: dir)
            return nil
        }
        return dir.appendingPathComponent("db")
    }

    private static func parse(databaseAt path: String, originalPath: String) -> ImportedLayout? {
        // The Launchpad database is in WAL mode. A read-only open fails with
        // SQLITE_CANTOPEN once the Dock has reclaimed the -shm sidecar, because
        // SQLite would have to create it. The opened file is our own staged
        // copy, never the live one, so opening it read-write is safe and lets
        // SQLite manage the write-ahead log in the temporary directory.
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            NSLog("LaunchDeck: could not open the staged Launchpad database")
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }

        // item rowid -> (type, parent, ordering)
        var type: [Int64: Int64] = [:]
        var parent: [Int64: Int64] = [:]
        var ordering: [Int64: Int64] = [:]
        if let rows = query(handle, "SELECT rowid, type, parent_id, ordering FROM items") {
            for row in rows {
                guard row.count == 4,
                      let id = row[0].int, let t = row[1].int,
                      let p = row[2].int, let o = row[3].int else { continue }
                type[id] = t
                parent[id] = p
                ordering[id] = o
            }
        }
        guard !type.isEmpty else { return nil }

        var apps: [Int64: (title: String, bundleID: String)] = [:]
        if let rows = query(handle, "SELECT item_id, title, bundleid FROM apps") {
            for row in rows {
                guard row.count == 3, let id = row[0].int else { continue }
                apps[id] = (row[1].text ?? "", row[2].text ?? "")
            }
        }

        var groupTitles: [Int64: String] = [:]
        if let rows = query(handle, "SELECT item_id, title FROM groups") {
            for row in rows {
                guard let id = row[0].int else { continue }
                groupTitles[id] = row[1].text ?? ""
            }
        }

        var rootID: Int64 = 1
        if let rows = query(handle, "SELECT value FROM dbinfo WHERE key = 'launchpad_root'"),
           let value = rows.first?.first?.text, let parsed = Int64(value) {
            rootID = parsed
        }

        // Children per parent, ordered exactly as Launchpad shows them.
        var children: [Int64: [Int64]] = [:]
        for (id, p) in parent where id != rootID {
            children[p, default: []].append(id)
        }
        for key in children.keys {
            children[key]?.sort { (ordering[$0] ?? 0) < (ordering[$1] ?? 0) }
        }

        let appType: Int64 = 4
        // Groups come in two flavours in this schema: type 3 for pages and for
        // the outer, named folder group, and type 2 for the inner group that
        // actually holds the folder's member apps. Treating only type 3 as a
        // group silently drops every folder.
        let groupTypes: Set<Int64> = [2, 3]

        func appMembers(of group: Int64, depth: Int = 0) -> [String] {
            var out: [String] = []
            for child in children[group] ?? [] {
                let childType = type[child] ?? 0
                if childType == appType, let app = apps[child] {
                    out.append(app.bundleID.isEmpty ? app.title : app.bundleID)
                } else if groupTypes.contains(childType), depth < 3 {
                    out.append(contentsOf: appMembers(of: child, depth: depth + 1))
                }
            }
            return out
        }

        func groupTitle(of group: Int64, depth: Int = 0) -> String {
            if let title = groupTitles[group], !title.isEmpty { return title }
            guard depth < 3 else { return "" }
            for child in children[group] ?? [] where groupTypes.contains(type[child] ?? 0) {
                let nested = groupTitle(of: child, depth: depth + 1)
                if !nested.isEmpty { return nested }
            }
            return ""
        }

        var pages: [[ImportedLayout.Slot]] = []
        for pageID in children[rootID] ?? [] {
            var slots: [ImportedLayout.Slot] = []
            for item in children[pageID] ?? [] {
                let itemType = type[item] ?? 0
                if itemType == appType, let app = apps[item] {
                    let bundleID = app.bundleID.isEmpty ? app.title : app.bundleID
                    slots.append(.app(bundleID: bundleID, title: app.title))
                } else if groupTypes.contains(itemType) {
                    let members = appMembers(of: item)
                    guard !members.isEmpty else { continue }
                    let name = groupTitle(of: item)
                    slots.append(.folder(name: name.isEmpty ? "Folder" : name, members: members))
                }
            }
            pages.append(slots)
        }

        // Drop leading/trailing empty pages but keep genuine gaps.
        while let first = pages.first, first.isEmpty { pages.removeFirst() }
        while let last = pages.last, last.isEmpty { pages.removeLast() }
        guard !pages.isEmpty else { return nil }

        return ImportedLayout(pages: pages, databasePath: originalPath)
    }

    // MARK: - SQLite helpers

    private struct Value {
        let text: String?
        let int: Int64?
    }

    private static func query(_ handle: OpaquePointer?, _ sql: String) -> [[Value]]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            NSLog("LaunchDeck: query failed: \(String(cString: sqlite3_errmsg(handle)))")
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let columnCount = Int(sqlite3_column_count(statement))
        var rows: [[Value]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [Value] = []
            for index in 0 ..< columnCount {
                let columnType = sqlite3_column_type(statement, Int32(index))
                // `sqlite3_column_text` converts a BLOB to its raw bytes and
                // returns a pointer to them, and `String(cString:)` **traps** —
                // it does not throw — on anything that is not valid UTF-8. All
                // four current queries read TEXT/INTEGER so this has never fired,
                // but that is a property of the queries, not of the data: one
                // BLOB column would take the process down. Decode with
                // replacement instead, so there is no crashing input at all.
                let text: String?
                if let bytes = sqlite3_column_text(statement, Int32(index)) {
                    // text-then-bytes is the order SQLite documents as safe.
                    let length = Int(sqlite3_column_bytes(statement, Int32(index)))
                    text = String(decoding: Data(bytes: bytes, count: length), as: UTF8.self)
                } else {
                    text = nil
                }
                let isNull = columnType == SQLITE_NULL
                row.append(Value(text: isNull ? nil : text,
                                 int: isNull ? nil : sqlite3_column_int64(statement, Int32(index))))
            }
            rows.append(row)
        }
        return rows
    }
}
