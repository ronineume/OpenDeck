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

/// Arbitrates between the page the scroll view reports and the page a jump
/// asked for.
///
/// Deliberately a **class** with no `@Published` anywhere: it is written on
/// every reported page change, and republishing would rebuild the whole grid —
/// the same trap `PagingModel`'s invariant note describes.
///
/// ## The bug this exists for
///
/// A jump moves two things at once: the page the model believes in, and the
/// scroll offset. The offset catches up afterwards, and a jump that animates
/// reports every page it passes through on the way. Those reports name pages
/// the user never chose, so adopting one overwrites the jump before it lands and
/// `onPageSettled` then writes the *wrong* page into preferences.
///
/// Measured on this machine before the guard: a resume-at-page-2 launch ended
/// with `lastPage` at 0, on every launch.
final class PageJumpGuard {
    /// The page the scroll view last reported. Seeded to 0 because a freshly
    /// built scroll view sits at offset 0.
    private(set) var reportedPage = 0

    /// The page a jump asked for, until the scroll view reports it. `nil` when
    /// no jump is in flight, i.e. every report is the user's.
    private(set) var inFlight: Int?

    /// Forgets everything, so a guard reaching a newly built grid cannot carry a
    /// jump from the previous one.
    func reset() {
        reportedPage = 0
        inFlight = nil
    }

    /// A jump is about to drive the scroll view to `page`.
    ///
    /// - Returns: whether the scroll view actually has to move.
    ///
    ///   A jump to the page it is already on is **not** armed. Nothing will be
    ///   reported for it, and a guard that nothing ever clears would swallow the
    ///   user's next scroll instead.
    func arm(_ page: Int) -> Bool {
        guard page != reportedPage else {
            inFlight = nil
            return false
        }
        inFlight = page
        return true
    }

    /// The user took over — a drag began — so a jump that has not landed loses
    /// its claim on the next report. Without this, a jump interrupted by a
    /// finger would keep swallowing reports until the page it wanted finally
    /// appeared, which may be never.
    func disarm() { inFlight = nil }

    /// Whether a page reported by the scroll view should be adopted as the
    /// user's page.
    ///
    /// - Returns: `false` for every report made while a jump is in flight,
    ///   including the one that finally arrives — that one only ends the jump,
    ///   and there is nothing left to change. With no jump in flight, a report
    ///   naming the page we already believe in is ignored too, which is what
    ///   keeps a redundant write (and its preferences write) out of the settle
    ///   path.
    func observe(reported page: Int, requested: Int) -> Bool {
        reportedPage = page
        guard let target = inFlight else { return page != requested }
        guard page == target else { return false }
        inFlight = nil
        return false
    }
}
