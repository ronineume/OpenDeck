import Foundation
import SwiftUI

/// Serialized form of the user's layout, written to disk as JSON.
private struct LayoutFile: Codable {
    var pages: [[String]] = []
    var folders: [AppFolder] = []
    var hidden: [String] = []
    var sortKey: SortKey = .manual
    var sortOrder: SortOrder = .ascending
    var customOrder: [String] = []

    init(pages: [[String]], folders: [AppFolder], hidden: [String],
         sortKey: SortKey, sortOrder: SortOrder, customOrder: [String]) {
        self.pages = pages
        self.folders = folders
        self.hidden = hidden
        self.sortKey = sortKey
        self.sortOrder = sortOrder
        self.customOrder = customOrder
    }

    enum CodingKeys: String, CodingKey {
        case pages, folders, hidden, sortKey, sortOrder, customOrder
    }

    /// Tolerant decoding (A1 companion). The synthesized `Decodable` ignores the
    /// property defaults above, so a file missing *any* key failed the whole load
    /// and the user's layout was dropped. Each field is now optional-on-read: a
    /// **missing** key falls back to its default (recoverable), while a
    /// truncated / syntactically broken / empty file, or a present-but-malformed
    /// value, still throws — that is real corruption and must be preserved, not
    /// silently accepted.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pages = try container.decodeIfPresent([[String]].self, forKey: .pages) ?? []
        folders = try container.decodeIfPresent([AppFolder].self, forKey: .folders) ?? []
        hidden = try container.decodeIfPresent([String].self, forKey: .hidden) ?? []
        sortKey = try container.decodeIfPresent(SortKey.self, forKey: .sortKey) ?? .manual
        sortOrder = try container.decodeIfPresent(SortOrder.self, forKey: .sortOrder) ?? .ascending
        customOrder = try container.decodeIfPresent([String].self, forKey: .customOrder) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pages, forKey: .pages)
        try container.encode(folders, forKey: .folders)
        try container.encode(hidden, forKey: .hidden)
        try container.encode(sortKey, forKey: .sortKey)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(customOrder, forKey: .customOrder)
    }
}

/// File-system operations the data-safety paths go through, so the self-test can
/// force a failure the file system cannot produce deterministically.
///
/// The case that matters is "preserving the site failed **while the directory
/// is still writable**": a rebuild would then happily overwrite the user's only
/// copy. A read-only directory cannot model it — there the overwrite fails too,
/// so "the bytes did not change" passes even against a build with the bug. The
/// earlier probe leaned on a file-name collision to cause the failure, which
/// stopped working the moment the name was made unique. Injecting the failure
/// removes the dependence on permissions, on name collisions and on wall-clock
/// seconds all at once.
struct FileSeams {
    /// Copy `source` to `destination`. Throws on failure.
    var copyItem: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    /// Write `data` to `destination` atomically. Throws on failure.
    ///
    /// Deliberately **not** wired into `save()`'s main write: a probe that
    /// injects a failure here must isolate the recovery write, otherwise it
    /// cannot tell "the recovery could not complete" from "saving is broken".
    var writeData: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
}

/// Owns the application list and the user's grid layout.
///
/// ## Ownership invariants — the arbitration rules for every mutation
///
/// Let *membership* mean "listed in some `AppFolder.appIDs`" and *standalone*
/// mean "present as a `.app` slot in `pages`.
///
/// - **I1 — exclusive folder membership**: an app belongs to **at most one**
///   folder.
/// - **I2 — single placement**: an app is **either** a standalone grid slot
///   **or** a folder member, never both. Breaking this is what conjures a
///   duplicate icon and pollutes `customOrder`.
/// - **I3 — no duplicate members**: a folder's `appIDs` never repeats an app.
/// - **I4 — order independence**: `reconcile` converges to the same result no
///   matter the order of the slots in `pages`. The tie-breaker that makes this
///   hold is **"folder membership always wins over a standalone slot"**.
///
/// `makeFolder` / `addToFolder` enforce I1–I3 at the point of mutation;
/// `reconcile` is the authoritative normaliser that restores all four for data
/// already on disk. Any automatic repair leaves a trace (see `recordDataRepair`).
@MainActor
final class DeckStore: ObservableObject {
    @Published private(set) var apps: [AppInfo] = []
    /// Pages of grid items; the last page is never empty.
    @Published var pages: [[DeckSlot]] = [[]]
    @Published var folders: [UUID: AppFolder] = [:]
    @Published var hidden: Set<String> = []
    @Published var sortKey: SortKey = .manual
    @Published var sortOrder: SortOrder = .ascending
    /// Manual ordering used when `sortKey == .manual`.
    @Published var customOrder: [String] = []
    @Published var lastError: String?
    /// Set **only** by the layout-loading data-safety paths (A1 corruption,
    /// recovery, degraded read-only, and the empty-`pages` case). A
    /// user-facing, plain-language note surfaced in Settings.
    ///
    /// Deliberately separate from `lastError`: `recordDataRepair` also writes
    /// `lastError` for *benign* repairs (e.g. one duplicate slot removed), and
    /// mixing "your file is damaged, this session will not save" with those in
    /// one banner would flatten two very different severities.
    @Published private(set) var layoutHealthMessage: String?
    /// Grid geometry for the screen currently being displayed; set by the window controller.
    @Published var metrics = GridMetrics(columns: 7, rows: 5, iconSize: 104, cellWidth: 150, cellHeight: 166) {
        didSet {
            // A different screen means a different slot count: repack the pages.
            guard metrics.capacity != oldValue.capacity else { return }
            // Repack so nothing overflows a smaller grid. `reflow()` itself never
            // writes, but that alone was **not** enough to keep a repack off
            // disk: the next `reconcile()` saves, and merely opening the deck
            // triggers one (`.deckRescanRequested` → `applyScan`). A repack
            // followed by an open was therefore permanent. `reconcile()` now
            // writes only when the persisted state actually changed, so a repack
            // no user edit follows stays in memory and the next real mutation is
            // what persists it.
            //
            // NOTE: the repack is still **lossy** — it compacts every page to
            // exactly `capacity`, so in-page gaps the user deliberately left are
            // flattened and returning to the original display does *not* restore
            // their exact arrangement. Only the un-persisted part was fixed here.
            reflow(capacity: metrics.capacity)
        }
    }

    private var index: [String: AppInfo] = [:]
    private var isLoading = false
    private let storeURL: URL
    /// Overridable file operations (see `FileSeams`); production uses the real ones.
    private let seams: FileSeams

    /// When true, `save()` is a no-op. The dev tools load the real layout so
    /// snapshots are faithful, but must never rewrite it.
    private let readOnly: Bool
    /// Set at load time when the on-disk layout could not be decoded **and** no
    /// usable `.bak` existed (A1). Kept separate from `readOnly` on purpose:
    /// that one is a construction-time constant also used by `--bench` /
    /// `--snapshot`, so overloading it would silently change those tools. While
    /// this is true `save()` is a no-op, so a damaged file is never overwritten
    /// with a reconstructed layout.
    private var degradedReadOnly = false
    /// True when the store is running in the degraded, non-persisting mode above.
    var isDegraded: Bool { degradedReadOnly }
    /// When true, the next `save()` skips `rotateBackup()`.
    ///
    /// Set by a load path that has already established the file on disk is **not**
    /// a good "previous state": rotating it would copy known-bad bytes over the
    /// user's only healthy `.bak`. That is exactly how the empty-`pages` rebuild
    /// destroyed the backup that could still have recovered the layout — the
    /// damaged file survived as a `.corrupt-*` sibling, but the *usable* copy
    /// was gone. Consumed on the next `save()`.
    private var suppressNextBackupRotation = false
    /// The id set reported by the last scan rejected as implausible (see
    /// `shouldAdoptScan`). Kept so a second, identical observation can be told
    /// apart from a one-off read failure — and so the rejection is idempotent:
    /// believing the second sighting does **not** consume this, otherwise a
    /// third call with the same ids would reject again.
    private var rejectedScanIDs: Set<String>?
    /// The id set of the last **believed** scan. It is what turns a single missing
    /// observation into "not confirmed gone" instead of "uninstalled".
    private var previouslyScannedIDs: Set<String>?
    /// Ids that were in the previous believed picture but are missing from the
    /// scan that was just accepted. Set by `shouldAdoptScan`, consumed by
    /// `reconcile` — see `membershipValid` there.
    private var unconfirmedAbsent: Set<String> = []
    /// A scan may report fewer apps than the layout uses: an uninstall is an
    /// ordinary event. Beyond this share of the layout's apps missing, the scan
    /// is treated as suspect instead of as an uninstall.
    private static let scanSanityDropTolerance = 0.20
    /// Below this many referenced apps the ratio is noise — losing one app out of
    /// four is a 25% fall and perfectly ordinary — so the check does not apply.
    private static let scanSanityFloor = 5

    /// While a batch is open, `save()` only records that a write is owed.
    private var batchDepth = 0
    private var pendingSave = false
    /// True from a drag gesture's first `onChanged` until its commit. While it
    /// holds, `normalizePages()` defers empty-page reclamation (Q1) so the dot
    /// row does not shrink mid-drag; `endDragSession()` reclaims exactly once.
    ///
    /// A **Bool**, not the `batchDepth` counter: two gesture handlers can both
    /// "open" for a single drag, and a raw counter would then reach 2 while a
    /// single end only decrements to 1 — never flushing and never reclaiming
    /// (§8.2/§8.4(d)).
    private var dragSessionActive = false

    /// - Parameters:
    ///   - storeURL: override for tests; defaults to Application Support.
    ///   - readOnly: skip all writes.
    ///   - seams: overridable file operations; the self-test injects failures here.
    init(storeURL: URL? = nil, readOnly: Bool = false, seams: FileSeams = FileSeams()) {
        self.readOnly = readOnly
        self.seams = seams
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.storeURL = storeURL ?? base.appendingPathComponent("layout.json")
        // Load first. Scanning must not reconcile (and therefore must not save)
        // before the on-disk layout has been read, or it would be overwritten
        // with a fresh default on every launch.
        isLoading = true
        reloadApps()
        loadLayout()
    }

    // MARK: - Lookup

    func app(id: String) -> AppInfo? { index[id] }

    var visibleApps: [AppInfo] {
        apps.filter { !hidden.contains($0.id) }
    }

    /// Apps the user has hidden, in display order.
    var hiddenApps: [AppInfo] {
        apps
            .filter { hidden.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func folder(_ id: UUID) -> AppFolder? { folders[id] }

    /// All apps belonging to a folder, resolved and de-duplicated.
    func folderApps(_ id: UUID) -> [AppInfo] {
        guard let folder = folders[id] else { return [] }
        return folder.appIDs.compactMap { index[$0] }
    }

    /// Display name and icon for any grid item.
    func label(for item: DeckSlot) -> String {
        switch item {
        case .app(let id): return index[id]?.name ?? "Missing"
        case .folder(let id): return folders[id]?.name ?? "Folder"
        }
    }

    // MARK: - Scanning

    func reloadApps() {
        applyScan(AppScanner.scan())
    }

    /// Adopt a freshly scanned list. New apps are appended to the grid and
    /// vanished ones are dropped, so an install or uninstall shows up without a
    /// relaunch. The scan itself can run off the main thread.
    ///
    /// A scan that is not believable (see `shouldAdoptScan`) is discarded
    /// *before* it replaces anything. Letting it through "only in memory" is not
    /// harmless: the grid would render every missing app as a hole, and
    /// `reconcile()` would then make the loss permanent.
    func applyScan(_ scanned: [AppInfo]) {
        if !isLoading, !shouldAdoptScan(Set(scanned.map { $0.id })) { return }
        apps = scanned
        index = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, $0) })
        if !isLoading { reconcile() }
    }

    // MARK: - Ordering

    /// Apps in the order implied by the current sort settings.
    func sorted(_ list: [AppInfo]) -> [AppInfo] {
        let asc = sortOrder == .ascending
        switch sortKey {
        case .manual:
            // customOrder can legitimately contain duplicates (an app that is
            // both a grid slot and a folder member). The old
            // `Dictionary(uniqueKeysWithValues:)` trapped on a repeated key;
            // keep the earliest position instead.
            let position = Dictionary(customOrder.enumerated().map { ($1, $0) },
                                      uniquingKeysWith: { first, _ in first })
            return list.sorted { a, b in
                let pa = position[a.id] ?? Int.max
                let pb = position[b.id] ?? Int.max
                if pa != pb { return pa < pb }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        case .name:
            return list.sorted {
                let r = $0.name.localizedStandardCompare($1.name)
                return asc ? r == .orderedAscending : r == .orderedDescending
            }
        case .dateAdded:
            return list.sorted { a, b in
                let da = a.addedDate ?? .distantPast
                let db = b.addedDate ?? .distantPast
                if da == db { return a.name < b.name }
                return asc ? da < db : da > db
            }
        case .lastUsed:
            return list.sorted { a, b in
                let da = a.lastUsedDate ?? .distantPast
                let db = b.lastUsedDate ?? .distantPast
                if da == db { return a.name < b.name }
                return asc ? da < db : da > db
            }
        }
    }

    /// Re-sort every page in place. Folders keep their slot on the page.
    func applySort() {
        guard sortKey != .manual else { return }
        // Collect app items across all pages, sort them, then deal them back out
        // into the slots that previously held plain apps.
        var plainApps: [AppInfo] = []
        for page in pages {
            for item in page {
                if case .app(let id) = item, let app = index[id], !hidden.contains(id) {
                    plainApps.append(app)
                }
            }
        }
        let ordered = sorted(plainApps)
        var cursor = 0
        for p in pages.indices {
            for i in pages[p].indices {
                if case .app = pages[p][i] {
                    if cursor < ordered.count {
                        pages[p][i] = .app(ordered[cursor].id)
                        cursor += 1
                    } else {
                        // Fewer apps than slots: drop the trailing empties later.
                        pages[p][i] = .app("")
                    }
                }
            }
        }
        pages = pages.map { $0.filter { $0 != .app("") } }
        normalizePages()
        save()
    }

    // MARK: - Mutation

    func setHidden(_ id: String, _ isHidden: Bool) {
        if isHidden {
            hidden.insert(id)
            removeFromGrid(id)
        } else {
            hidden.remove(id)
            appendToGrid(.app(id))
        }
        save()
    }

    func rename(_ folderID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var folder = folders[folderID] else { return }
        folder.name = trimmed
        folders[folderID] = folder
        save()
    }

    /// Create a folder from the app at `source`, dropped onto `target`.
    ///
    /// Enforces **I1/I3**: `source` is detached from any folder it currently
    /// belongs to (dissolving a one-app leftover) and is never appended twice.
    func makeFolder(dropping source: String, onto target: String) {
        guard source != target else { return }
        let targetFolderID = folders.values.first { $0.appIDs.contains(target) }?.id
        // Already together: nothing to do (also protects the folder's name/identity).
        if let fid = targetFolderID, folders[fid]?.appIDs.contains(source) == true { return }

        // I1: an app may belong to only one folder, so leave the old one first.
        detachFromAnyFolder(source)

        // If the target already lives in a folder, merge into it (I3: never twice).
        if let fid = targetFolderID, var updated = folders[fid] {
            if !updated.appIDs.contains(source) { updated.appIDs.append(source) }
            folders[fid] = updated
            removeGridSlot(source)
            save()
            return
        }
        let folder = AppFolder(name: "Folder", appIDs: [target, source])
        folders[folder.id] = folder
        replaceInGrid(.app(target), with: .folder(folder.id))
        removeGridSlot(source)
        save()
    }

    /// Add an existing app to an existing folder.
    ///
    /// `makeFolder(dropping:onto:)` only knew how to combine two loose apps, so
    /// dragging onto a folder tile had nowhere to go. Enforces **I1/I3**: the
    /// app is detached from any *other* folder first and is never added twice.
    @discardableResult
    func addToFolder(_ appID: String, folder folderID: UUID) -> Bool {
        guard folders[folderID]?.appIDs.contains(appID) == false else { return false }
        // I1: leave whatever other folder holds it (dissolving a one-app leftover).
        detachFromAnyFolder(appID, except: folderID)
        guard var folder = folders[folderID] else { return false }
        folder.appIDs.append(appID)
        folders[folderID] = folder
        removeGridSlot(appID)
        normalizePages()
        save()
        return true
    }

    /// Remove one app from a folder; an empty folder disappears.
    func removeFromFolder(_ appID: String, folder folderID: UUID) {
        guard var folder = folders[folderID] else { return }
        folder.appIDs.removeAll { $0 == appID }
        // I2: leaving a folder must leave the app with **exactly one** standalone
        // grid slot. If the input already breached I2 (the app was *both* a grid
        // slot and a folder member — e.g. an old `app-first` layout), the
        // `appendToGrid` below would conjure a SECOND icon (observed: 1 → 2).
        // Drop any stray slot first. `removeGridSlot` touches only `pages`,
        // never `folders`, so it is safe at this point.
        removeGridSlot(appID)
        if folder.appIDs.count <= 1 {
            let leftovers = folder.appIDs
            folders.removeValue(forKey: folderID)
            replaceInGrid(.folder(folderID), with: leftovers.first.map { DeckSlot.app($0) } ?? .app(""))
            pages = pages.map { $0.filter { $0 != .app("") } }
            appendToGrid(.app(appID))
        } else {
            folders[folderID] = folder
            appendToGrid(.app(appID))
        }
        normalizePages()
        save()
    }

    /// Dissolve a folder, returning its apps to the grid.
    func ungroup(_ folderID: UUID) {
        guard let folder = folders[folderID] else { return }
        folders.removeValue(forKey: folderID)
        let members = folder.appIDs
        replaceInGrid(.folder(folderID), with: members.first.map { DeckSlot.app($0) } ?? .app(""))
        for extra in members.dropFirst() { appendToGrid(.app(extra)) }
        pages = pages.map { $0.filter { $0 != .app("") } }
        normalizePages()
        save()
    }

    /// Move the item at a page/index to another position.
    func move(itemAt source: IndexPath, to destination: IndexPath) {
        guard source.section < pages.count, source.item < pages[source.section].count else { return }
        let moved = pages[source.section].remove(at: source.item)

        let targetPage = min(destination.section, pages.count - 1)
        var page = pages[targetPage]
        let insertAt = min(max(destination.item, 0), page.count)
        page.insert(moved, at: insertAt)
        pages[targetPage] = page

        normalizePages()
        syncCustomOrder()
        save()
    }

    /// Pull an app out of a folder and place it at a specific grid position.
    /// Used when dragging an app out of an expanded folder onto the grid.
    @discardableResult
    func moveOutOfFolder(_ appID: String, folder folderID: UUID, toPage page: Int, index: Int) -> Bool {
        guard let folder = folders[folderID], folder.appIDs.contains(appID) else { return false }
        removeFromFolder(appID, folder: folderID)

        guard let slot = locate(.app(appID)) else { return false }
        let target = min(max(page, 0), max(pages.count - 1, 0))
        let limit = pages.indices.contains(target) ? pages[target].count : 0
        move(itemAt: slot, to: IndexPath(item: min(max(index, 0), limit), section: target))
        save()
        return true
    }

    /// Move a grid item to the end of another page. Used when a drag is
    /// dropped onto a page dot.
    func moveItem(_ item: DeckSlot, toPage page: Int) {
        guard let from = locate(item) else { return }
        let target = min(max(page, 0), max(pages.count - 1, 0))
        let count = pages.indices.contains(target) ? pages[target].count : 0
        // Dropping an item onto its own page is a no-op rather than a shuffle.
        guard target != from.section else { return }
        move(itemAt: from, to: IndexPath(item: count, section: target))
    }

    /// Remove every gap, packing apps forward across pages.
    func fillEmptySlots(capacity: Int) {
        let flat = pages.flatMap { $0 }
        guard capacity > 0 else { return }
        var rebuilt: [[DeckSlot]] = []
        var current: [DeckSlot] = []
        for item in flat {
            if current.count == capacity {
                rebuilt.append(current)
                current = []
            }
            current.append(item)
        }
        if !current.isEmpty { rebuilt.append(current) }
        pages = rebuilt.isEmpty ? [[]] : rebuilt
        syncCustomOrder()
        save()
    }

    func restartToDefaultOrder(capacity: Int) {
        customOrder = sorted(visibleApps).map { $0.id }
        let items = customOrder.map { DeckSlot.app($0) }
        pages = stride(from: 0, to: max(items.count, 1), by: max(capacity, 1)).map {
            Array(items[$0 ..< min($0 + capacity, items.count)])
        }
        if pages.isEmpty { pages = [[]] }
        save()
    }

    // MARK: - Grid helpers

    /// Guarantee the invariant the view depends on: no page may hold more slots
    /// than the grid can show, or the view's index arithmetic traps.
    ///
    /// Only over-full pages are split. Pages that are *under* capacity are left
    /// exactly as they are, so gaps the user created survive a relaunch.
    func enforceCapacity() {
        let cap = max(metrics.capacity, 1)
        var rebuilt: [[DeckSlot]] = []
        for page in pages {
            if page.count <= cap {
                rebuilt.append(page)
                continue
            }
            var remaining = ArraySlice(page)
            while !remaining.isEmpty {
                rebuilt.append(Array(remaining.prefix(cap)))
                remaining = remaining.dropFirst(cap)
            }
        }
        pages = rebuilt.isEmpty ? [[]] : rebuilt
        normalizePages()
    }

    /// Compact every page to exactly `capacity`, closing all gaps.
    /// Used when the grid shape itself changes, where a repack is what the
    /// user expects; deliberately not used when merely loading a saved layout.
    func reflow(capacity: Int) {
        let cap = max(capacity, 1)
        var rebuilt: [[DeckSlot]] = [[]]
        for page in pages {
            for item in page {
                if rebuilt[rebuilt.count - 1].count >= cap { rebuilt.append([]) }
                rebuilt[rebuilt.count - 1].append(item)
            }
        }
        pages = rebuilt
        normalizePages()
    }

    /// Find where a grid item currently sits, if anywhere.
    func locate(_ item: DeckSlot) -> IndexPath? {
        for (page, items) in pages.enumerated() {
            if let index = items.firstIndex(of: item) {
                return IndexPath(item: index, section: page)
            }
        }
        return nil
    }

    private func appendToGrid(_ item: DeckSlot) {
        let capacity = max(metrics.capacity, 1)
        // Appending past capacity wrote an over-full page to disk, which the
        // next launch split into an extra page out of nowhere.
        if pages.isEmpty {
            pages = [[item]]
            return
        }
        if pages[pages.count - 1].count >= capacity { pages.append([]) }
        pages[pages.count - 1].append(item)
    }

    /// Remove only the app's standalone grid slot, leaving folder membership
    /// untouched. Used when an app moves into a folder.
    private func removeGridSlot(_ appID: String) {
        let item = DeckSlot.app(appID)
        for p in pages.indices { pages[p].removeAll { $0 == item } }
        normalizePages()
    }

    /// Remove the app from the grid *and* from any folder holding it.
    private func removeFromGrid(_ appID: String) {
        let item = DeckSlot.app(appID)
        for p in pages.indices { pages[p].removeAll { $0 == item } }
        // Also pull it out of any folder.
        for (fid, var folder) in folders where folder.appIDs.contains(appID) {
            folder.appIDs.removeAll { $0 == appID }
            if folder.appIDs.isEmpty { folders.removeValue(forKey: fid) } else { folders[fid] = folder }
        }
        for p in pages.indices {
            pages[p] = pages[p].map { item in
                if case .folder(let fid) = item, folders[fid] == nil { return .app("") }
                return item
            }
            pages[p].removeAll { $0 == .app("") }
        }
        normalizePages()
    }

    private func replaceInGrid(_ old: DeckSlot, with new: DeckSlot) {
        for p in pages.indices {
            if let i = pages[p].firstIndex(of: old) {
                if new == .app("") { pages[p].remove(at: i) } else { pages[p][i] = new }
                return
            }
        }
    }

    /// Detach `appID` from every folder that holds it, except `keep`.
    ///
    /// Enforces **I1** at the point of mutation. A folder left with fewer than
    /// two members is not a folder: it is dissolved and its survivor returned to
    /// the grid, matching `reconcile`'s "a folder needs two members" rule.
    private func detachFromAnyFolder(_ appID: String, except keep: UUID? = nil) {
        let holders = folders
            .filter { $0.key != keep && $0.value.appIDs.contains(appID) }
            .map(\.key)
        for fid in holders {
            guard var folder = folders[fid] else { continue }
            folder.appIDs.removeAll { $0 == appID }
            if folder.appIDs.count <= 1 {
                folders.removeValue(forKey: fid)
                // A user's named folder silently vanishing is exactly the kind of
                // automatic action the class contract (`Any automatic repair
                // leaves a trace`) promises to surface — do not swallow it.
                recordDataRepair("a folder fell below two members and was dissolved; its survivor was returned to the grid")
                let survivor = folder.appIDs.first.map { DeckSlot.app($0) } ?? .app("")
                replaceInGrid(.folder(fid), with: survivor)
                pages = pages.map { $0.filter { $0 != .app("") } }
            } else {
                folders[fid] = folder
            }
        }
    }

    /// Record that damaged data had to be repaired.
    ///
    /// Deliberately observable (stderr + `lastError`) rather than silent: a user
    /// whose layout gets rewritten should be able to learn that it happened,
    /// instead of the corruption being swallowed.
    private func recordDataRepair(_ message: String) {
        lastError = "Repaired layout: \(message)"
        FileHandle.standardError.write(Data("LaunchDeck: repaired layout: \(message)\n".utf8))
    }

    /// THE unconditional "drop every empty page" primitive: an interior empty
    /// page used to survive startup and be re-saved forever, rendering as a
    /// blank page whose taps dismissed the deck.
    ///
    /// Returns true when it removed at least one page. In-page gaps are
    /// deliberately preserved — only whole-page emptiness is reclaimed.
    @discardableResult
    private func reclaimEmptyPages() -> Bool {
        let before = pages.count
        pages.removeAll { $0.isEmpty }
        if pages.isEmpty { pages = [[]] }
        return pages.count != before
    }

    /// Normalise the page array. While a drag session is open the empty-page
    /// reclamation is **deferred** (Q1): the grid can transiently hold a page
    /// the user is dragging the last item out of, and reclaiming it mid-drag
    /// shrank `pages.count` under the live read index and made the dot row
    /// jump. `endDragSession()` reclaims exactly once at the end, and `save()`
    /// never writes an empty page (guard for a session that never closed).
    private func normalizePages() {
        if !dragSessionActive { reclaimEmptyPages() }
        if pages.isEmpty { pages = [[]] }
    }

    private func syncCustomOrder() {
        guard sortKey == .manual else { return }
        // An app that is both a grid slot and a folder member would otherwise be
        // appended twice, and the duplicate is written straight to disk (which
        // used to crash the next launch). De-duplicate, first occurrence wins.
        var seen = Set<String>()
        var order: [String] = []
        for page in pages {
            for item in page {
                switch item {
                case .app(let id):
                    if seen.insert(id).inserted { order.append(id) }
                case .folder(let id):
                    for member in folders[id]?.appIDs ?? [] where seen.insert(member).inserted {
                        order.append(member)
                    }
                }
            }
        }
        customOrder = order
    }

    // MARK: - Import

    /// Outcome of importing an external layout.
    struct ImportReport {
        var placedApps = 0
        var folders = 0
        var pages = 0
        /// Apps named by the source that are not installed here.
        var skipped: [String] = []
        /// Apps that are installed but hidden in LaunchDeck, so not shown.
        var hiddenSkipped: [String] = []
    }

    /// Replace the layout with one read from macOS's Launchpad database.
    ///
    /// Apps the source mentions but that are not installed are reported rather
    /// than silently dropped, and anything installed but absent from the import
    /// is appended so nothing disappears.
    @discardableResult
    func applyImported(_ layout: ImportedLayout) -> ImportReport {
        var byBundleID: [String: AppInfo] = [:]
        var byName: [String: AppInfo] = [:]
        for app in apps {
            if let bundleID = app.bundleID { byBundleID[bundleID.lowercased()] = app }
            byName[app.name.lowercased()] = app
        }

        var report = ImportReport()
        var newPages: [[DeckSlot]] = []
        var newFolders: [UUID: AppFolder] = [:]
        var placed = Set<String>()

        func resolve(_ bundleID: String, title: String) -> AppInfo? {
            if let hit = byBundleID[bundleID.lowercased()] { return hit }
            if !title.isEmpty, let hit = byName[title.lowercased()] { return hit }
            return nil
        }

        for page in layout.pages {
            var slots: [DeckSlot] = []
            for slot in page {
                switch slot {
                case .app(let bundleID, let title):
                    guard let app = resolve(bundleID, title: title) else {
                        report.skipped.append(title.isEmpty ? bundleID : title)
                        continue
                    }
                    if hidden.contains(app.id) {
                        report.hiddenSkipped.append(app.name)
                        continue
                    }
                    guard !placed.contains(app.id) else { continue }
                    placed.insert(app.id)
                    slots.append(.app(app.id))
                    report.placedApps += 1

                case .folder(let name, let members):
                    var ids: [String] = []
                    for member in members {
                        guard let app = resolve(member, title: member) else {
                            // Report it: silently dropping folder members made
                            // imports look complete when they were not.
                            report.skipped.append(member)
                            continue
                        }
                        if hidden.contains(app.id) {
                            report.hiddenSkipped.append(app.name)
                            continue
                        }
                        guard !placed.contains(app.id) else { continue }
                        placed.insert(app.id)
                        ids.append(app.id)
                    }
                    if ids.count >= 2 {
                        let folder = AppFolder(name: name, appIDs: ids)
                        newFolders[folder.id] = folder
                        slots.append(.folder(folder.id))
                        report.folders += 1
                        report.placedApps += ids.count
                    } else if let only = ids.first {
                        // A one-item folder is just an app.
                        slots.append(.app(only))
                        report.placedApps += 1
                    }
                }
            }
            if !slots.isEmpty { newPages.append(slots) }
        }

        guard !newPages.isEmpty else { return report }

        folders = newFolders
        pages = newPages
        // Imported pages follow Launchpad's 7x5 grid; split anything that does
        // not fit this screen.
        enforceCapacity()

        // Keep apps that the imported layout did not mention.
        let leftovers = sorted(visibleApps.filter { !placed.contains($0.id) })
        for app in leftovers { appendToGrid(.app(app.id)) }
        enforceCapacity()

        customOrder = pages.flatMap { page in
            page.flatMap { slot -> [String] in
                switch slot {
                case .app(let id): return [id]
                case .folder(let id): return folders[id]?.appIDs ?? []
                }
            }
        }
        sortKey = .manual
        report.pages = pages.count
        save()
        return report
    }

    // MARK: - Reconciliation

    /// Exactly the state `save()` writes. `reconcile()` compares it before and
    /// after, so it only writes when something really changed.
    ///
    /// An unconditional save there was **not** harmless: a screen change repacks
    /// the pages in memory (`reflow()`, deliberately not persisted), and then
    /// merely opening the deck fires `.deckRescanRequested` → `applyScan` →
    /// `reconcile()`, which wrote that repack to disk with no user action at all
    /// — and switching back to the original display did not undo it.
    ///
    /// The fields and the `sorted()` calls must mirror `save()` exactly: a
    /// mismatch would either report a change that never happened (and write) or
    /// miss one that did (and lose it).
    private struct PersistedState: Equatable {
        var pages: [[DeckSlot]]
        var folders: [AppFolder]
        var hidden: [String]
        var sortKey: SortKey
        var sortOrder: SortOrder
        var customOrder: [String]
    }

    /// The state as `save()` would serialise it right now.
    private var persistedState: PersistedState {
        PersistedState(
            pages: pages,
            folders: folders.values.sorted { $0.id.uuidString < $1.id.uuidString },
            hidden: hidden.sorted(),
            sortKey: sortKey,
            sortOrder: sortOrder,
            customOrder: customOrder
        )
    }

    /// Every app id the in-memory layout depends on: grid slots, folder members,
    /// `hidden` entries and the manual order.
    ///
    /// This is the yardstick a scan is measured against, because the layout is
    /// what a bad scan destroys — and it is available on the launch path too,
    /// where it comes from the file rather than from a scan.
    private func referencedAppIDs() -> Set<String> {
        var ids = Set<String>()
        for page in pages {
            for item in page {
                switch item {
                case .app(let id):
                    // `applySort` briefly parks `.app("")` in trailing slots; an
                    // empty id is not a reference to anything.
                    if !id.isEmpty { ids.insert(id) }
                case .folder(let id):
                    ids.formUnion(folders[id]?.appIDs ?? [])
                }
            }
        }
        ids.formUnion(customOrder)
        ids.formUnion(hidden)
        return ids
    }

    /// Whether the scanned app list is a believable picture of this machine.
    ///
    /// `stillThere` is how many of the layout's apps the scan accounts for, so the
    /// verdict is about the *layout* rather than about the raw count: a scan that
    /// reports plenty of apps, none of which the layout uses, is just as bad.
    ///
    /// Requiring two identical observations costs exactly one extra scan before a
    /// real mass uninstall is reflected. It deliberately says nothing about a
    /// *single* app vanishing: any threshold has to tolerate an ordinary
    /// uninstall, so a one-app gap is always believed.
    private func scanLooksPlausible(scannedIDs: Set<String>, stillThere: Int, referenced: Set<String>) -> Bool {
        guard referenced.count >= Self.scanSanityFloor else { return true }
        // "Nothing is installed" is never a plausible reading of this machine,
        // and it is the shape that dissolves every folder at once.
        guard !scannedIDs.isEmpty else { return false }
        return Double(stillThere) >= Double(referenced.count) * (1 - Self.scanSanityDropTolerance)
    }

    /// Judge a freshly scanned id set: true when it may be adopted.
    ///
    /// A scan can fail *partially* and still return a plausible-looking list.
    /// `AppScanner` yields nothing for a search root it cannot read and silently
    /// skips a bundle it cannot open — so a rescan that fires while apps are being
    /// replaced, which is precisely what triggers a rescan, can report much of
    /// the machine as gone. Believing that list is destructive *and permanent*:
    /// `reconcile` dissolves folders and deletes grid slots, `hidden` marks and
    /// `customOrder` entries, and the save that follows rotates the result over
    /// `.bak`. A layout built from a partial scan decodes perfectly, so `.bak` is
    /// never consulted and the loss survives every relaunch, with nothing shown
    /// to the user.
    ///
    /// So an implausible scan is not believed on first sight: the same id set has
    /// to be seen twice. The cost is that a genuine mass uninstall lands one scan
    /// later.
    ///
    /// **Idempotent** for a repeat call with the same ids — believing the second
    /// sighting does *not* consume it — so `applyScan` and `reconcile` can both
    /// ask without the second question undoing the first answer.
    private func shouldAdoptScan(_ scannedIDs: Set<String>) -> Bool {
        let referenced = referencedAppIDs()
        let stillThere = scannedIDs.intersection(referenced).count
        if scanLooksPlausible(scannedIDs: scannedIDs, stillThere: stillThere, referenced: referenced) {
            rejectedScanIDs = nil
            return true
        }
        if rejectedScanIDs == scannedIDs { return true }
        rejectedScanIDs = scannedIDs
        recordScanRejection(accountedFor: stillThere, referenced: referenced.count)
        return false
    }

    /// Advance the "previous picture" to the scan a `reconcile` pass just accepted,
    /// and record which of its apps went missing.
    ///
    /// Deliberately **not** part of `shouldAdoptScan`: `applyScan` and `reconcile`
    /// both ask that question about the same scan, and advancing the baseline on
    /// the first ask would make the second one see nothing missing — the
    /// one-observation rule would silently disable itself. Only the pass that
    /// actually acts on the scan commits it.
    ///
    /// On the first accepted pass of a process there is no earlier scan, so the
    /// layout's own records are the baseline. That is what extends the rule to the
    /// launch path.
    private func commitScanBaseline(_ scannedIDs: Set<String>) {
        let previous = previouslyScannedIDs ?? referencedAppIDs()
        unconfirmedAbsent = previous.subtracting(scannedIDs)
        previouslyScannedIDs = scannedIDs
    }

    /// Record that a scan was discarded as implausible.
    ///
    /// Goes to `lastError` (surfaced in Settings) and stderr — deliberately
    /// **not** to `layoutHealthMessage`: that banner is reserved for "your file
    /// is damaged and this session will not save", and overwriting it with this
    /// lesser notice would flatten two very different severities, which is the
    /// exact mistake those two channels exist to prevent.
    private func recordScanRejection(accountedFor: Int, referenced: Int) {
        lastError = "Ignored a rescan: only \(accountedFor) of the \(referenced) apps this layout uses are accounted for, which looks like a failed scan rather than an uninstall. Your layout was left as it was; a second matching scan will apply the change."
        FileHandle.standardError.write(Data("LaunchDeck: discarded an implausible scan (\(accountedFor)/\(referenced) of the layout's apps accounted for); layout left untouched\n".utf8))
    }

    /// Merge the on-disk layout with what is actually installed right now.
    ///
    /// Restores the ownership invariants (see the type doc). The grid pass is
    /// deliberately **two-phase — folder members are collected first and win** —
    /// so the outcome does not depend on slot order (I4) and a folder member is
    /// never also left as a standalone slot (I2). "Folder membership wins" is
    /// the arbitration rule for I2.
    private func reconcile() {
        // The launch path reaches `reconcile` directly — `applyScan` runs while
        // `isLoading` and so is not screened by its own check — and that is the
        // one where the on-disk layout is what a bad scan would destroy. Same
        // judgement, same single place it can act: the `save()` at the end.
        let scannedIDs = Set(apps.map { $0.id })
        if !shouldAdoptScan(scannedIDs) { return }
        commitScanBaseline(scannedIDs)

        let stateBefore = persistedState
        let valid = scannedIDs
        // An app the scan did not see is not necessarily uninstalled: a bundle
        // being replaced disappears from a scan and comes back, and it is exactly
        // that replacement that fires the rescan. Records a single observation
        // would destroy **permanently** are therefore kept for one more scan —
        // folder membership, the `hidden` mark and the manual order. Grid slots
        // are still dropped, because a slot for an app that cannot be drawn
        // renders as a hole, and the count screen in `shouldAdoptScan` already
        // protects the arrangement itself.
        let membershipValid = valid.union(unconfirmedAbsent)

        // Drop `hidden` entries for apps that are no longer installed, so that
        // reinstalling a previously hidden app lets it show up again (a user-facing
        // decision, not an accident). Only ids with **no installed app** are
        // removed — an app the user deliberately hid and still has installed keeps
        // its entry untouched.
        let staleHidden = hidden.subtracting(membershipValid)
        if !staleHidden.isEmpty {
            hidden.subtract(staleHidden)
            recordDataRepair("\(staleHidden.count) hidden app(s) are no longer installed and were removed from the hidden list")
        }

        // Folders: drop members that vanished / are hidden (normal pruning),
        // drop duplicates *within* a folder (I3), then drop folders that no
        // longer hold two apps.
        var duplicateMemberRepairs = 0
        var dissolvedFolderRepairs = 0
        for (fid, folder) in folders {
            var updated = folder
            var seenMembers = Set<String>()
            var kept: [String] = []
            for id in updated.appIDs {
                guard membershipValid.contains(id), !hidden.contains(id) else { continue }
                if seenMembers.insert(id).inserted {
                    kept.append(id)
                } else {
                    duplicateMemberRepairs += 1
                }
            }
            updated.appIDs = kept
            if updated.appIDs.count <= 1 {
                folders.removeValue(forKey: fid)
                dissolvedFolderRepairs += 1
            } else {
                folders[fid] = updated
            }
        }
        if duplicateMemberRepairs > 0 {
            recordDataRepair("\(duplicateMemberRepairs) duplicate folder member(s) removed")
        }
        if dissolvedFolderRepairs > 0 {
            recordDataRepair("\(dissolvedFolderRepairs) folder(s) fell below two members and were dissolved")
        }

        // I1: an app may belong to only one folder.
        normalizeFolderExclusivity()

        // Grid (I2/I4). Pass 1: every folder member is authoritative and claims
        // its app first, whatever the slot order.
        var folderMembers = Set<String>()
        for page in pages {
            for item in page {
                if case .folder(let fid) = item, let f = folders[fid] {
                    f.appIDs.forEach { folderMembers.insert($0) }
                }
            }
        }
        var placed = folderMembers
        // Pass 2: a standalone slot survives only if it is live and unclaimed.
        var dualPlacementRepairs = 0
        var duplicateSlotRepairs = 0
        var danglingFolderSlotRepairs = 0
        for p in pages.indices {
            pages[p] = pages[p].filter { item in
                switch item {
                case .app(let id):
                    guard valid.contains(id), !hidden.contains(id) else { return false }
                    if placed.contains(id) {
                        if folderMembers.contains(id) { dualPlacementRepairs += 1 }
                        else { duplicateSlotRepairs += 1 }
                        return false
                    }
                    placed.insert(id)
                    return true
                case .folder(let fid):
                    if folders[fid] != nil { return true }
                    // A `.folder` slot whose folder no longer exists rendered as
                    // an invisible hole and was dropped silently — leave a trace.
                    danglingFolderSlotRepairs += 1
                    return false
                }
            }
        }
        if dualPlacementRepairs > 0 {
            recordDataRepair("\(dualPlacementRepairs) grid slot(s) also held by a folder — folder membership kept")
        }
        if duplicateSlotRepairs > 0 {
            recordDataRepair("\(duplicateSlotRepairs) duplicate grid slot(s) removed")
        }
        if danglingFolderSlotRepairs > 0 {
            recordDataRepair("\(danglingFolderSlotRepairs) folder slot(s) referenced a missing folder and were removed")
        }
        normalizePages()

        // Append anything newly installed and not yet placed.
        let missing = sorted(visibleApps.filter { !placed.contains($0.id) })
        for app in missing { appendToGrid(.app(app.id)) }

        // De-duplicate as well as drop invalid ids: a duplicate here would be
        // written back to disk and (before the sorted() fix) crashed the next load.
        var seenCustom = Set<String>()
        customOrder = customOrder.filter { membershipValid.contains($0) && seenCustom.insert($0).inserted }
        for app in missing where !customOrder.contains(app.id) { customOrder.append(app.id) }

        enforceCapacity()
        normalizePages()
        // Only write when this pass actually changed something — see
        // `PersistedState`. The unconditional save is what let a display-driven
        // repack reach disk with no user action behind it.
        if persistedState != stateBefore { save() }
    }

    /// Enforce **I1**: an app lives in at most one folder.
    ///
    /// The authoritative folder is the one whose `.folder` slot appears *first*
    /// in `pages` (a deterministic choice — never the `Dictionary`'s random
    /// enumeration order); folders not referenced by any page fall back to
    /// UUID order. The app is then removed from every other folder, and any
    /// folder left with fewer than two members is dissolved with its survivor
    /// returned to the grid.
    private func normalizeFolderExclusivity() {
        // 1) Authoritative folder per app: pages order first, then UUID order.
        var firstHolder: [String: UUID] = [:]
        for page in pages {
            for item in page {
                guard case .folder(let fid) = item, let f = folders[fid] else { continue }
                for member in f.appIDs where firstHolder[member] == nil { firstHolder[member] = fid }
            }
        }
        for fid in folders.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            for member in folders[fid]?.appIDs ?? [] where firstHolder[member] == nil {
                firstHolder[member] = fid
            }
        }

        // 2) Strip each app from every folder that is not its authoritative holder.
        var repaired = 0
        for fid in Array(folders.keys) {
            guard var folder = folders[fid] else { continue }
            let before = folder.appIDs.count
            folder.appIDs.removeAll { firstHolder[$0] != fid }
            guard folder.appIDs.count != before else { continue }
            repaired += before - folder.appIDs.count
            if folder.appIDs.count <= 1 {
                // A one-app folder is not a folder: dissolve it.
                folders.removeValue(forKey: fid)
                let survivor = folder.appIDs.first.map { DeckSlot.app($0) } ?? .app("")
                replaceInGrid(.folder(fid), with: survivor)
                pages = pages.map { $0.filter { $0 != .app("") } }
            } else {
                folders[fid] = folder
            }
        }
        if repaired > 0 {
            recordDataRepair("\(repaired) folder membership(s) removed — an app was in more than one folder")
        }
    }

    // MARK: - Persistence

    /// Where the previous good copy lives (A2).
    private var backupURL: URL { storeURL.appendingPathExtension("bak") }

    /// A sibling path that preserves a copy of the current file, e.g.
    /// `layout.json.corrupt-2026-09-17T213000.123Z`. Colons are stripped because
    /// macOS does not allow `:` in a filename; the fractional seconds and the
    /// collision suffix are what make the name unique.
    ///
    /// Unique on purpose: the name used to have one-second resolution, so a
    /// second load in the same second — or any leftover file with that name —
    /// made the preservation `copyItem` fail with "destination exists". That
    /// flipped the store into `degradedReadOnly` and silently stopped saving for
    /// the whole session, for a reason that had nothing to do with the user's
    /// data. (It also means the old probe that manufactured the failure by
    /// pre-creating a same-named item can no longer do so — the injected
    /// `FileSeams.copyItem` failure replaces it.)
    private func preservedSiblingURL(reason: String) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = storeURL.deletingLastPathComponent()
        let base = storeURL.lastPathComponent + ".\(reason)-\(stamp)"
        var candidate = directory.appendingPathComponent(base)
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(suffix)")
            suffix += 1
        }
        return candidate
    }

    /// Sibling used when the file could not be decoded at all.
    private func corruptSiblingURL() -> URL { preservedSiblingURL(reason: "corrupt") }

    /// Decode a layout file at `url`, or nil when it is absent / unreadable /
    /// malformed. Never mutates state.
    private func decodeLayoutFile(at url: URL) -> LayoutFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LayoutFile.self, from: data)
    }

    /// Adopt a decoded layout into memory. Does not reconcile and does not save.
    private func apply(_ file: LayoutFile) {
        hidden = Set(file.hidden)
        // Same trap risk as customOrder below: dedupe rather than trap.
        folders = Dictionary(file.folders.map { ($0.id, $0) },
                             uniquingKeysWith: { first, _ in first })
        sortKey = file.sortKey
        sortOrder = file.sortOrder
        // An existing on-disk layout may already carry duplicates (an app that is
        // both a grid slot and a folder member). De-duplicate on load, keeping the
        // earliest position, so a damaged file heals instead of crashing.
        var seenOrder = Set<String>()
        customOrder = file.customOrder.filter { seenOrder.insert($0).inserted }

        var decodedPages: [[DeckSlot]] = []
        for page in file.pages {
            var items: [DeckSlot] = []
            for raw in page {
                if raw.hasPrefix("folder:"),
                   let uuid = UUID(uuidString: String(raw.dropFirst("folder:".count))) {
                    items.append(.folder(uuid))
                } else if raw.hasPrefix("app:") {
                    items.append(.app(String(raw.dropFirst("app:".count))))
                }
            }
            decodedPages.append(items)
        }
        pages = decodedPages.isEmpty ? [[]] : decodedPages
    }

    /// A2: rotate the current file to `layout.json.bak` before it is replaced.
    /// Best-effort — it never throws, so a rotation failure cannot abort a save.
    /// A missing or empty current file is left alone (nothing worth keeping).
    ///
    /// **Non-destructive by construction.** The new bytes are staged to
    /// `layout.json.bak.new` and only swapped in once the copy has fully
    /// succeeded. The previous version removed `.bak` and *then* copied, so any
    /// copy failure (disk full, permissions) silently destroyed the only
    /// backup — which is how a failed recovery could leave a user with no way
    /// back at all.
    private func rotateBackup() {
        let fm = FileManager.default
        guard let values = try? storeURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size > 0 else { return }
        let backup = backupURL
        let staging = backup.appendingPathExtension("new")
        try? fm.removeItem(at: staging)
        do {
            try seams.copyItem(storeURL, staging)
        } catch {
            NSLog("LaunchDeck: backup rotation skipped, previous backup kept: \(error.localizedDescription)")
            return
        }
        if fm.fileExists(atPath: backup.path) {
            do {
                // Atomic swap that keeps the old backup until the replacement is
                // complete; on failure the original stays where it is.
                _ = try fm.replaceItemAt(backup, withItemAt: staging)
                return
            } catch {
                NSLog("LaunchDeck: backup swap failed, previous backup kept: \(error.localizedDescription)")
                try? fm.removeItem(at: staging)
                return
            }
        }
        do {
            try fm.moveItem(at: staging, to: backup)
        } catch {
            NSLog("LaunchDeck: backup move failed: \(error.localizedDescription)")
            try? fm.removeItem(at: staging)
        }
    }

    private func loadLayout() {
        isLoading = true
        defer { isLoading = false }

        // First launch: no file yet. A fresh default layout is the correct,
        // legitimate outcome — reconcile, and let the normal save write it.
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            reconcile()
            return
        }

        if let file = decodeLayoutFile(at: storeURL) {
            // (B) `save()` never writes an empty `pages` array — `normalizePages`
            // guarantees at least `[[]]` — so `{"pages": []}` can only come from
            // an external tool emptying the file. It decodes fine, so it would
            // otherwise take the silent "reconcile and rebuild" path and be
            // overwritten with no trace. Treat it as structural corruption:
            // preserve the site, trace it, then rebuild. The rest of the file
            // (`customOrder`/`folders`/`hidden`) is still applied, so nothing the
            // user arranged is lost — and writes stay enabled.
            if file.pages.isEmpty {
                // This file is structurally bogus, so it must never become the
                // rotation source: `rotateBackup()` would copy it over the user's
                // only healthy `.bak`, which is the one artifact that could still
                // recover their layout. Set **before** `reconcile()` — the
                // `save()` it triggers reads the flag.
                suppressNextBackupRotation = true
                let preservedURL = preservedSiblingURL(reason: "empty-pages")
                let preserved = (try? seams.copyItem(storeURL, preservedURL)) != nil
                if !preserved {
                    // The only copy could not be preserved (disk full, directory
                    // not writable, name clash). A rebuild would call `save()` and
                    // overwrite that only copy — so stop writing instead. The flag
                    // MUST be set *before* `reconcile()`: its trailing `save()`
                    // would otherwise already have written.
                    degradedReadOnly = true
                    apply(file)
                    reconcile()
                    layoutHealthMessage = "The layout file listed no pages, which LaunchDeck never writes on its own, and a copy could not be saved as \(preservedURL.lastPathComponent). Changes made in this session will not be saved."
                    FileHandle.standardError.write(Data("LaunchDeck: \(layoutHealthMessage ?? "")\n".utf8))
                    return
                }
                apply(file)
                reconcile()
                layoutHealthMessage = "The layout file listed no pages, which LaunchDeck never writes on its own. A copy was kept as \(preservedURL.lastPathComponent) and the grid was rebuilt."
                FileHandle.standardError.write(Data("LaunchDeck: \(layoutHealthMessage ?? "")\n".utf8))
                return
            }
            apply(file)
            reconcile()
            return
        }

        // The file exists but could not be decoded: it is damaged. Never let a
        // reconstructed layout overwrite it. First, preserve the evidence.
        let corruptURL = corruptSiblingURL()
        let sitePreserved = (try? seams.copyItem(storeURL, corruptURL)) != nil

        // A2: recover from the backup when one is readable.
        if let backupData = try? Data(contentsOf: backupURL),
           let backupFile = try? JSONDecoder().decode(LayoutFile.self, from: backupData) {
            // Write the good bytes back **before** reconciling, so the
            // `rotateBackup()` inside the save that `reconcile()` triggers cannot
            // copy the damaged bytes over the good backup.
            //
            // The result must be checked. It used to be `try?` and swallowed:
            // when the write failed the main file stayed damaged, `reconcile()`
            // saved anyway, `rotateBackup()` deleted the one good `.bak` and could
            // not copy it back — and the user was told "it was restored from a
            // backup". A recovery that did not happen must never be reported as
            // one, and it must not cost the user their last good copy.
            guard (try? seams.writeData(backupData, storeURL)) != nil else {
                // Stop writing instead: with the main file still damaged, any save
                // would rotate those damaged bytes over the good backup first.
                // MUST precede `reconcile()` — its trailing `save()` would
                // otherwise already have run, and already done the damage.
                degradedReadOnly = true
                apply(backupFile)
                reconcile()
                lastError = sitePreserved
                    ? "The layout file could not be read. A backup was found but could not be written back, so it was left untouched; the damaged file was saved as \(corruptURL.lastPathComponent). Changes made in this session will not be saved."
                    : "The layout file could not be read. A backup was found but could not be written back, so it was left untouched, and the damaged file could not be preserved. Changes made in this session will not be saved."
                layoutHealthMessage = sitePreserved
                    ? "Your layout file was unreadable. The backup \(backupURL.lastPathComponent) is intact but could not be written back, so it was left alone; the damaged file was kept as \(corruptURL.lastPathComponent). This session will not save changes."
                    : "Your layout file was unreadable. The backup \(backupURL.lastPathComponent) is intact but could not be written back, so it was left alone. The damaged file could not be preserved. This session will not save changes."
                FileHandle.standardError.write(Data("LaunchDeck: \(lastError ?? "")\n".utf8))
                return
            }
            apply(backupFile)
            reconcile()
            // Set *after* `reconcile()`: a repair trace it may record concerns
            // the rebuilt in-memory layout, not the user's data, so it must not
            // bury the headline — the file was recovered from the backup. Only
            // claim the site was kept when the preservation copy really happened.
            lastError = sitePreserved
                ? "Recovered the layout from the backup after the main file could not be read; the damaged file was saved as \(corruptURL.lastPathComponent)."
                : "Recovered the layout from the backup after the main file could not be read; the damaged file could not be preserved."
            layoutHealthMessage = sitePreserved
                ? "Your layout file was unreadable; it was restored from a backup and the damaged file was kept as \(corruptURL.lastPathComponent)."
                : "Your layout file was unreadable; it was restored from a backup. The damaged file could not be preserved."
            FileHandle.standardError.write(Data("LaunchDeck: \(lastError ?? "")\n".utf8))
            return
        }

        // No usable backup: degrade to read-only so the damaged file is kept
        // (never overwritten) for the rest of the session.
        degradedReadOnly = true
        reconcile()
        lastError = sitePreserved
            ? "The layout file could not be read and no usable backup was found; it was saved as \(corruptURL.lastPathComponent). Changes made in this session will not be saved."
            : "The layout file could not be read and no usable backup was found; it could not be preserved. Changes made in this session will not be saved."
        layoutHealthMessage = sitePreserved
            ? "Your layout file could not be read and no usable backup was found. It was kept as \(corruptURL.lastPathComponent) and this session will not save changes."
            : "Your layout file could not be read and no usable backup was found, and it could not be preserved. This session will not save changes."
        FileHandle.standardError.write(Data("LaunchDeck: \(lastError ?? "")\n".utf8))
    }

    /// Group many mutations into a single write. A drag used to hit the disk on
    /// every pointer step, so a crash mid-drag left a half-applied layout.
    func beginBatch() {
        batchDepth += 1
    }

    func endBatch() {
        batchDepth = max(batchDepth - 1, 0)
        guard batchDepth == 0, pendingSave else { return }
        pendingSave = false
        save()
    }

    /// Open a drag session: hold writes (via a batch) **and** defer empty-page
    /// reclamation until the gesture ends (Q1). Idempotent — a second "open"
    /// from a duplicate gesture handler is a no-op, so the depth stays 1 and a
    /// single `endDragSession()` reliably closes it (§8.2).
    func beginDragSession() {
        guard !dragSessionActive else { return }
        dragSessionActive = true
        beginBatch()
    }

    /// Close a drag session: force the batch shut, reclaim the deferred empty
    /// pages exactly once, then flush if a write is owed. Idempotent, and also
    /// closes a bare batch left open by a missed gesture end.
    func endDragSession() {
        guard dragSessionActive || batchDepth > 0 else { return }
        dragSessionActive = false
        // Force the depth to zero (normally exactly one `endBatch()`). The gate
        // is already off, so the `save()` inside `endBatch` also reclaims.
        while batchDepth > 0 { endBatch() }
        if reclaimEmptyPages() { pendingSave = true }
        if pendingSave { pendingSave = false; save() }
    }

    func save() {
        // `degradedReadOnly` (A1): a damaged file that could not be decoded and
        // had no usable backup must never be overwritten with a reconstructed
        // layout — that would destroy the user's data *and* its evidence.
        guard !readOnly, !degradedReadOnly else { return }
        if batchDepth > 0 {
            pendingSave = true
            return
        }
        // Persistence guard (L4): an empty page must never reach disk, even on a
        // path that bypassed `endDragSession` (a session that never closed, or a
        // launch-time write). Complements the visible reclamation at session end.
        reclaimEmptyPages()
        let encodedPages = pages.map { page in
            page.map { item -> String in
                switch item {
                case .app(let id): return "app:\(id)"
                case .folder(let id): return "folder:\(id.uuidString)"
                }
            }
        }
        let file = LayoutFile(
            pages: encodedPages,
            // Sorted: dictionary iteration order is random, so two saves of
            // the same state produced different bytes.
            folders: folders.values.sorted { $0.id.uuidString < $1.id.uuidString },
            // Sorted for the same reason as `folders`: `Set` iteration order is
            // stable within a process but *not* across processes, so two runs of
            // the same binary wrote different bytes for an equal `hidden` set.
            hidden: hidden.sorted(),
            sortKey: sortKey,
            sortOrder: sortOrder,
            customOrder: customOrder
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(file)
            // A save whose bytes are already on disk must not write — and, above
            // all, must not rotate. `rotateBackup()` copies whatever is in the
            // file *right now* over `.bak`, so a redundant save replaces the one
            // previous generation with a twin of the current file and the earlier
            // state is gone for good. `.bak` is the only artifact the
            // decode-failure path can recover from, and the regression is
            // invisible: the main file's bytes do not change, so nothing looks
            // wrong. Several call sites legitimately save a state they did not
            // modify — `closeFolder()` after an Esc is the everyday one.
            //
            // Encoding is deterministic (`.sortedKeys`, plus the `sorted()` on
            // `folders`/`hidden` above), so comparing bytes is exact. A missing
            // file yields no comparison and falls through to a real write, which
            // is the first-launch path.
            if let onDisk = try? Data(contentsOf: storeURL), onDisk == data {
                return
            }
            // A2: keep the current on-disk layout as `layout.json.bak` before
            // replacing it, so a later corruption is recoverable. Best-effort —
            // a failed rotation must never abort the real save.
            if suppressNextBackupRotation {
                // The file on disk was already judged bad by the load path (an
                // empty-`pages` rebuild), so rotating it would replace the user's
                // one healthy backup with useless bytes. Consumed exactly once:
                // the write below makes the file good again.
                suppressNextBackupRotation = false
            } else {
                rotateBackup()
            }
            try data.write(to: storeURL, options: .atomic)
        } catch {
            lastError = "Save failed: \(error.localizedDescription)"
            NSLog("LaunchDeck: save failed: \(error)")
        }
    }
}
