import Foundation
import AppKit
import QuartzCore

/// The low-frequency half of the strip's model: which page the strip has
/// finished gliding onto, or nil while it is still moving.
///
/// ## Why this is not `@Published` on `DragOffsetModel`
///
/// The two values this model publishes are watched at completely different
/// rates, by different views. `applied` changes **every frame** and is watched by
/// `DragStripLayer` alone — observing it in `PagesScroller` would re-evaluate the
/// page grids 175 cells at a time, per frame. `landing` changes **twice per
/// drag** and is watched by the grid, because moving the scroll view to catch the
/// strip is something only the grid can do.
///
/// Putting both on one object made the grid unable to see the landing at all:
/// `PagesScroller` holds `DragOffsetModel` as a plain `let` (deliberately — see
/// above), and SwiftUI's `onChange` only fires when the *view* is re-evaluated.
/// A `@Published` on an object a view does not observe never re-evaluates it, so
/// the landing was published into the void. The deck was then left exactly where
/// the drag had pushed it, with the scroll view still on the old page.
final class DragLandingSignal: ObservableObject {
    /// The page to hand the scroll view over to, or nil.
    @Published var page: Int?
}

/// Where the page strip is drawn while a drag is in flight, and where it is
/// heading.
///
/// ## What moves it, and what does not
///
/// **Only a page change moves the strip.** Dragging an icon sideways leaves the
/// grid exactly where it is: the icons reflow around the pointer, the pointer
/// keeps moving across the same static cells, and the page turns only when the
/// pointer parks against the screen's left or right edge. That is what Launchpad
/// does, and it is what the pointer-following cut of this got wrong — see report
/// 37 §2. The pointer-following shape is recoverable
/// (`0x10011df70`: `targetOffsetX = helper(dx)`), but feeding it in means the
/// strip gives back the pointer's whole travel, so the pointer never leaves the
/// cell it started on and reordering inside a page becomes a no-op.
///
/// ## Why it is input-agnostic
///
/// A SwiftUI `DragGesture` and an AppKit `NSDraggingSession` both reduce to the
/// same two facts — *the pointer has travelled N points* and *the button came
/// up* — so one object serves either. That also keeps every rule here reachable
/// from `--selftest`, which a live event loop is not.
///
/// ## The two offsets
///
/// `presented` is absolute, in the same coordinates as the scroll view's own
/// content offset: resting on page `p` is `-p · pageWidth`. But the strip is
/// drawn *inside* the scroll view — which already translates its content — so
/// what SwiftUI applies is `applied = presented + scrollOffset`. The two cancel
/// exactly, which is what makes a deck with no drag in flight pixel-identical to
/// one that never had this feature.
///
/// ## The ramp
///
/// The glide itself is `DragMotion.step` — LaunchOS's display-link interpolation,
/// ported constant by constant. A page change is therefore *approached* frame by
/// frame rather than jumped, at whatever rate the display actually runs.
@MainActor
final class DragOffsetModel: ObservableObject {

    /// What SwiftUI applies as `.offset(x:)`. Zero whenever no drag is in
    /// flight.
    @Published private(set) var applied: Double = 0

    /// The landing page, published on its own object — the grid observes that
    /// one. Read through `landing` here; see `DragLandingSignal` for why a single
    /// object could not serve both.
    let landingSignal = DragLandingSignal()

    /// The page the strip has finished gliding onto, or nil.
    ///
    /// Handed back rather than acted on here because the hand-back is SwiftUI's
    /// job: the scroll view has to be moved to `page` and `applied` has to return
    /// to zero **in one transaction**, and only the grid can do both. Two
    /// separate updates would show the deck a page off for one frame.
    var landing: Int? { landingSignal.page }

    /// Absolute presented offset — see the type comment.
    private(set) var presented: Double = 0
    /// Where `presented` is heading.
    private(set) var goal: Double = 0
    /// The page the strip is anchored to: the page the deck is showing, which is
    /// **not** always the page the scroll view has reached. After an edge dwell
    /// the strip has glided on while the scroll view waits for the hand-back, so
    /// this is the page the user is looking at — and the one a drop belongs to.
    private(set) var anchorPage = 0
    private(set) var pageWidth: Double = 0
    private(set) var pageCount = 1

    /// The scroll view's own content offset when the drag began.
    ///
    /// Frozen for the duration, and that is not an approximation: a mouse drag
    /// cannot scroll a scroll view on macOS, and wheel events cannot arrive while
    /// a button is held.
    private var scrollOffset: Double = 0
    /// Set by `release()`; consumed by the tick that converges.
    private var landingTarget: Int?

    private var link: CADisplayLink?
    /// `CADisplayLink` retains its target, so the link must not point at this
    /// object — see `DragLinkTarget`.
    private let linkTarget = DragLinkTarget()

    var isActive: Bool { pageWidth > 0 }

    init() { linkTarget.model = self }

    // MARK: - Lifecycle

    /// Begins a drag from the strip's current position.
    ///
    /// - Parameter scrollOffset: the scroll view's content offset right now. The
    ///   presented offset is initialised to cancel it, so this frame cannot move
    ///   the strip by even a pixel no matter how the scroll view happens to be
    ///   sitting (mid-glide, mid-bounce, or exactly on a page) — and so the strip
    ///   stays where the user found it for the whole drag unless a page change is
    ///   asked for.
    func begin(scrollOffset: Double, pageWidth: Double, pageCount: Int) {
        stopLink()
        self.scrollOffset = scrollOffset
        self.pageWidth = max(pageWidth, 1)
        self.pageCount = max(pageCount, 1)
        self.presented = -scrollOffset
        self.goal = -scrollOffset
        self.landingTarget = nil
        self.anchorPage = DragMotion.settledPage(offset: presented,
                                                 pageWidth: self.pageWidth,
                                                 pageCount: self.pageCount)
        landingSignal.page = nil
        publish()
        startLink()
    }

    /// Re-anchors the strip onto `page`, keeping the drag alive.
    ///
    /// This is how a drag crosses pages. The deck window arms its edge dwell, and
    /// when it matures the *anchor* moves and the display link glides the strip
    /// there — one mechanism, ported, so the page turn is an approach rather than
    /// a jump.
    ///
    /// ⚠️ **The target page is OpenDeck's own rule.** Which page an edge dwell
    /// should reach, how long it must rest first, and whether it should be
    /// clamped rather than refused are not recoverable from the binary (report
    /// 33 §7; the dwell is 0.5 s and entirely ours).
    func nudge(to page: Int) {
        guard isActive else { return }
        let clamped = min(max(page, 0), pageCount - 1)
        guard clamped != anchorPage else { return }
        anchorPage = clamped
        goal = DragMotion.restingGoal(page: clamped, pageWidth: pageWidth)
    }

    /// Ends the drag: aims the strip at the page it should land on and returns
    /// that page.
    ///
    /// The motion keeps running afterwards, so the strip *slides* onto the page
    /// rather than snapping — and only once it has arrived does `landing` appear.
    ///
    /// The landing page is the **anchor** — the page the drag is on — and not the
    /// page the strip happens to be nearest to. Those are the same value except
    /// mid-glide, which is exactly the case that matters: if the button comes up
    /// while an edge-dwell page turn is still sliding, "nearest" names the page
    /// the drag has already left. The drop is placed on the anchor
    /// (`DeckDragHost.commit` reads the same value), so handing the scroll view a
    /// different page would land the item off-screen.
    @discardableResult
    func release() -> Int {
        guard isActive else { return anchorPage }
        goal = DragMotion.restingGoal(page: anchorPage, pageWidth: pageWidth)
        landingTarget = anchorPage
        return anchorPage
    }

    /// Finishes the hand-back.
    ///
    /// The grid calls this in the **same transaction** as the scroll jump, so the
    /// two offsets swap over within a single frame. Doing them apart would show
    /// the deck a page off for one frame — the "闪一帧" this whole design exists
    /// to avoid.
    func completeLanding() {
        reset()
    }

    /// Drops the drag without landing it. For teardown (Esc, a display change,
    /// the deck closing) so a half-finished motion cannot outlive its deck.
    func cancel() {
        reset()
    }

    // MARK: - The motion itself

    /// The display link callback.
    @objc func step(_ link: CADisplayLink) {
        tick(frameDuration: link.targetTimestamp - link.timestamp)
    }

    /// One frame of the motion.
    ///
    /// Separated from the link so `--selftest` can drive it with an arbitrary
    /// frame duration — which is exactly the parameter the ported ramp is
    /// normalised by, so the tests can pin 60 Hz and 120 Hz behaviour that a
    /// machine with one display could never exercise.
    func tick(frameDuration: Double) {
        guard isActive else { return }
        let step = DragMotion.step(value: presented, goal: goal, frameDuration: frameDuration)
        presented = step.value
        publish()
        // Settling is normal — the strip is at its goal and has nothing to do —
        // and means nothing until the button is up.
        if step.settled, let target = landingTarget {
            landingTarget = nil
            stopLink()
            landingSignal.page = target
        }
    }

    // MARK: - Plumbing

    private func publish() {
        applied = presented + scrollOffset
    }

    private func reset() {
        landingTarget = nil
        stopLink()
        presented = 0
        goal = 0
        anchorPage = 0
        scrollOffset = 0
        pageWidth = 0
        pageCount = 1
        landingSignal.page = nil
        applied = 0
    }

    private func startLink() {
        // A display link needs a window server. The development modes have one on
        // this machine, but a headless run must never start a clock it cannot
        // stop, and the tests drive `tick` directly anyway.
        guard link == nil, !AppEnvironment.isHeadless else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let link = screen.displayLink(target: linkTarget, selector: #selector(DragLinkTarget.step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    deinit {
        // The link retains its target, so a live link would otherwise keep
        // ticking forever after this object is gone.
        link?.invalidate()
    }
}

/// Breaks the retain cycle `CADisplayLink` would otherwise create.
///
/// A display link retains its target. A link whose target is the model would
/// therefore keep the model alive for as long as it ticks — and since the link is
/// only ever invalidated *by* the model, neither would ever go away, so a deck
/// that was opened and closed would leave a 120 Hz clock running for the life of
/// the process. The link retains this proxy instead, and the proxy holds the
/// model weakly.
///
/// `@MainActor` because the link is added to the main run loop: the callback is
/// on the main thread by construction, and saying so lets it call straight into
/// the model instead of hopping through a queue that would add a frame of delay
/// to every step of the motion.
@MainActor
private final class DragLinkTarget: NSObject {
    weak var model: DragOffsetModel?
    @objc func step(_ link: CADisplayLink) { model?.step(link) }
}
