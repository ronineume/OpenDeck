import SwiftUI
import AppKit

/// Drives search, selection and folder state.
///
/// Paging and hover deliberately live elsewhere (`PagingModel`, `PageJumper`,
/// `HoverState`) because anything published here re-evaluates the whole deck.
/// Paging state used to be here, which meant every scroll tick rebuilt 175 cells.
@MainActor
final class LaunchpadViewModel: ObservableObject {
    @Published var query = ""
    /// -1 means "no keyboard selection", matching Launchpad's idle look.
    @Published var selection = -1
    @Published var openedFolder: UUID?
    @Published var isEditingFolderName = false
    /// Set to ask the open folder to play its closing animation. The overlay
    /// animates itself and then calls back, because relying on SwiftUI's removal
    /// transition did not animate reliably.
    @Published var folderClosing = false
    /// Report 46 — set when a drag **pulls a member out** of the open panel:
    /// the panel plays the same collapse, but the teardown afterwards is a
    /// light one. A full `closeFolder()` would call `store.endDragSession()`
    /// while the drag is still live, reclaiming the deferred empty pages under
    /// a drag that is still flying — so the pull-out path clears only the
    /// overlay's own state and leaves the session to the commit.
    @Published var folderMinimizing = false
    @Published var folderNameDraft = ""
    /// Where the folder tile was on screen when it was opened, so the expanded
    /// panel can grow out of it (the animation proxy's start frame).
    @Published var folderOrigin: CGRect?

    /// Geometry of the expanded folder panel's grid, in deck coordinates.
    ///
    /// Deliberately **not** published: it changes on layout, and republishing it
    /// would re-evaluate the deck. Written by `FolderOverlayView` as it lays out,
    /// read by `DeckDragHost`'s hit test — the host has to be able to tell which
    /// tile inside the panel was pressed, and only the view knows where the panel
    /// is.
    var folderPanel: FolderPanelLayout?

    let store: DeckStore
    let paging = PagingModel()
    let jumper = PageJumper()
    /// Arbitration for programmatic jumps. Owned here rather than by the grid
    /// because it describes the relationship between `paging` and the scroll
    /// view, and because `reset()` is the one place that knows a deck is being
    /// built anew — a guard left armed on a rebuilt grid would swallow the first
    /// scroll of the new session.
    let jumpGuard = PageJumpGuard()
    /// Set by the window controller so keyboard actions can dismiss the deck.
    var dismiss: (() -> Void)?
    /// Set by the window controller so the gear button can open settings.
    var openSettings: (() -> Void)?

    init(store: DeckStore) {
        self.store = store
    }

    var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Search

    /// Ranked search over name and bundle identifier.
    var searchResults: [AppInfo] {
        let raw = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !raw.isEmpty else { return [] }
        // Spaces are dropped on both sides of the latin comparison, so a user who
        // types "wei xin" and one who types "weixin" get the same result against
        // the space-separated transliteration.
        let needle = raw.replacingOccurrences(of: " ", with: "")

        let pool = DeckSettings.shared.showHiddenInSearch ? store.apps : store.visibleApps
        return pool
            .compactMap { app -> (AppInfo, Int)? in
                guard let score = Self.matchScore(
                    name: app.name,
                    latin: cachedLatinKey(for: app.name),
                    bundleID: app.bundleID,
                    raw: raw,
                    needle: needle
                ) else { return nil }
                return (app, score)
            }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                return a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
            }
            .map(\.0)
    }

    /// The rank of an app against the query, or nil when nothing matches.
    ///
    /// Pulled out as a **pure function** so the ranking can be asserted directly
    /// instead of through a store and a live search. `raw` is the trimmed,
    /// lowercased query and `needle` is the same with spaces removed; `latin` is
    /// the name's transliteration in the same no-space form (see `latinized`).
    static func matchScore(
        name: String,
        latin: String?,
        bundleID: String?,
        raw: String,
        needle: String
    ) -> Int? {
        let name = name.lowercased()
        if name == raw || latin == needle { return 0 }
        if name.hasPrefix(raw) || latin?.hasPrefix(needle) == true { return 1 }
        if name.contains(raw) || latin?.contains(needle) == true { return 2 }
        if let bid = bundleID?.lowercased(), bid.contains(raw) { return 3 }
        if isSubsequence(needle, of: name) { return 4 }
        if let latin, isSubsequence(needle, of: latin) { return 4 }
        return nil
    }

    /// Lowercased transliteration of `name` with spaces removed, or nil.
    ///
    /// **Static and pure on purpose.** An earlier draft made this the caching
    /// instance method itself, and the space-stripping it performs was then
    /// unreachable from the self-test: every assertion built its own `latin:`
    /// argument and called `matchScore` directly, so deleting the strip left the
    /// suite green (report 42, mutation M107). The cache below is now a separate
    /// wrapper, and this seam is the one the assertions drive.
    static func latinKey(for name: String) -> String? {
        let value = latinized(name)?.replacingOccurrences(of: " ", with: "") ?? ""
        return value.isEmpty ? nil : value
    }

    /// Cache of `latinKey` results, keyed by the original name.
    ///
    /// `CFStringTransform` walks the whole string through ICU, so calling it for
    /// every app on every keystroke would show up on a large grid. A name does
    /// not change during a session, so the answer is computed once per name. An
    /// empty string means "no transliteration", which is different from "not
    /// looked up yet".
    private var latinCache: [String: String] = [:]

    private func cachedLatinKey(for name: String) -> String? {
        let value: String
        if let hit = latinCache[name] {
            value = hit
        } else {
            value = Self.latinKey(for: name) ?? ""
            latinCache[name] = value
        }
        return value.isEmpty ? nil : value
    }

    /// Latin transliteration of `name`, lowercased — "微信" becomes "wei xin".
    ///
    /// Uses the system's ICU-backed transform, so the app ships **no** dictionary
    /// and gains **no** dependency. Returns nil when the transform is unavailable,
    /// in which case the caller simply has one fewer way to match rather than the
    /// search failing.
    static func latinized(_ name: String) -> String? {
        let mutable = NSMutableString(string: name) as CFMutableString
        guard CFStringTransform(mutable, nil, kCFStringTransformToLatin, false) else { return nil }
        guard CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false) else { return nil }
        return (mutable as String).lowercased()
    }

    /// Character-subsequence match, so "gimp" can find "GraphicImageProcessor".
    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var it = haystack.makeIterator()
        for ch in needle {
            var matched = false
            while let next = it.next() {
                if next == ch {
                    matched = true
                    break
                }
            }
            if !matched { return false }
        }
        return true
    }

    // MARK: - Paging

    func items(forPage page: Int) -> [DeckSlot] {
        guard page < store.pages.count else { return [] }
        return store.pages[page]
    }

    var pageCount: Int { max(store.pages.count, 1) }

    func goToPage(_ page: Int) {
        // `paging.set` clamps internally; the jump signal carries the clamped value.
        jumper.target = paging.set(page, count: pageCount)
        selection = -1
    }

    // MARK: - Selection

    func activateSelection() {
        if isSearching {
            let results = searchResults
            let index = selection < 0 ? 0 : selection
            guard index < results.count else { return }
            LaunchService.launch(results[index])
            dismiss?()
            return
        }

        if let folderID = openedFolder {
            let apps = store.folderApps(folderID)
            guard selection < apps.count else { return }
            LaunchService.launch(apps[selection])
            dismiss?()
            return
        }

        let items = items(forPage: paging.resolved(count: pageCount))
        guard selection >= 0, selection < items.count else { return }
        switch items[selection] {
        case .app(let id):
            if let app = store.app(id: id) {
                LaunchService.launch(app)
                dismiss?()
            }
        case .folder(let fid):
            openFolder(fid)
        }
    }

    func openFolder(_ id: UUID) {
        folderOrigin = FrameRegistry.shared.frame(for: DeckSlot.folder(id).id)
        openedFolder = id
        selection = -1
        isEditingFolderName = false
    }

    func closeFolder() {
        // Esc with a folder open routes here and *returns true* (see
        // `handleKeyDown`), so the window is never hidden and
        // `LaunchpadWindowController.hide()` never runs. Any drag session opened
        // before that Esc must still be closed here, or a stuck session would
        // swallow every later `save()` (data loss). Symmetric with the hide path.
        store.endDragSession()
        openedFolder = nil
        folderOrigin = nil
        selection = -1
        isEditingFolderName = false
        folderClosing = false
        folderMinimizing = false
        store.save()
    }

    func reset() {
        query = ""
        selection = -1
        openedFolder = nil
        folderOrigin = nil
        folderPanel = nil
        isEditingFolderName = false
        folderClosing = false
        folderMinimizing = false
        // Redundant safety net: `show()`/`hide()` both call `reset()`, so a
        // session left open by a missed `onEnded` is closed here too.
        store.endDragSession()
        paging.reset()
        jumper.target = nil
        jumpGuard.reset()
    }

    // MARK: - Keyboard

    /// Returns true when the event was consumed.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Escape
            if isEditingFolderName {
                isEditingFolderName = false
                return true
            }
            if openedFolder != nil {
                closeFolder()
                return true
            }
            if isSearching {
                query = ""
                selection = 0
                return true
            }
            return false // the window closes

        case 36, 76: // Return / keypad Enter
            activateSelection()
            return true

        case 123: // Left
            if !isSearching { moveSelection(dx: -1, dy: 0); return true }
            return false

        case 124: // Right
            if !isSearching { moveSelection(dx: 1, dy: 0); return true }
            return false

        case 125: // Down
            if !isSearching { moveSelection(dx: 0, dy: 1); return true }
            return false

        case 126: // Up
            if !isSearching { moveSelection(dx: 0, dy: -1); return true }
            return false

        default:
            return false
        }
    }

    private func moveSelection(dx: Int, dy: Int) {
        // First arrow press just establishes a selection.
        if selection < 0 {
            if openedFolder == nil, !items(forPage: paging.resolved(count: pageCount)).isEmpty { selection = 0 }
            if let folder = openedFolder, !store.folderApps(folder).isEmpty { selection = 0 }
            return
        }

        if let folderID = openedFolder {
            let count = store.folderApps(folderID).count
            guard count > 0 else { return }
            // A folder panel uses the page's column count (LaunchOS
            // `columnsPerPage`, see `FolderLayout`), so ↑/↓ must move by that
            // stride to stay aligned with the drawn grid.
            let cols = FolderLayout.columns(pageColumns: store.metrics.columns)
            let next = selection + dx + dy * cols
            if next >= 0, next < count { selection = next }
            return
        }

        let page = paging.resolved(count: pageCount)
        let current = items(forPage: page)
        guard !current.isEmpty else { return }
        let cols = max(store.metrics.columns, 1)

        // Horizontal overflow crosses page boundaries.
        if dx < 0, selection == 0, page > 0 {
            let previous = items(forPage: page - 1)
            goToPage(page - 1)
            selection = max(previous.count - 1, 0)
            return
        }
        if dx > 0, selection + 1 >= current.count, page < pageCount - 1 {
            goToPage(page + 1)
            selection = 0
            return
        }

        var index = selection + dx + dy * cols
        if index < 0 { index = 0 }
        if index >= current.count { index = current.count - 1 }
        selection = index
    }
}
