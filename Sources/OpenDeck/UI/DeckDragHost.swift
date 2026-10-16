import AppKit
import SwiftUI

/// A tile the pointer went down on, resolved at press time.
///
/// Carried explicitly rather than re-resolved later: the pointer moves, and the
/// whole point of a press-then-drag is that the *press* decides what is being
/// dragged.
struct DragOrigin: Equatable {
    var item: DeckSlot
    /// Position within its page (or within its folder, for a member).
    var index: Int
    var source: DragState.Source
}

/// Where the expanded folder panel's grid sits, in deck coordinates.
///
/// The panel is pure SwiftUI, so its geometry is measured there and handed over
/// as it lays out. The host needs it only to answer one question — which tile
/// was pressed — so it is a plain value with no behaviour.
struct FolderPanelLayout: Equatable {
    /// The grid's own frame (not the panel's), in deck coordinates.
    var frame: CGRect
    var columns: Int
    var cellWidth: CGFloat
    var cellHeight: CGFloat
    var hSpacing: CGFloat
    var vSpacing: CGFloat
}

/// The deck's drag, driven the way LaunchOS drives its own: a real
/// `NSDraggingSession` for the icon in the air, and the deck's own tracking for
/// everything else.
///
/// ## Why the input layer moved out of SwiftUI
///
/// A SwiftUI `DragGesture` cannot express what the original does:
///
/// • **Slop is 4 points**, not the 8 `DragGesture(minimumDistance:)` offered.
///   Decoded from LaunchOS at `0x10011df38`.
/// • **The press must stay a press.** `DragGesture` competes with the scroll
///   view and the tiles' own tap gestures; the window is the only place that
///   sees an event *before* either of them.
/// • **The session takes the events over.** Measured, not assumed (probe in
///   report 35 §1): once `beginDraggingSession` runs, the source view's
///   `mouseDragged:` stops arriving entirely and the pointer can only be
///   followed through `draggingSession(_:movedTo:)`. A gesture recogniser is
///   simply not in that loop.
///
/// ## The division of labour
///
///   • `NSDraggingSession` — carries the icon. `formation = .none` and
///     `animatesToStartingPositionsOnCancelOrFail = false`, both decoded from
///     LaunchOS. It is *purely visual*: LaunchOS registers zero drag
///     destinations, and so does this (mask 8 is private, exactly as decoded).
///   • `DraggingSessionState` — the press/slop/claim state machine.
///   • `DragState` — the reflow, hover, and the rest-to-combine rule. The pointer
///     moves **these** and nothing else.
///   • `DragOffsetModel` — the page strip, on a `CADisplayLink`. It is moved by
///     a page change and by nothing else: the deck does not slide sideways while
///     an icon is dragged (report 37 §2).
///
/// ## Coordinates
///
/// **There is exactly one coordinate space in this file**: the deck's own —
/// top-left origin, y increasing downwards, the space `DragState.gridFrame`,
/// `DragState.dotsFrame` and every `frame(in: .named("deck"))` in the view live
/// in. Everything that arrives from AppKit (a window point, a screen point) is
/// converted into it on the way in, and nothing else is ever mixed in. See
/// `deckPoint(ofWindowPoint:in:)` for what that means in practice.
@MainActor
final class DeckDragHost: NSObject, NSDraggingSource {

    let drag: DragState
    let offset: DragOffsetModel

    private let store: DeckStore
    private let vm: LaunchpadViewModel

    private var session = DragSessionState()
    /// What the press landed on. Cleared once the session opens.
    private var pendingOrigin: DragOrigin?
    /// True between `beginDraggingSession` and its `endedAt`. Guards the
    /// tracking path, because the session can be torn down from under it (Esc,
    /// a display change).
    private var isLive = false
    private var activeSession: NSDraggingSession?
    private weak var window: NSWindow?

    init(store: DeckStore, vm: LaunchpadViewModel) {
        self.store = store
        self.vm = vm
        self.drag = DragState()
        self.offset = DragOffsetModel()
        super.init()
        wireOutcomes()
    }

    // MARK: - Outcomes

    /// The three things a drag can cause, wired once.
    ///
    /// They used to be closures set by `LaunchpadView.onAppear`, because the
    /// SwiftUI gesture lived there. The host owns the input now, so it owns the
    /// consequences too — and the view is left with nothing but rendering.
    private func wireOutcomes() {
        // Reflow while dragging so a gap follows the pointer — *animated*, not
        // teleported. The icons have to slide out of the way; snapping them was
        // half of why a drag read as "not like LaunchOS".
        drag.onLiveMove = { [weak self] slot, index in
            guard let self, let from = self.store.locate(slot) else { return }
            let page = self.dragPage
            let count = self.store.pages.indices.contains(page) ? self.store.pages[page].count : 0
            withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                self.store.move(itemAt: from,
                                to: IndexPath(item: min(max(index, 0), count), section: page))
            }
        }
        // The edge dwell maturing is the **only** thing that turns a page during
        // a drag. `nudge` re-anchors the strip and lets the display link glide
        // there, so the page turn is the ported approach rather than a jump.
        //
        // Nothing else is done here — in particular `paging` is **not** moved
        // yet. `paging` is the deck's single answer to "which page am I on", and
        // during the glide the honest answer is still the old page: the scroll
        // view has not moved, and the page the strip has left is not one the
        // deck is *on*. The hand-back writes it, a few frames later, in the same
        // transaction as `scrollTo` — which is the only moment the two can be
        // swapped without a frame of disagreement. Moving it early also bought
        // nothing worth having: the glide settles in ~100 ms, and it opened a
        // real hole — an Esc during a page-turning drag would have left the
        // indicator a page ahead of the grid with no test to catch it.
        drag.onRequestPage = { [weak self] page in
            guard let self else { return }
            self.offset.nudge(to: page)
        }
    }

    // MARK: - Window routing

    /// Handle a mouse event on the deck's behalf.
    ///
    /// - Returns: true when the deck consumed the event and the window must not
    ///   deliver it. A **press is never consumed**: claiming it would stop every
    ///   icon from being clicked and every context menu from opening.
    func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        self.window = window
        let point = Self.deckPoint(ofWindowPoint: event.locationInWindow, in: window)

        switch event.type {
        case .leftMouseDown:
            let hit = hitTarget(at: point)
            pendingOrigin = hit
            let route = session.mouseDown(slot: hit?.index, at: point)
            return route.consumes

        case .leftMouseDragged:
            let allows = DragState.allowsDrag(sortKey: store.sortKey)
            switch session.mouseDragged(to: point, allowsDrag: allows) {
            case .normal:
                // Below the slop, or a press that missed every tile. Still a
                // press: let AppKit deliver it.
                return false
            case .refuse:
                if pendingOrigin != nil { drag.refuseBegin(DragState.reorderLockedMessage) }
                pendingOrigin = nil
                return true
            case .beginSession:
                beginSession(event: event, in: window, at: point)
                return true
            default:
                // `.track` and `.commit` cannot arrive here: once the session is
                // open, AppKit routes the dragged events to
                // `draggingSession(_:movedTo:)` instead of to this method.
                return true
            }

        case .leftMouseUp:
            let route = session.mouseUp()
            if route == .commit { commit() }
            pendingOrigin = nil
            return route.consumes

        default:
            return false
        }
    }

    /// Drops everything in flight without committing. For teardown (Esc, the
    /// deck closing, a display change).
    func teardown() {
        isLive = false
        activeSession = nil
        pendingOrigin = nil
        session.reset()
        // The store's session has to be closed or every later `save()` is a
        // no-op. `endDragSession` is idempotent.
        store.endDragSession()
        store.setDropHoverFolder(nil)
        store.setDropHoverApp(nil)
        drag.reset()
        offset.cancel()
    }

    // MARK: - The session

    private func beginSession(event: NSEvent, in window: NSWindow, at point: CGPoint) {
        guard let origin = pendingOrigin, let view = window.contentView else {
            self.session.reset()
            return
        }
        pendingOrigin = nil

        // The user is driving, so a jump that has not landed loses its claim on
        // the next report: their hand outranks an animation in flight.
        vm.jumpGuard.disarm()

        // Open a drag session on the store: defer page reclamation and hold
        // writes until the drag lands (§8.2/§8.4).
        store.beginDragSession()

        // The strip starts from wherever the scroll view happens to be, so this
        // first frame cannot move the deck even a pixel — however the scroll
        // view is sitting, mid-glide or exactly on a page. It then stays there
        // unless a page change is asked for.
        drag.deckSize = window.frame.size
        offset.begin(scrollOffset: Double(drag.scrollOffset),
                     pageWidth: Double(drag.gridFrame.width),
                     pageCount: vm.pageCount)

        let app: AppInfo? = {
            if case .app(let id) = origin.item { return store.app(id: id) }
            return nil
        }()
        let title: String? = {
            if case .folder(let id) = origin.item { return store.folder(id)?.name }
            return app?.name
        }()
        drag.begin(item: origin.item, app: app, title: title, index: origin.index,
                   page: dragPage, source: origin.source, location: point)
        isLive = true

        // The icon is framed in the **view's** own coordinates, around where the
        // pointer is in them — see `iconFrame(pointerInView:size:)` for why that
        // is the only space that works here.
        let pointerInView = view.convert(event.locationInWindow, from: nil)
        let item = draggingItem(for: origin.item, at: pointerInView)
        let session = view.beginDraggingSession(with: [item], event: event, source: self)
        // Both decoded from LaunchOS: the icons do not arrange themselves into a
        // formation, and a cancelled drag does not fly back to where it started.
        session.draggingFormation = .none
        session.animatesToStartingPositionsOnCancelOrFail = false
        activeSession = session
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // 8 is what LaunchOS answers with — an operation no destination in the
        // system claims, which is the point: the session exists to carry the
        // icon, not to negotiate a drop.
        NSDragOperation(rawValue: 8)
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard isLive, let window else { return }
        let point = Self.deckPoint(ofWindowPoint: window.convertPoint(fromScreen: screenPoint),
                                   in: window)
        // **The pointer does not move the strip.** It moves the reflow and
        // nothing else: the grid stays where it is, the icons slide out of the
        // way, and a page turns only when the edge dwell matures (see
        // `onRequestPage`). Feeding the pointer's travel to `DragOffsetModel` is
        // what made the whole deck slide sideways during a drag — and, because
        // the strip then gave that travel straight back, it also pinned the
        // pointer over the cell it had started on, so an in-page drag could not
        // reorder anything at all (report 37 §2).
        let page = dragPage
        let items = store.pages.indices.contains(page) ? store.pages[page] : []
        drag.update(location: point, page: page, metrics: store.metrics,
                    pageItems: items, capacity: store.metrics.capacity)
        // Mirror the drop-hover signals into the store, diffed: the pointer
        // fires dozens of these per second and only a boundary crossing may
        // re-render the grid. Every exit path clears both (commit / endedAt /
        // teardown).
        if store.dropHoverFolderID != drag.combineFolderID {
            store.setDropHoverFolder(drag.combineFolderID)
        }
        if store.dropHoverAppID != drag.combineAppID {
            store.setDropHoverApp(drag.combineAppID)
        }
        // Report 46 — the pull-out: leaving the expanded panel mid-drag
        // collapses the folder and turns the rest of the drag into an ordinary
        // grid drag. Checked after `update`, so the hover state the exit
        // decision needs is already fresh for this very point.
        pullOutIfExited(at: point)
    }

    /// The pull-out (report 46). While a **member** drag is live and the
    /// pointer leaves the expanded panel's visible bounds, the member joins the
    /// grid right now, the panel collapses (`folderMinimizing` — a light
    /// teardown that leaves the store's drag session alone), and the drag is
    /// promoted to an ordinary grid drag: the reflow's gap follows the pointer
    /// for the rest of the flight, and the release can even fold into another
    /// tile. Internal so `--selftest` can drive it, same as `commit()`.
    ///
    /// A release **inside** the panel keeps the old contract — the commit moves
    /// the member out at the hovered grid position and closes the folder there.
    func pullOutIfExited(at point: CGPoint) {
        guard drag.sourceFolder != nil,
              let fid = vm.openedFolder,
              !vm.folderClosing, !vm.folderMinimizing,
              let panel = vm.folderPanel else { return }
        guard DragState.exitedPanel(pointer: point, panelFrame: panel.frame,
                                    padding: FolderOverlayView.panelPadding) else { return }
        guard case .app(let appID) = drag.item else { return }
        // Land where the pointer is: the hovered grid cell, or the page tail
        // when the exit happened off the grid. From here the live reflow takes
        // over — the very next `movedTo` that changes the index slides the gap.
        let count = store.pages.indices.contains(dragPage) ? store.pages[dragPage].count : 0
        let index = drag.hoverIndex.map { min(max($0, 0), count) } ?? count
        withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
            if store.moveOutOfFolder(appID, folder: fid, toPage: dragPage, index: index) {
                vm.folderMinimizing = true
                drag.promoteToGrid()
            }
        }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        activeSession = nil
        guard isLive else {
            // Torn down mid-drag (or already merged): nothing left to commit,
            // but the store's session still has to be closed.
            self.session.reset()
            store.setDropHoverFolder(nil)
            store.setDropHoverApp(nil)
            store.endDragSession()
            offset.cancel()
            return
        }
        isLive = false
        self.session.reset()
        // Aim the strip at the page it should land on. The grid is *not* jumped
        // here: the motion glides there first and only then publishes
        // `landing`, which is what turns the hand-back into a single frame
        // instead of a visible snap.
        offset.release()
        commit()
    }

    // MARK: - Commit

    /// Resolve what the drag should do and apply it in one step.
    ///
    /// Internal rather than private so `--selftest` can drive it — the same
    /// reason `dragPage` and `deckPoint(ofWindowPoint:in:)` are. The alternative
    /// was to reach it through `handle(_:in:)`, which needs a real button-down, a
    /// live `NSDraggingSession` and a nested event loop; what actually goes wrong
    /// here is which action the drop resolves to and what the store is asked to
    /// do, and both are reachable without any of that. (A release-time merge that
    /// silently did nothing survived the whole mutation suite until this was
    /// opened up — the decision was asserted and the *effect* was not.)
    func commit() {
        // The drop-hover zoom dies with the release, whatever it resolves to.
        store.setDropHoverApp(nil)
        store.setDropHoverFolder(nil)
        // Read the page through the single derived point (§2.2): never a stored,
        // possibly-stale index — and through `dragPage`, because after an edge
        // dwell the strip is a page ahead of the scroll view and the drop belongs
        // to the page the user is looking at, not the one the scroll view is
        // still on.
        let page = dragPage
        let items = store.pages.indices.contains(page) ? store.pages[page] : []
        let action = drag.drop(metrics: store.metrics, pageItems: items)
        let dragged = drag.item
        // Both captured *before* `reset()` (which clears `source`→`.grid` and
        // `item`→nil): the explicit source lets the commit dispatch on where the
        // drag came from instead of re-resolving it with `store.locate(...)`,
        // which returns nil for a folder member.
        let source = drag.source
        drag.reset()
        // One write for the whole drag. `endDragSession` reclaims the empty pages
        // deferred during the drag (Q1/§8.2) and then flushes exactly once.
        defer { store.endDragSession() }

        guard let slot = dragged else { return }
        switch action {
        case .none:
            break
        case .combine(let target):
            // **The fold happens here, on the release, and nowhere else.** An
            // app joins a folder — or folds with another app into a new one —
            // when the button comes up on the tile. There is no rest-to-combine
            // timer: LaunchOS never turns a hover into an action on its own
            // (`draggingSession:movedToPoint:` is a bare `ret`); the merge is
            // the release's decision, armed on the tile (report 45).
            guard case .app(let appID) = slot else { break }
            switch target {
            case .app(let targetID):
                // The report-45 rule: releasing on an app tile folds the two
                // into a new folder.
                store.makeFolder(dropping: appID, onto: targetID)
            case .folder(let folderID):
                store.addToFolder(appID, folder: folderID)
            }
        case .toPage(let target):
            // There is no grid cell under a page dot, so the item lands at the
            // end of the target page — matching Launchpad's dot-drop behaviour.
            let targetPage = DragState.clampPage(target, count: store.pages.count)
            switch (source, slot) {
            case (.folderMember(let fid), .app(let appID)):
                let tail = store.pages.indices.contains(targetPage) ? store.pages[targetPage].count : 0
                if store.moveOutOfFolder(appID, folder: fid, toPage: targetPage, index: tail) {
                    // §8.3/L5: pulling a member out leaves that folder's view.
                    vm.folderClosing = true
                }
            default:
                store.moveItem(slot, toPage: targetPage)
            }
        case .toIndex(let index):
            switch (source, slot) {
            case (.folderMember(let fid), .app(let appID)):
                // Q3: the drop lands on the cell the pointer released over
                // (`hoverIndex`, carried by `drop()`), never `liveIndex` — a
                // folder member does not reflow, so only `hoverIndex` is valid.
                if store.moveOutOfFolder(appID, folder: fid, toPage: page, index: index) {
                    vm.folderClosing = true
                }
            case (.grid, _):
                guard let from = store.locate(slot) else { break }
                let limit = store.pages.indices.contains(page) ? store.pages[page].count : 0
                store.move(itemAt: from, to: IndexPath(item: min(max(index, 0), limit), section: page))
            default:
                break
            }
        }
    }

    // MARK: - Which page this drag is about

    private func resolvedPage() -> Int {
        vm.paging.resolved(count: store.pages.count)
    }

    /// The page the drag is working on, which is **not** always the page the
    /// scroll view has reached.
    ///
    /// After an edge dwell the strip has already glided to the next page while
    /// the scroll view stays where it was until the hand-back — that two-phase
    /// hand-over is the whole point of the landing. Everything that asks "which
    /// page is this drag about" — the reflow's item list, the drop's section —
    /// has to mean the page the user is *looking at*, so it reads the strip's
    /// anchor. Asking `paging` instead put a dropped item onto the page the user
    /// had just left: the drop looked right and landed a page away.
    ///
    /// Internal so `--selftest` can drive it: it needs a live strip, which is the
    /// part a plain number cannot express.
    var dragPage: Int { offset.isActive ? offset.anchorPage : resolvedPage() }

    // MARK: - Hit testing

    /// The tile under `point` (deck coordinates), or nil for empty space.
    ///
    /// Internal rather than private so `--selftest` can drive it: it is the one
    /// part of the drag with no pure-function twin, and it decides what a press
    /// grabs — including the rule that an open folder panel shadows the grid
    /// behind it.
    func hitTarget(at point: CGPoint) -> DragOrigin? {
        if vm.openedFolder != nil { return folderTarget(at: point) }
        return gridTarget(at: point)
    }

    private func gridTarget(at point: CGPoint) -> DragOrigin? {
        guard drag.gridFrame.width > 0 else { return nil }
        let page = resolvedPage()
        let items = store.pages.indices.contains(page) ? store.pages[page] : []
        let local = CGPoint(x: point.x - drag.gridFrame.minX,
                            y: point.y - drag.gridFrame.minY)
        let tester = GridHitTester(metrics: store.metrics, itemCount: items.count,
                                   containerSize: drag.gridFrame.size,
                                   slotCount: store.metrics.capacity)
        guard let index = tester.index(at: local), index < items.count else { return nil }
        return DragOrigin(item: items[index], index: index, source: .grid)
    }

    /// A tile inside the expanded folder panel.
    ///
    /// The panel is SwiftUI and its geometry lives in the view, so the view
    /// registers it (`LaunchpadViewModel.folderPanel`) as it lays out. Only an
    /// app can be dragged out of a folder.
    private func folderTarget(at point: CGPoint) -> DragOrigin? {
        guard let fid = vm.openedFolder, let panel = vm.folderPanel else { return nil }
        let local = CGPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY)
        guard local.x >= 0, local.y >= 0 else { return nil }
        let columnStride = panel.cellWidth + panel.hSpacing
        let rowStride = panel.cellHeight + panel.vSpacing
        guard columnStride > 0, rowStride > 0 else { return nil }
        let column = Int(local.x / columnStride)
        let row = Int(local.y / rowStride)
        guard column >= 0, column < panel.columns else { return nil }
        let index = row * panel.columns + column
        let apps = store.folderApps(fid)
        guard index >= 0, index < apps.count else { return nil }
        return DragOrigin(item: .app(apps[index].id), index: index, source: .folderMember(fid))
    }

    // MARK: - The icon in the air

    private func draggingItem(for slot: DeckSlot, at pointerInView: CGPoint) -> NSDraggingItem {
        let size = store.metrics.iconSize
        let pasteboard = NSPasteboardItem()
        // Private type, never registered by anyone — decoded from LaunchOS, whose
        // session has no destination either. The session is a carrier, not a
        // negotiation.
        pasteboard.setString(slot.id, forType: NSPasteboard.PasteboardType("local.opendeck.drag"))
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        item.setDraggingFrame(Self.iconFrame(pointerInView: pointerInView, size: size),
                              contents: DragImageFactory.image(for: slot, store: store, size: size))
        return item
    }

    // MARK: - Coordinates

    /// Deck coordinates from a point in the window's.
    ///
    /// Deck coordinates have their origin at the top-left of the hosting view and
    /// y increasing downwards — exactly the space `.global` and
    /// `frame(in: .named("deck"))` report in, and therefore exactly the space
    /// `DragState.gridFrame` and `DragState.dotsFrame` live in.
    ///
    /// ## The one thing that must not be done here
    ///
    /// `NSHostingView` is **flipped**. That is measured, not assumed — report 36
    /// §1 prints `isFlipped == true` for a hosting view built exactly the way
    /// `LaunchpadWindowController` builds one, and shows that a window point 55
    /// up from the bottom edge converts to y = 345 in a 400-point-tall view,
    /// which is 55 down from the top. So `convert(_:from: nil)` **already**
    /// returns a top-left-origin point; subtracting it from `bounds.height` to
    /// "flip it" flips it a second time and mirrors every hit test in the drag
    /// about the middle of the deck — press the top row, lift the bottom row's
    /// icon. That was the bug, and this whole method exists to be the single
    /// place the conversion happens.
    static func deckPoint(ofWindowPoint point: NSPoint, in window: NSWindow) -> CGPoint {
        guard let view = window.contentView else { return .zero }
        let local = view.convert(point, from: nil)
        return CGPoint(x: local.x, y: local.y)
    }

    /// The dragging item's frame, in the **view's** coordinate system.
    ///
    /// Not a preference: `beginDraggingSession(with:event:source:)` documents that
    /// "the frame property of each `NSDraggingItem` must be in the view's
    /// coordinate system", and that the event's "mouse location is used for the
    /// offset of the icon being dragged". The previous cut passed
    /// `NSEvent.mouseLocation` — a *screen* point, bottom-left origin — so the
    /// icon's offset from the pointer was computed in a space the view knows
    /// nothing about; AppKit silently rewrote the frame as the session opened.
    static func iconFrame(pointerInView: CGPoint, size: CGFloat) -> NSRect {
        NSRect(x: pointerInView.x - size / 2, y: pointerInView.y - size / 2,
               width: size, height: size)
    }
}

/// Builds the image the dragging session carries.
///
/// A folder's is drawn the way its tile is: up to nine mini icons on a frosted
/// plate. AppKit composites this one, so the icon in the air costs the main
/// thread nothing per frame — which is most of why the original feels smoother
/// than a SwiftUI view chasing the pointer.
///
/// ## Why even a plain app icon is **drawn**, not handed over as-is
///
/// The obvious thing is to pass `store.app(id:)?.icon` straight to
/// `setDraggingFrame(_:contents:)`. It is measured wrong, and it is why the icon
/// in the air looked soft while the same icon in the grid looked crisp.
///
/// `NSWorkspace.icon(forFile:)` is a **1024-point** image (its largest rep is
/// 2048 px at scale 2 — see the probe below). AppKit does not scale that down to
/// the dragging frame we ask for: it derives the dragging component at its own
/// legacy size and leaves *that* to be stretched into the frame. Measured with
/// `NSDraggingItem.imageComponents`, for a 64×64 frame:
///
/// ```
/// contents: the NSWorkspace icon   -> component image = 32 pt / 32 px
/// contents: an image of size 64    -> component image = 64 pt / 128 px
/// ```
///
/// 32 px stretched into 64 points is 2× on any display and 4× on a Retina one —
/// exactly the 虚化 that was reported. The component must be **1:1 with the
/// frame at the screen's own pixel scale**, which is what drawing the icon into
/// an `NSImage(size: side)` does: `lockFocus` picks the screen's scale (measured:
/// a `NSCGImageSnapshotRep` at 128 px for 64 pt on a 2× display), so nothing
/// downstream has anything to rescale.
///
/// A folder's image was already built that way, which is why only app icons were
/// soft. One rule for both now: **the image's logical size is the frame's.**
///
/// Probe: `/tmp/probe-dragsession/main8.swift`; report 38 §1 (archived in
/// `docs/review/archive-2026-10-15.zip`; summary in `docs/review/DECISIONS.md`) —
/// not in the repo: the probe.
@MainActor
enum DragImageFactory {
    static func image(for slot: DeckSlot, store: DeckStore, size: CGFloat) -> NSImage {
        switch slot {
        case .app(let id):
            guard let icon = store.app(id: id)?.icon else { return blank(size: size) }
            return plate(size: size) { icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size)) }
        case .folder(let fid):
            return folder(members: store.folderApps(fid).map(\.icon), size: size)
        }
    }

    /// An image whose logical size is `size` — see the note above for why that is
    /// the whole point, and why the pixel scale is left to `lockFocus`.
    private static func plate(size: CGFloat, draw: () -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }
        draw()
        return image
    }

    private static func blank(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size))
    }

    private static func folder(members: [NSImage], size: CGFloat) -> NSImage {
        plate(size: size) {
            let plate = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                                     xRadius: size * 0.22, yRadius: size * 0.22)
            NSColor(white: 0.55, alpha: 0.55).setFill()
            plate.fill()
            NSColor(white: 1, alpha: 0.18).setStroke()
            plate.lineWidth = 1
            plate.stroke()

            let shown = Array(members.prefix(9))
            guard !shown.isEmpty else { return }
            let columns = shown.count <= 4 ? 2 : 3
            let spacing: CGFloat = 6
            let inset: CGFloat = 9
            let mini = (size - inset * 2 - CGFloat(columns - 1) * spacing) / CGFloat(columns)
            for (index, icon) in shown.enumerated() {
                let column = index % columns
                let row = index / columns
                let x = inset + CGFloat(column) * (mini + spacing)
                // The plate's origin is bottom-left in this drawing space, and so is
                // the grid's first row.
                let y = size - inset - CGFloat(row + 1) * mini - CGFloat(row) * spacing
                icon.draw(in: NSRect(x: x, y: y, width: mini, height: mini))
            }
        }
    }
}
