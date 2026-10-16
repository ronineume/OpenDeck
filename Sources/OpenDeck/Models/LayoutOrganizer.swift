import Foundation

/// Where folders sit relative to apps when the layout is reorganized.
///
/// LaunchOS `Folder Placement` (three options, `localization.json` en/zh-Hans):
/// `After Apps` / `Before Apps` / `Mixed with Apps`.
enum FolderPlacement: String, Codable, CaseIterable, Identifiable {
    case afterApps
    case beforeApps
    case mixedWithApps

    var id: String { rawValue }

    var label: String {
        switch self {
        case .afterApps: return "After Apps"
        case .beforeApps: return "Before Apps"
        case .mixedWithApps: return "Mixed with Apps"
        }
    }
}

/// Where Apple's own apps sit relative to everyone else's.
///
/// LaunchOS `Apple App Placement` — a **separate** setting from
/// `FolderPlacement` (report 52 §3: report 48 conflated the two). Options:
/// `After Other Apps` / `Before Other Apps` / `Mixed with Other Apps`.
enum AppleAppPlacement: String, Codable, CaseIterable, Identifiable {
    case afterOtherApps
    case beforeOtherApps
    case mixedWithOtherApps

    var id: String { rawValue }

    var label: String {
        switch self {
        case .afterOtherApps: return "After Other Apps"
        case .beforeOtherApps: return "Before Other Apps"
        case .mixedWithOtherApps: return "Mixed with Other Apps"
        }
    }
}

/// Which pages the reorganization touches.
///
/// LaunchOS `OrganizePageScope`: `All Pages` / `Selected Pages` (the per-page
/// checkbox list, with the `Select at least one page` validation).
enum OrganizePageScope: String, Codable, CaseIterable, Identifiable {
    case allPages
    case selectedPages

    var id: String { rawValue }

    var label: String {
        switch self {
        case .allPages: return "All Pages"
        case .selectedPages: return "Selected Pages"
        }
    }
}

/// The full rule set of LaunchOS's "Reorganize Layout" sheet.
///
/// Field order mirrors the sheet's option order as reversed in report 53:
/// page scope, across-pages, Apple placement, folder placement, sort
/// method/direction, sort-in-folders, ungroup-all.
struct OrganizeOptions: Codable, Hashable {
    var pageScope: OrganizePageScope = .allPages
    /// Pages (indices) chosen when `pageScope == .selectedPages`.
    var selectedPages: Set<Int> = []
    /// `Reorganize Across Pages` — one list across the scope, refilled page by
    /// page. Off = each page reorganized independently.
    var acrossPages: Bool = true
    var appleAppPlacement: AppleAppPlacement = .afterOtherApps
    var folderPlacement: FolderPlacement = .afterApps
    /// Only the three non-manual keys: Custom order is the user's own
    /// arrangement and "reorganizing" it would destroy exactly what it protects.
    var sortMethod: SortKey = .name
    var sortDirection: SortOrder = .ascending
    /// `Also Sort Apps in Folders` — apply the same key inside every folder.
    var alsoSortInFolders: Bool = false
    /// `Ungroup All Folders` — dissolve every in-scope folder first; members
    /// join the flat list.
    var ungroupAllFolders: Bool = false

    /// Pages the run will actually touch, given the live page count.
    ///
    /// An empty selection is the caller's error to surface (LaunchOS: "Select
    /// at least one page") — this returns empty rather than guessing "all".
    func scope(pageCount: Int) -> [Int] {
        switch pageScope {
        case .allPages:
            return Array(0 ..< max(pageCount, 0))
        case .selectedPages:
            return selectedPages.filter { $0 >= 0 && $0 < pageCount }.sorted()
        }
    }
}

/// The pure reorganization engine (LaunchOS "Reorganize Layout", report 53).
///
/// Takes the layout apart and puts it back together by the rules in
/// `OrganizeOptions`. **Pure**: no store, no I/O, no defaults — every input is
/// a parameter, so the whole rule set is assertable headlessly. The mutating
/// entry point is `DeckStore.reorganize(with:)`, which wraps this in one batch.
///
/// Semantics come from LaunchOS's own description strings (report 52 §1):
/// "Reorganize all apps and folders as a single layout, moving items between
/// pages when needed." Items outside the chosen scope are left untouched.
enum LayoutOrganizer {

    /// The outcome of one run: the new pages, the surviving folders, and how
    /// many pages were appended past the old last page.
    struct Result {
        var pages: [[DeckSlot]]
        var folders: [UUID: AppFolder]
        var appendedPages: Int
    }

    /// Reorganize `pages` in place according to `options`.
    ///
    /// - Parameters:
    ///   - apps: every known app, keyed by id — the source of names, dates and
    ///     Apple-ness for sorting and placement. Ids absent from it sort last
    ///     by name (a stale slot must not crash the run).
    ///   - capacity: slots per page, from `GridMetrics.capacity`.
    ///   - scopePages: the pages to touch; other pages keep their items.
    ///     Empty → no-op (the "Select at least one page" case).
    static func organize(pages: [[DeckSlot]],
                         folders: [UUID: AppFolder],
                         apps: [AppInfo],
                         capacity: Int,
                         options: OrganizeOptions,
                         scopePages: [Int]) -> Result {
        let cap = max(capacity, 1)
        var pages = pages
        var folders = folders
        guard !scopePages.isEmpty else {
            return Result(pages: pages, folders: folders, appendedPages: 0)
        }
        let scope = scopePages.sorted()

        // 1. Collect the in-scope slots in page order — the baseline order
        //    that stable sorting falls back to.
        var items: [DeckSlot] = []
        for p in scope where p < pages.count {
            items.append(contentsOf: pages[p])
        }
        if items.isEmpty {
            return Result(pages: pages, folders: folders, appendedPages: 0)
        }

        // 2. Ungroup-all happens first: every in-scope folder dissolves and
        //    its members join the flat list in member order.
        if options.ungroupAllFolders {
            var flat: [DeckSlot] = []
            for slot in items {
                switch slot {
                case .app:
                    flat.append(slot)
                case .folder(let id):
                    if let folder = folders[id] {
                        for member in folder.appIDs { flat.append(.app(member)) }
                        folders.removeValue(forKey: id)
                    }
                }
            }
            items = flat
        }

        // 3. Also-sort-in-folders rewrites folder membership in place; the
        //    folder tiles themselves keep their position in the flat list.
        if options.alsoSortInFolders {
            for slot in items {
                if case .folder(let id) = slot, var folder = folders[id] {
                    let members = folder.appIDs.compactMap { id in apps.first { $0.id == id } }
                    let ordered = members.sorted { compare($0, $1, options) }
                    folder.appIDs = ordered.map(\.id)
                    folders[id] = folder
                }
            }
        }

        // 4. Split, sort, and recompose by the placement rules.
        let ordered = recompose(items: items,
                                folders: folders,
                                apps: apps,
                                options: options)

        // 5. Refill.
        if options.acrossPages {
            // One list across the whole scope: walk the scope's pages in
            // order, handing each `cap` items; a leftover becomes a new page
            // appended after the last scope page.
            var cursor = 0
            var newPages: [[DeckSlot]] = []
            for p in scope where p < pages.count {
                let take = Array(ordered[cursor ..< min(cursor + cap, ordered.count)])
                newPages.append(take)
                cursor += take.count
            }
            while cursor < ordered.count {
                let take = Array(ordered[cursor ..< min(cursor + cap, ordered.count)])
                newPages.append(take)
                cursor += take.count
            }
            // Pages the run emptied are dropped, not kept as blanks — they can
            // only sit at the tail, because the fill walks the scope in order.
            newPages.removeAll { $0.isEmpty }
            let inserted = newPages.count - scope.count
            // Splice: scope region replaced by newPages; pages after it shift
            // down by `inserted`.
            let before = Array(pages[0 ..< min(scope.first ?? 0, pages.count)])
            let afterStart = min((scope.last ?? pages.count - 1) + 1, pages.count)
            let after = Array(pages[afterStart ..< pages.count])
            pages = before + newPages + after
            return Result(pages: pages, folders: folders, appendedPages: max(inserted, 0))
        } else {
            // Per-page: each scope page keeps its item count, so nothing can
            // spill; recompose each page independently.
            for p in scope where p < pages.count {
                let pageItems = pages[p]
                let pageOrdered = recompose(items: pageItems,
                                            folders: folders,
                                            apps: apps,
                                            options: options)
                pages[p] = Array(pageOrdered.prefix(cap))
            }
            return Result(pages: pages, folders: folders, appendedPages: 0)
        }
    }

    /// Sort + place one flat list of slots into its final order.
    ///
    /// Apple placement is applied to the apps first (others vs Apple's), then
    /// folder placement decides where the folder tiles sit relative to the
    /// composed app list. "Mixed" interleaves by name; the two directional
    /// options concatenate the groups.
    static func recompose(items: [DeckSlot],
                          folders: [UUID: AppFolder],
                          apps: [AppInfo],
                          options: OrganizeOptions) -> [DeckSlot] {
        var appSlots: [DeckSlot] = []
        var folderSlots: [(slot: DeckSlot, name: String)] = []
        for slot in items {
            switch slot {
            case .app:
                appSlots.append(slot)
            case .folder(let id):
                folderSlots.append((slot, folders[id]?.name ?? ""))
            }
        }

        // Apps: Apple placement first.
        var others: [AppInfo] = []
        var apples: [AppInfo] = []
        for slot in appSlots {
            if case .app(let id) = slot, let app = apps.first(where: { $0.id == id }) {
                if isAppleApp(app) { apples.append(app) } else { others.append(app) }
            }
        }
        others.sort { compare($0, $1, options) }
        apples.sort { compare($0, $1, options) }

        var orderedApps: [AppInfo] = []
        switch options.appleAppPlacement {
        case .mixedWithOtherApps:
            // One pool, one sort — the natural interleave.
            var pool = others + apples
            pool.sort { compare($0, $1, options) }
            orderedApps = pool
        case .afterOtherApps:
            orderedApps = others + apples
        case .beforeOtherApps:
            orderedApps = apples + others
        }

        var ordered: [DeckSlot] = orderedApps.map { .app($0.id) }

        // Folders: placement relative to the app list.
        if !folderSlots.isEmpty {
            var sortedFolders = folderSlots
            switch options.folderPlacement {
            case .mixedWithApps:
                sortedFolders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                // Merge by name against the app list.
                var merged: [DeckSlot] = []
                var ai = 0
                var fi = 0
                while ai < orderedApps.count || fi < sortedFolders.count {
                    if fi >= sortedFolders.count {
                        merged.append(.app(orderedApps[ai].id)); ai += 1
                    } else if ai >= orderedApps.count {
                        merged.append(sortedFolders[fi].slot); fi += 1
                    } else {
                        let appName = orderedApps[ai].name
                        let folderName = sortedFolders[fi].name
                        if folderName.localizedStandardCompare(appName) == .orderedAscending {
                            merged.append(sortedFolders[fi].slot); fi += 1
                        } else {
                            merged.append(.app(orderedApps[ai].id)); ai += 1
                        }
                    }
                }
                ordered = merged
            case .afterApps:
                ordered += sortedFolders.map(\.slot)
            case .beforeApps:
                ordered = sortedFolders.map(\.slot) + ordered
            }
        }
        return ordered
    }

    /// The shared app comparator: key first, name as the deterministic
    /// tiebreak, direction applied to the key only.
    ///
    /// Kept identical to `DeckStore.sorted(_:)`'s three non-manual cases so
    /// "reorganize by name" and "sort by name" cannot drift apart.
    static func compare(_ a: AppInfo, _ b: AppInfo, _ options: OrganizeOptions) -> Bool {
        let asc = options.sortDirection == .ascending
        switch options.sortMethod {
        case .manual:
            // Custom is never offered by the sheet; fall back to name so the
            // comparator stays total.
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        case .name:
            let r = a.name.localizedStandardCompare(b.name)
            return asc ? r == .orderedAscending : r == .orderedDescending
        case .dateAdded:
            let da = a.addedDate ?? .distantPast
            let db = b.addedDate ?? .distantPast
            if da == db { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return asc ? da < db : da > db
        case .lastUsed:
            let da = a.lastUsedDate ?? .distantPast
            let db = b.lastUsedDate ?? .distantPast
            if da == db { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return asc ? da < db : da > db
        }
    }

    /// Apple's own apps: bundle-id prefix, or living under a system location.
    ///
    /// Deterministic and offline — the same test a human would apply by
    /// looking at the path.
    static func isAppleApp(_ app: AppInfo) -> Bool {
        if let bundleID = app.bundleID, bundleID.hasPrefix("com.apple.") { return true }
        return app.path.hasPrefix("/System/Applications/")
            || app.path.hasPrefix("/System/Applications/Utilities/")
    }
}
