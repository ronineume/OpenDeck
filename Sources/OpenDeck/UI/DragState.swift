import SwiftUI
import AppKit

/// Which slot is currently lifted out of the grid, if any.
///
/// The grid has to hide the tile that has been lifted, or the deck shows two
/// copies of the icon — one under the pointer and one still in its slot. But the
/// grid deliberately does **not** observe `DragState`, which publishes the
/// pointer on every move and would redraw every cell at pointer rate. Identity
/// changes twice per drag, so it gets an observable of its own.
final class DragSourceBadge: ObservableObject {
    @Published var slotID: String?
}

/// Owns an in-progress drag.
///
/// Mirrors what LaunchOS does with an AppKit dragging session: the pointer is
/// tracked directly, the grid **reflows live** so a gap follows the cursor —
/// except over a hovered tile, which must not move — and a fold happens on the
/// release, over another app's tile or a folder, nowhere else.
///
/// ## Why a merge is armed on the tile, not the cell (report 45)
///
/// Report 40 removed the app target: OpenDeck's whole-cell reflow put the
/// dragged icon *into* the hovered cell, so by the time the button came up
/// "released on another app" and "released where I just moved it" were the same
/// geometry. The user then watched LaunchOS do what 40 said it could not —
/// hover an icon and it waits with a merge effect, release creates the folder,
/// and a larger movement repositions. The binary agrees after a second look:
/// `isDraggingMerge` is an ivar in three LaunchOS classes (a merge state the
/// report-40 pass never read), and the `dropActionHoverDelay` evidence only
/// ever ruled out a *timer*, not a release-time merge.
///
/// The fix is scoping, not mechanism. The merge is armed only when the pointer
/// is **on the tile** (`GridHitTester.overTile`); a merge hover never reflows —
/// so the hovered tile is never slid out from under the pointer. And the cell
/// margin is an insertion point only **past** the tile: the user pinned the
/// distance judgment — moving an icon toward another from the right prepares
/// the merge on contact, and the position only changes once the icon has moved
/// to the other icon's left. So the reflow at an occupied cell is gated on the
/// pointer having crossed that cell's tile (`crossedTileIDs`); an approach-side
/// margin moves nothing, and a release there sends the icon home.
///
/// ## What is deliberately absent
///
/// No hover *matures* into anything while the button is down: there is no
/// timer, and the merge is the release's decision. (LaunchOS's
/// `isDraggingMerge` marks the hovered tile — a state, not an action — and
/// OpenDeck mirrors it with the drop-hover zoom and merge ring.) OpenDeck used
/// to add two inventions on top — a circular 1.2 s countdown ring (and the
/// 60 Hz `Timer` that drove it) and a vertical insertion seam. Both are gone:
/// they were the reason a drag did not read like the original.
final class DragState: ObservableObject {
    @Published private(set) var item: DeckSlot?
    @Published private(set) var proxyApp: AppInfo?
    @Published private(set) var proxyTitle: String?
    @Published var location: CGPoint = .zero
    @Published private(set) var isActive = false
    @Published private(set) var hoverIndex: Int?
    @Published private(set) var hoverPage: Int?

    /// Set while a drag that was refused should be explained on screen, then
    /// cleared on its own.
    ///
    /// LaunchOS refuses the same gesture rather than allowing it to fail
    /// quietly. Refusing *silently* is the worst of the three: the user cannot
    /// tell a locked deck from a broken one.
    @Published private(set) var blockedNotice: String?

    /// Called when the grid should reflow so the item sits at `index`.
    var onLiveMove: ((DeckSlot, Int) -> Void)?
    /// Called when a hover over a page dot or screen edge has matured.
    var onRequestPage: ((Int) -> Void)?

    /// Which slot is lifted out of the grid, as its own observable — see
    /// `DragSourceBadge` for why the grid cannot just watch this object.
    let badge = DragSourceBadge()

    /// What a drag can fold into.
    enum CombineTarget: Equatable {
        /// An app. **The current rule never produces this** — see
        /// `combineTarget` and report 40. The case is kept on purpose: the rule
        /// has to stay a one-line change, and the check that an app is *not* a
        /// target can only be pinned by a mutation that restores the old line.
        /// A mutation is a text patch, so deleting the failure mode outright
        /// would leave that check hollow.
        case app(String)
        /// The app joins this folder.
        case folder(UUID)
    }

    /// Where a drag came from. Carried explicitly so the commit can dispatch on
    /// it instead of re-resolving the source with `store.locate(...)` — which
    /// returns `nil` for a folder member and silently swallowed the drop.
    enum Source: Equatable {
        /// A standalone grid slot.
        case grid
        /// A member of `folderID` (it has no grid slot of its own).
        case folderMember(UUID)
    }

    /// Frames in the deck's coordinate space; not published, they change on
    /// layout and republishing would fight the drag.
    var gridFrame: CGRect = .zero
    var dotsFrame: CGRect = .zero
    var deckSize: CGSize = .zero
    var dotCount: Int = 1

    /// The scroll view's own content offset. Recorded, never published: it
    /// changes on every scroll frame and republishing would rebuild the grid.
    /// Read once, at the moment a drag begins.
    var scrollOffset: CGFloat = 0

    /// Snapshot of the page being dragged over, for the target marker.
    var itemCount = 0
    var capacity = 0

    /// How long a hover must rest before the page turns.
    private static let pageFlipDelay: TimeInterval = 0.5
    /// Distance from the left/right edge that starts a page flip.
    private static let edgeInset: CGFloat = 70

    // MARK: - When a drag may begin at all

    /// Whether a drag may begin under `sortKey`.
    ///
    /// LaunchOS gates the whole gesture on the sort, and says so in as many
    /// words — "Dragging to reorder is only available in Custom sort mode."
    /// OpenDeck used to accept the drag and drop the result on the floor:
    /// `pages` moved, but `syncCustomOrder()` bails out when the sort is not
    /// `.manual`, so the new order was never recorded and the next sort silently
    /// undid it. Refusing up front, with a reason, is the honest form of the
    /// same rule.
    static func allowsDrag(sortKey: SortKey) -> Bool { sortKey == .manual }

    /// Shown when a drag is refused because the sort is not `.manual`.
    static let reorderLockedMessage =
        "Dragging to reorder is only available in Custom sort mode."

    /// Which screen edge the pointer is parked against, if any.
    ///
    /// Named for LaunchOS's `DragEdgeZone`, which exists for the same reason:
    /// the edge test is a rule about the deck's geometry rather than a detail of
    /// pointer tracking, so it lives in a pure function the self-test can drive
    /// with plain numbers instead of a window.
    enum EdgeZone: Equatable {
        case leading
        case trailing
    }

    /// The zone `x` falls into for a deck `width` wide, or nil in between.
    /// `inset` is how far in from the edge the band reaches.
    static func edgeZone(x: CGFloat, width: CGFloat, inset: CGFloat) -> EdgeZone? {
        guard width > 0, inset > 0 else { return nil }
        if x <= inset { return .leading }
        if x >= width - inset { return .trailing }
        return nil
    }

    /// How long a refusal stays on screen.
    private static let noticeDuration: TimeInterval = 3.0

    private var liveIndex = -1
    private var livePage = 0
    private var flipWork: DispatchWorkItem?
    /// The tile the pointer is on, if releasing there would fold.
    /// Held rather than recomputed at the drop because the live reflow moves the
    /// dragged item *into* the hovered slot — by the time the button comes up,
    /// the slot names the dragged app, not the one it landed on.
    private var combineCandidate: CombineTarget?
    /// Tiles whose cell the pointer has **crossed** during this drag, keyed by
    /// the occupant's `DeckSlot.id`. Touching a tile marks it crossed; the gap
    /// may only open in a cell whose tile is crossed (or that is empty). The
    /// user's distance judgment: the approach side of an icon moves nothing —
    /// the position only changes once the icon has moved past it.
    private var crossedTileIDs: Set<String> = []
    /// The same folder, published: the drop-hover signal. The grid must not
    /// observe `DragState` (LaunchpadView deliberately does not), so the drag
    /// host mirrors this into the store and `FolderCell` consumes it to play
    /// the decoded drop-hover zoom (1.05). Follows `combineCandidate` — the
    /// zoom means exactly "releasing here would fold" — and nothing else.
    @Published private(set) var combineFolderID: UUID?
    /// The same signal for a merge over an **app** tile: the app the dragged
    /// icon would fold with into a new folder. Mirrored by the drag host into
    /// the store and consumed by `AppCell` (zoom + ring). Follows the same
    /// tile rule as `combineFolderID`.
    @Published private(set) var combineAppID: String?
    /// Clears `blockedNotice` on its own after `noticeDuration`.
    private var noticeWork: DispatchWorkItem?

    // MARK: - Lifecycle

    func begin(item: DeckSlot, app: AppInfo?, title: String?, index: Int, page: Int,
               source: Source = .grid, location: CGPoint) {
        guard !isActive else { return }
        // A real drag supersedes any refusal still on screen.
        clearBlockedNotice()
        combineFolderID = nil
        combineAppID = nil
        crossedTileIDs = []
        // The grid hides this tile for as long as the drag lives, so the deck
        // shows one icon — the one under the pointer — instead of two.
        badge.slotID = item.id
        self.item = item
        proxyApp = app
        proxyTitle = title
        self.source = source
        liveIndex = index
        livePage = page
        self.location = location
        isActive = true
    }

    /// Where this drag came from. `.grid` for an ordinary in-grid drag, or the
    /// folder an expanded-folder member was pulled from.
    private(set) var source: Source = .grid

    /// Compatibility view of `source` for call sites that only need the
    /// originating folder (the folder-overlay teardown path).
    var sourceFolder: UUID? {
        if case .folderMember(let id) = source { return id }
        return nil
    }

    /// Promote a folder-member drag to an ordinary grid drag (report 46).
    ///
    /// The moment the pointer leaves the expanded panel, LaunchOS collapses the
    /// folder and the pull continues as a plain grid drag. The host has already
    /// moved the member onto the grid when it calls this — which is what makes
    /// the promotion honest: the live reflow's `store.locate` starts answering,
    /// so the gap follows the pointer for the rest of the drag, and the release
    /// is resolved by the **grid** rules — including the fold into another tile,
    /// which a member release can never do (`drop()` gates the combine on
    /// `.grid` on purpose).
    ///
    func promoteToGrid() {
        guard source != .grid else { return }
        source = .grid
    }

    /// Report 46 — has the pointer left the expanded panel? The panel's
    /// registered frame is its **grid content** box; the visible plate adds
    /// `padding` around it, so the exit test is run against the inset rect.
    /// Pure so the self-test can drive the boundary with plain numbers.
    static func exitedPanel(pointer: CGPoint, panelFrame: CGRect, padding: CGFloat) -> Bool {
        !panelFrame.insetBy(dx: -padding, dy: -padding).contains(pointer)
    }

    func reset() {
        flipWork?.cancel(); flipWork = nil
        combineCandidate = nil
        combineFolderID = nil
        combineAppID = nil
        crossedTileIDs = []
        noticeWork?.cancel(); noticeWork = nil
        blockedNotice = nil
        badge.slotID = nil
        item = nil
        proxyApp = nil
        proxyTitle = nil
        hoverIndex = nil
        hoverPage = nil
        source = .grid
        liveIndex = -1
        isActive = false
    }

    // MARK: - Tracking

    func update(location: CGPoint, page: Int, metrics: GridMetrics, pageItems: [DeckSlot], capacity: Int) {
        guard isActive else { return }
        self.location = location
        self.itemCount = pageItems.count
        self.capacity = capacity

        // Dragging to the left/right edge flips pages, which is how Launchpad
        // crosses pages — far easier to hit than the dots.
        //
        // Deliberately *not* gated on `!gridFrame.contains(location)`:
        // `gridFrame` is the scroll viewport, which spans the full window width,
        // so that gate made edge paging unreachable for every ordinary in-grid
        // drag and left it firing only in the chrome bands above and below.
        switch Self.edgeZone(x: location.x, width: deckSize.width, inset: Self.edgeInset) {
        case .some(.leading): requestPage(page - 1)
        case .some(.trailing): requestPage(page + 1)
        case .none: requestPage(nil)
        }

        if dotsFrame.contains(location) {
            setHoverPage(pageIndex(forDotAt: location), current: page)
            return
        }
        if !dotsFrame.contains(location) { setHoverPage(nil, current: page) }

        guard gridFrame.contains(location) else {
            hoverIndex = nil
            combineCandidate = nil
            combineFolderID = nil
            combineAppID = nil
            return
        }

        // The grid does **not** move during a drag — the strip stays where the
        // scroll view left it and a page turns only on an edge dwell — so a deck
        // point is already a grid point and there is nothing to take back out.
        // (An earlier cut slid the whole strip with the pointer and subtracted
        // that travel here; report 37 §2 is why it is gone.)
        let local = CGPoint(
            x: location.x - gridFrame.minX,
            y: location.y - gridFrame.minY
        )
        let tester = GridHitTester(
            metrics: metrics,
            itemCount: pageItems.count,
            containerSize: gridFrame.size,
            slotCount: capacity
        )
        guard let index = tester.index(at: local) else {
            hoverIndex = nil
            combineCandidate = nil
            combineFolderID = nil
            combineAppID = nil
            return
        }
        hoverIndex = index

        // Decide *before* reflowing, and only on the tile: a merge is armed
        // when the pointer is on the icon itself. There is **no timer here**:
        // the candidate is refreshed on every move and read once, at the drop.
        // (This used to arm a 1.2 s rest-to-combine, which turned two icons
        // into a folder while the button was still down; LaunchOS waits for
        // the release.)
        var decision = Self.combineDecision(item: item, pageItems: pageItems, index: index)
        if decision != .keep, !tester.overTile(at: local, index: index) {
            decision = .cancel
        }
        switch decision {
        case .keep:
            // The live reflow already put the dragged item here, so this is the
            // app it displaced. Keep the candidate that named it.
            break
        case .start(let target):
            combineCandidate = target
            if case .folder(let id) = target { combineFolderID = id } else { combineFolderID = nil }
            if case .app(let id) = target { combineAppID = id } else { combineAppID = nil }
            // The touch marks the tile crossed: the gap may only open past it.
            crossedTileIDs.insert(pageItems[index].id)
        case .cancel:
            combineCandidate = nil
            combineFolderID = nil
            combineAppID = nil
        }

        // A slot the reflow has already filled with the dragged item has nothing
        // left to report — and it is where the pointer spends most of the drag.
        if decision == .keep { return }

        // A merge hover never reflows: the tile under the pointer must not be
        // slid out from under it. LaunchOS holds the hovered tile in place —
        // the user watched a folder stay put while hovered — and sliding it
        // away is exactly what made the target "run". Skipping the reflow also
        // leaves `liveIndex` where it was, so the gap reopens the moment the
        // pointer moves off the tile.
        if case .start = decision { return }

        // The distance judgment (report 45). A cell holding another icon is an
        // insertion point only **past** its tile: on the approach side — margin,
        // tile untouched — nothing moves. Empty slots keep the old
        // gap-follows-pointer behavior; there is no tile to cross there.
        let occupant = index < pageItems.count ? pageItems[index] : nil
        if let occupant, occupant != item, !crossedTileIDs.contains(occupant.id) {
            return
        }

        // Fire on every change of target, including after a page flip: gating
        // on `page == livePage` killed all drop feedback for the rest of the
        // drag once the user crossed a page.
        //
        // This *is* the reflow: the grid opens the gap under the pointer as it
        // moves, which is what tells the user where a drop will land.
        if index != liveIndex {
            liveIndex = index
            livePage = page
            onLiveMove?(item ?? .app(""), index)
        }
    }

    /// What the drag should do about folding at `index`.
    enum CombineDecision: Equatable {
        /// The dragged item already occupies the slot, so the slot no longer
        /// names what the pointer is over.
        case keep
        case start(CombineTarget)
        case cancel
    }

    /// Pure decision used by `update`. Exists as its own function because the
    /// live reflow moves the dragged item *into* the hovered slot, so the naive
    /// "look at what is under the pointer" reading reports the dragged app as
    /// its own combine target — which silently disabled folding.
    static func combineDecision(item: DeckSlot?, pageItems: [DeckSlot], index: Int) -> CombineDecision {
        guard let item else { return .cancel }
        if index >= 0, index < pageItems.count, pageItems[index] == item { return .keep }
        if let target = combineTarget(item: item, pageItems: pageItems, index: index) {
            return .start(target)
        }
        return .cancel
    }

    /// Clamp a requested page into range. Negative indices used to reach
    /// `store.pages[-1]` and trap on the next pointer move.
    static func clampPage(_ page: Int, count: Int) -> Int {
        min(max(page, 0), max(count - 1, 0))
    }

    /// What a drag should fold with when the button comes up over `index`.
    ///
    /// **The tile under the pointer**: an app folds with it into a new folder,
    /// a folder absorbs the app. Report 45 reverses report 40's app-less rule —
    /// the tile-scoped merge hover (no reflow while armed) removes the geometry
    /// collision that motivated it, and LaunchOS arms exactly this merge
    /// (`isDraggingMerge`).
    ///
    /// Bounds-checked on purpose: the hit tester reports trailing *empty* slots
    /// as droppable, so `index` may be past the last item. Pure, so the crash
    /// path is covered by the self-test.
    static func combineTarget(item: DeckSlot?, pageItems: [DeckSlot], index: Int) -> CombineTarget? {
        guard let item, case .app = item else { return nil }
        guard index >= 0, index < pageItems.count else { return nil }
        switch pageItems[index] {
        case .app(let appID): return .app(appID)
        case .folder(let folderID): return .folder(folderID)
        }
    }

    private func setHoverPage(_ page: Int?, current: Int) {
        guard hoverPage != page else { return }
        hoverPage = page
        guard let page, page != current else { return }
        schedulePageChange(page)
    }

    private func requestPage(_ page: Int?) {
        guard let page else {
            flipWork?.cancel(); flipWork = nil
            return
        }
        schedulePageChange(page)
    }

    private func schedulePageChange(_ page: Int) {
        guard flipWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.flipWork = nil
            self?.onRequestPage?(page)
        }
        flipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pageFlipDelay, execute: work)
    }

    // MARK: - Refusal

    /// Refuse a drag that `allowsDrag(sortKey:)` rejected, leaving the reason on
    /// screen for a moment.
    ///
    /// Called from the gesture's first change and *before* a drag session is
    /// opened, so a locked deck never holds a session open — an open session
    /// swallows every later `save()`.
    func refuseBegin(_ message: String) {
        blockedNotice = message
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.noticeWork = nil
            self?.blockedNotice = nil
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noticeDuration, execute: work)
    }

    /// Clear the refusal notice early: a real drag supersedes it.
    ///
    /// Guarded so the common path publishes nothing — `blockedNotice` is
    /// `@Published` and the notice layer redraws on every change.
    func clearBlockedNotice() {
        guard blockedNotice != nil || noticeWork != nil else { return }
        noticeWork?.cancel()
        noticeWork = nil
        blockedNotice = nil
    }

    // MARK: - Drop

    enum Drop: Equatable {
        case none
        case toPage(Int)
        case toIndex(Int)
        /// Released on a tile: the app joins the folder under it, or folds with
        /// another app into a new folder. The store change itself is the host's,
        /// done at the moment of the drop — this object only says *that* it
        /// should happen and with what.
        case combine(CombineTarget)
    }

    func drop(metrics: GridMetrics, pageItems: [DeckSlot]) -> Drop {
        guard isActive, let item else { return .none }
        // A fold is decided from the remembered candidate, not from the grid:
        // after any reflow `pageItems` no longer names what the user aimed at
        // (and during a merge hover the reflow never ran at all). Only a
        // standalone grid tile folds — a member dragged inside an open folder
        // panel is a reorder within that panel, and the grid behind the panel
        // is not what the user is looking at.
        if source == .grid, let target = combineCandidate, case .app = item {
            return .combine(target)
        }
        if let page = hoverPage { return .toPage(page) }
        guard let index = hoverIndex else { return .none }
        // The crossing rule reaches the release too: a cell whose tile the
        // pointer never crossed never became an insertion point, so releasing
        // on the approach side leaves the icon where the grid last put it —
        // home, if no gap ever opened.
        if index < pageItems.count, pageItems[index] != item,
           !crossedTileIDs.contains(pageItems[index].id) {
            return .none
        }
        if index < pageItems.count, pageItems[index] == item { return .none }
        return .toIndex(index)
    }

    private func pageIndex(forDotAt point: CGPoint) -> Int? {
        guard dotsFrame.width > 0, dotCount > 0 else { return nil }
        let relative = (point.x - dotsFrame.minX) / dotsFrame.width
        guard relative >= 0, relative <= 1 else { return nil }
        return min(Int(relative * CGFloat(dotCount)), dotCount - 1)
    }

    /// Cancels any timer still armed, so a pending page turn cannot fire after
    /// the deck that owns this object is gone — e.g. Esc tears the deck down
    /// mid-drag, or the window is destroyed while a turn is pending.
    deinit {
        flipWork?.cancel()
        noticeWork?.cancel()
    }
}
