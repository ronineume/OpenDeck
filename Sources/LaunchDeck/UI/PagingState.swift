import Foundation

/// The unique owner of "which page is the deck on".
///
/// Only `requestedPage` is stored. Every consumer reads the page through
/// `resolved(count:)`, which clamps on demand against the **current** page
/// count. So when `pages.count` shrinks outside a drag (fill-gaps, ungroup,
/// hide, startup reconcile), the next read re-derives a legal value and can
/// never index `pages` out of range — *read-time derivation* (Q5), never
/// write-time clamping with an observer.
///
/// ## Invariant — the grid must NEVER observe this object
///
/// `PagesScroller` observes only `PageJumper`; `PageDotsView` observes this
/// model (see below). If the grid observed the settled page value it would
/// rebuild up to 175 cells on **every** scroll tick — that is why paging was
/// moved out of `LaunchpadViewModel` in the first place. Do **not** merge this
/// object with `PageJumper` and hand it to the grid; that silently regresses the
/// optimisation and no self-test would catch it.
final class PagingModel: ObservableObject {
    /// The page the user *asked* for. May transiently sit outside `[0, count)`
    /// right after the page count shrinks; `resolved(count:)` clamps on read.
    ///
    /// Deliberately **never** written back (L8): if the count grows again the
    /// user returns to the page they had chosen rather than a clamped remnant.
    @Published private(set) var requestedPage = 0

    /// THE single derived point. Always in `[0, count)`. `count <= 1` → 0.
    func resolved(count: Int) -> Int {
        DragState.clampPage(requestedPage, count: count)
    }

    /// The single write point (replaces the seven raw `currentPage` writes).
    /// Returns the clamped value so callers can drive the jump signal with it:
    /// `jumper.target = paging.set(page, count: vm.pageCount)`.
    @discardableResult
    func set(_ page: Int, count: Int) -> Int {
        let clamped = DragState.clampPage(page, count: count)
        requestedPage = clamped
        return clamped
    }

    /// Reset to the first page (used by `LaunchpadViewModel.reset()`).
    func reset() { requestedPage = 0 }
}

/// A requested programmatic page jump (a dot click or an arrow key).
///
/// Kept as a **separate** object from `PagingModel` on purpose: `PagesScroller`
/// observes this one, and it would otherwise rebuild the grid on every settled
/// page. See `PagingModel`'s invariant note.
final class PageJumper: ObservableObject {
    @Published var target: Int?
}
