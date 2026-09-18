import SwiftUI
import AppKit

/// Owns an in-progress drag.
///
/// Mirrors what LaunchOS does with an AppKit dragging session: the pointer is
/// tracked directly, the grid **reflows live** so a gap follows the cursor, and
/// a folder is only formed by deliberately resting on another app.
final class DragState: ObservableObject {
    @Published private(set) var item: DeckSlot?
    @Published private(set) var proxyApp: AppInfo?
    @Published private(set) var proxyTitle: String?
    @Published var location: CGPoint = .zero
    @Published private(set) var isActive = false
    @Published private(set) var hoverIndex: Int?
    @Published private(set) var hoverPage: Int?

    /// 0 → 1 while a rest-to-merge countdown is running, 0 otherwise.
    ///
    /// Published so the drag proxy overlay can draw the progress ring; the
    /// grid never observes `DragState`, so this costs nothing there. The value
    /// only ticks while a dwell is pending, so an ordinary reorder drag does
    /// not publish any extra frames.
    @Published private(set) var combineProgress: Double = 0

    /// Called when the grid should reflow so the item sits at `index`.
    var onLiveMove: ((DeckSlot, Int) -> Void)?
    /// Called when a hover over a page dot or screen edge has matured.
    var onRequestPage: ((Int) -> Void)?
    /// Called when resting on another app has matured into a folder.
    /// Called when resting on another tile has matured into a combine.
    var onFolderDrop: ((String, CombineTarget) -> Void)?

    /// What a resting drag can combine with.
    enum CombineTarget: Equatable {
        case app(String)
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

    /// Snapshot of the page being dragged over, for the target marker.
    var itemCount = 0
    var capacity = 0

    /// How long the pointer must rest on another app before they combine.
    /// Launchpad requires a deliberate pause; a short one merged by accident.
    private static let folderDwellDelay: TimeInterval = 1.2
    /// Movement beyond this cancels a pending combine.
    private static let dwellSlop: CGFloat = 14
    private static let pageFlipDelay: TimeInterval = 0.5
    /// Distance from the left/right edge that starts a page flip.
    private static let edgeInset: CGFloat = 70

    private var liveIndex = -1
    private var livePage = 0
    private var lastDwellLocation: CGPoint = .zero
    private var flipWork: DispatchWorkItem?
    private var folderWork: DispatchWorkItem?
    private var pendingFolderTarget: CombineTarget?
    /// Drives `combineProgress` while a dwell is pending. Invalidated the moment
    /// the pointer leaves the target or the button is released.
    private var progressTimer: Timer?
    /// When the current dwell clock started; `combineProgress` is derived from
    /// this each tick rather than accumulated, so it can never drift.
    private var dwellStart: Date?

    // MARK: - Lifecycle

    func begin(item: DeckSlot, app: AppInfo?, title: String?, index: Int, page: Int,
               source: Source = .grid, location: CGPoint) {
        guard !isActive else { return }
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

    func reset() {
        flipWork?.cancel(); flipWork = nil
        folderWork?.cancel(); folderWork = nil
        pendingFolderTarget = nil
        endCombineProgress()
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
        if deckSize.width > 0 {
            if location.x <= Self.edgeInset {
                requestPage(page - 1)
            } else if location.x >= deckSize.width - Self.edgeInset {
                requestPage(page + 1)
            } else {
                requestPage(nil)
            }
        }

        if dotsFrame.contains(location) {
            setHoverPage(pageIndex(forDotAt: location), current: page)
            return
        }
        if !dotsFrame.contains(location) { setHoverPage(nil, current: page) }

        guard gridFrame.contains(location) else {
            hoverIndex = nil
            cancelFolderDwell()
            return
        }

        let local = CGPoint(x: location.x - gridFrame.minX, y: location.y - gridFrame.minY)
        let tester = GridHitTester(
            metrics: metrics,
            itemCount: pageItems.count,
            containerSize: gridFrame.size,
            slotCount: capacity
        )
        guard let index = tester.index(at: local) else {
            hoverIndex = nil
            cancelFolderDwell()
            return
        }
        hoverIndex = index

        // Reflow immediately so a gap opens under the pointer. Without this the
        // pointer is always "over another app", so any pause merged them.
        let occupant: DeckSlot? = index < pageItems.count ? pageItems[index] : nil
        let occupantIsSelf = occupant != nil && occupant == item

        // Decide *before* reflowing: after `onLiveMove` the slot holds the
        // dragged item itself.
        switch Self.dwellDecision(item: item, pageItems: pageItems, index: index) {
        case .keep:
            // The live reflow already put the dragged item here, so this is the
            // app it displaced. Let the pending combine keep running.
            break
        case .start(let targetID):
            scheduleFolderDwell(target: targetID, location: location)
        case .cancel:
            cancelFolderDwell()
        }

        if occupantIsSelf { return }

        // Fire on every change of target, including after a page flip: gating
        // on `page == livePage` killed all drop feedback for the rest of the
        // drag once the user crossed a page.
        if index != liveIndex {
            liveIndex = index
            livePage = page
            onLiveMove?(item ?? .app(""), index)
        }
    }

    /// What the drag should do about combining at `index`.
    enum DwellDecision: Equatable {
        /// The dragged item already occupies the slot: leave the pending
        /// combine running.
        case keep
        case start(CombineTarget)
        case cancel
    }

    /// Pure decision used by `update`. Exists as its own function because the
    /// live reflow moves the dragged item *into* the hovered slot, so the naive
    /// "look at what is under the pointer" reading reports the dragged app as
    /// its own combine target — which silently disabled folder creation.
    static func dwellDecision(item: DeckSlot?, pageItems: [DeckSlot], index: Int) -> DwellDecision {
        guard let item else { return .cancel }
        if index >= 0, index < pageItems.count, pageItems[index] == item { return .keep }
        if let target = combineTarget(item: item, pageItems: pageItems, index: index) {
            return .start(target)
        }
        return .cancel
    }

    /// The app a drag should combine with when resting on `index`, if any.
    ///
    /// Bounds-checked on purpose: the hit tester reports trailing *empty* slots
    /// as droppable, so `index` may be past the last item. Pure, so the crash
    /// path is covered by the self-test.
    /// Clamp a requested page into range. Negative indices used to reach
    /// `store.pages[-1]` and trap on the next pointer move.
    static func clampPage(_ page: Int, count: Int) -> Int {
        min(max(page, 0), max(count - 1, 0))
    }

    static func combineTarget(item: DeckSlot?, pageItems: [DeckSlot], index: Int) -> CombineTarget? {
        guard let item, case .app = item else { return nil }
        guard index >= 0, index < pageItems.count else { return nil }
        switch pageItems[index] {
        case .app(let targetID): return .app(targetID)
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

    private func scheduleFolderDwell(target: CombineTarget, location: CGPoint) {
        if pendingFolderTarget != target {
            pendingFolderTarget = target
            folderWork?.cancel()
            folderWork = nil
            lastDwellLocation = location
        } else if hypot(location.x - lastDwellLocation.x, location.y - lastDwellLocation.y) > Self.dwellSlop {
            // Still moving: restart the clock.
            folderWork?.cancel()
            folderWork = nil
            lastDwellLocation = location
        }

        guard folderWork == nil else { return }
        lastDwellLocation = location
        // Start the visible countdown at the exact moment the work item is
        // armed, so the ring reaches 1 when `onFolderDrop` fires.
        beginCombineProgress()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let source = self.item, case .app(let sourceID) = source else { return }
            self.folderWork = nil
            self.stopCombineProgress()
            self.combineProgress = 1
            self.onFolderDrop?(sourceID, target)
        }
        folderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.folderDwellDelay, execute: work)
    }

    // MARK: - Combine countdown

    /// Arms the visible countdown: progress resets to 0 and ticks to 1 over
    /// `folderDwellDelay`. Reused whenever the dwell clock restarts.
    private func beginCombineProgress() {
        dwellStart = Date()
        combineProgress = 0
        progressTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let start = self.dwellStart else { return }
            let elapsed = Date().timeIntervalSince(start)
            self.combineProgress = min(max(elapsed / Self.folderDwellDelay, 0), 1)
        }
        // `.common` so the tick keeps running while the gesture is being
        // tracked (the default mode suspends during scroll/gesture tracking).
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    /// Stops the countdown ticker but keeps the last progress value (used by the
    /// firing path, which immediately sets progress to 1).
    private func stopCombineProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
        dwellStart = nil
    }

    /// Stops the countdown and clears the visible progress.
    private func endCombineProgress() {
        stopCombineProgress()
        if combineProgress != 0 { combineProgress = 0 }
    }

    /// Cancels a pending rest-to-merge and clears its visible progress.
    ///
    /// Called whenever the pointer leaves the target and — crucially — from
    /// `commitDrag` on mouse-up, so a half-finished dwell can never mature into
    /// a combine after the button is already released.
    func cancelFolderDwell() {
        pendingFolderTarget = nil
        folderWork?.cancel()
        folderWork = nil
        endCombineProgress()
    }

    // MARK: - Drop

    enum Drop: Equatable {
        case none
        case toPage(Int)
        case toIndex(Int)
    }

    func drop(metrics: GridMetrics, pageItems: [DeckSlot]) -> Drop {
        guard isActive, let item else { return .none }
        if let page = hoverPage { return .toPage(page) }
        guard let index = hoverIndex else { return .none }
        if index < pageItems.count, pageItems[index] == item { return .none }
        _ = item
        return .toIndex(index)
    }

    private func pageIndex(forDotAt point: CGPoint) -> Int? {
        guard dotsFrame.width > 0, dotCount > 0 else { return nil }
        let relative = (point.x - dotsFrame.minX) / dotsFrame.width
        guard relative >= 0, relative <= 1 else { return nil }
        return min(Int(relative * CGFloat(dotCount)), dotCount - 1)
    }

    /// A repeating `Timer` added to the run loop is **retained by the run loop**,
    /// so an in-flight dwell countdown would otherwise keep firing at 60 Hz
    /// forever after this object is gone (a no-op, since its block captures
    /// `self` weakly) — e.g. when Esc tears the deck down mid-drag, or when the
    /// window is destroyed while a merge countdown is pending. Invalidate it on
    /// deinit so teardown cannot leak a live timer (CPU, not just memory).
    deinit {
        progressTimer?.invalidate()
        flipWork?.cancel()
        folderWork?.cancel()
    }
}
