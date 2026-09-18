import Foundation
import AppKit

/// A launchable application discovered on disk.
struct AppInfo: Identifiable, Hashable, Codable {
    /// Stable identity: bundle identifier when available, otherwise the path.
    var id: String { bundleID ?? path }

    let path: String
    let bundleID: String?
    let name: String
    /// When the bundle was added to disk (approximates "date added").
    let addedDate: Date?
    /// Last time the app was launched, from Spotlight metadata.
    let lastUsedDate: Date?
    /// The bundle's freshness signature, captured at scan time. Compared by
    /// `IconCache`, so an app updated in place gets a fresh icon without any
    /// explicit invalidation call from the UI.
    let iconSignature: IconSignature

    var url: URL { URL(fileURLWithPath: path) }

    /// Resolved icon. Backed by `IconCache` because this is read once per cell
    /// on every render.
    var icon: NSImage {
        IconCache.icon(for: path, signature: iconSignature)
    }

    init(path: String, bundleID: String?, name: String, addedDate: Date?, lastUsedDate: Date?, iconSignature: IconSignature = .unknown) {
        self.path = path
        self.bundleID = bundleID
        self.name = name
        self.addedDate = addedDate
        self.lastUsedDate = lastUsedDate
        self.iconSignature = iconSignature
    }
}

/// How the grid should be ordered.
enum SortKey: String, Codable, CaseIterable, Identifiable {
    case manual
    case name
    case dateAdded
    case lastUsed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: return "Custom"
        case .name: return "Name"
        case .dateAdded: return "Date Added"
        case .lastUsed: return "Last Used"
        }
    }
}

enum SortOrder: String, Codable, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: String { rawValue }

    var label: String { self == .ascending ? "Ascending" : "Descending" }
}

/// A folder groups several apps under one grid slot.
struct AppFolder: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var appIDs: [String]

    init(id: UUID = UUID(), name: String = "Folder", appIDs: [String] = []) {
        self.id = id
        self.name = name
        self.appIDs = appIDs
    }
}

/// One item occupying a grid slot: either a single app or a folder.
enum DeckSlot: Identifiable, Hashable {
    case app(String)
    case folder(UUID)

    var id: String {
        switch self {
        case .app(let id): return "app:\(id)"
        case .folder(let id): return "folder:\(id.uuidString)"
        }
    }
}

/// A page is an ordered list of grid items.
struct Page: Codable, Hashable {
    var items: [String]  // encoded DeckSlot ids
}
