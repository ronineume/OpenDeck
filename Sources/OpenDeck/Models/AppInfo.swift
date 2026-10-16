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
    /// on every render. Full-size — the drag image and the settings/search
    /// previews draw it directly.
    var icon: NSImage {
        IconCache.icon(for: path, signature: iconSignature)
    }

    /// A rasterisation sized to the cell that will draw the icon, retina-crisp
    /// and with headroom for the hover zoom — see `IconCache.raster`.
    ///
    /// `IconCache` produced a raw 1024 pt `NSImage`; drawing that at 86 pt
    /// resamples a 2048 px bitmap down to ~172 px on the compositor every
    /// frame, per icon, over the whole deck. This delivers the same picture at
    /// a size the layer can use 1:1 instead.
    ///
    /// The extra 12 % above the point size keeps the 1.06 hover scale sharp
    /// (rasterised, then zoomed, it would otherwise blur). The full-size icon
    /// stays available through `icon` for the drag image and previews.
    func rasterIcon(at pointSize: CGFloat) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return IconCache.raster(for: path, signature: iconSignature,
                                maxPixel: pointSize * scale * 1.12)
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
    /// True when the **user** asked for this folder on purpose (the "New Folder"
    /// menu item) rather than it being carved out of a drag.
    ///
    /// It exists for exactly one reason: to let a folder hold fewer than two
    /// members. Every path that can *shrink* a folder asks
    /// `dissolves(memberCount:isExplicit:)` instead of comparing counts itself,
    /// so the two kinds of folder stay distinguishable in one place.
    var isUserCreated: Bool

    init(id: UUID = UUID(),
         name: String = "Folder",
         appIDs: [String] = [],
         isUserCreated: Bool = false) {
        self.id = id
        self.name = name
        self.appIDs = appIDs
        self.isUserCreated = isUserCreated
    }

    private enum CodingKeys: String, CodingKey { case id, name, appIDs, isUserCreated }

    /// Written by hand rather than synthesised: `isUserCreated` post-dates the
    /// on-disk format, and a synthesised decoder **throws on a missing key**,
    /// which the loader reads as corruption (A1) — so every layout file written
    /// before this field existed would be sent down the recovery path. Absent
    /// means `false`, which is exactly the old behaviour.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        appIDs = try c.decode([String].self, forKey: .appIDs)
        isUserCreated = try c.decodeIfPresent(Bool.self, forKey: .isUserCreated) ?? false
    }

    /// The single rule for "does this folder still exist?".
    ///
    /// A folder means *several apps behind one slot*, so one member is not a
    /// folder — it is an app (`reconcile`'s wording). The one exception is a
    /// folder the user created by hand, which is allowed to wait for its second
    /// member. **Zero members is never a folder**, whoever created it: the
    /// point of a folder is to hold apps, and its slot has nothing left to show.
    ///
    /// This is a function, not a count comparison, precisely so every site that
    /// asks it cannot drift apart — report 39's X90 lesson ("make the duplicate
    /// point disappear rather than wrap it again"). The four paths that can
    /// shrink a folder are `removeFromFolder`, `detachFromAnyFolder`, `reconcile`
    /// and `normalizeFolderExclusivity`; each has its own mutation (M99–M101,
    /// M98) so a future edit that reverts one of them cannot pass unnoticed.
    static func dissolves(memberCount: Int, isExplicit: Bool) -> Bool {
        if memberCount <= 0 { return true }
        return memberCount < 2 && !isExplicit
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
