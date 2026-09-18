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
    @Published var folderNameDraft = ""
    /// Where the folder tile was on screen when it was opened, so the expanded
    /// panel can grow out of it (the animation proxy's start frame).
    @Published var folderOrigin: CGRect?

    let store: DeckStore
    let paging = PagingModel()
    let jumper = PageJumper()
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
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }

        let pool = DeckSettings.shared.showHiddenInSearch ? store.apps : store.visibleApps
        return pool
            .compactMap { app -> (AppInfo, Int)? in
                let name = app.name.lowercased()
                let score: Int
                if name == needle {
                    score = 0
                } else if name.hasPrefix(needle) {
                    score = 1
                } else if name.contains(needle) {
                    score = 2
                } else if let bid = app.bundleID?.lowercased(), bid.contains(needle) {
                    score = 3
                } else if Self.isSubsequence(needle, of: name) {
                    score = 4
                } else {
                    return nil
                }
                return (app, score)
            }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                return a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
            }
            .map(\.0)
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
        store.save()
    }

    func reset() {
        query = ""
        selection = -1
        openedFolder = nil
        folderOrigin = nil
        isEditingFolderName = false
        // Redundant safety net: `show()`/`hide()` both call `reset()`, so a
        // session left open by a missed `onEnded` is closed here too.
        store.endDragSession()
        paging.reset()
        jumper.target = nil
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
            // A folder panel is not always four columns wide — the column count
            // depends on the member count (see `FolderLayout`). Using a hard-coded
            // 4 here made ↑/↓ skip or mis-align rows for 2–9 member folders.
            let cols = FolderLayout.columns(forMemberCount: count)
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
