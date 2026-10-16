import CoreGraphics

/// What the deck window should do with a mouse event.
enum DragRoute: Equatable {
    /// Deliver it normally — SwiftUI still owns clicks, hover and context menus.
    case normal
    /// The deck is driving a drag of its own: swallow the event.
    case consume
    /// Open an AppKit dragging session for `slot`.
    case beginSession(slot: Int)
    /// Feed the new pointer position to the running drag.
    case track
    /// Finish the drag and apply its outcome.
    case commit
    /// The deck refuses to start a drag here: explain why rather than fail quietly.
    case refuse
}

extension DragRoute {
    /// Whether the deck handled the event, so the window must not deliver it.
    ///
    /// The one place the consume/forward question is answered. Asked per call
    /// site instead, it drifts — and the failure is subtle: a `mouseDragged`
    /// left un-consumed slides the deck sideways at the same time as the drag
    /// moves an icon.
    var consumes: Bool {
        switch self {
        case .normal: return false
        case .consume, .beginSession, .track, .commit, .refuse: return true
        }
    }
}

/// The drag-session state machine behind `DeckWindow`.
///
/// ## Why a state machine and not just the window
///
/// LaunchOS keeps its drag in `mouseDragged:`/`mouseUp:` on the deck view. A
/// window that needs a window server, a screen and a genuine button-down cannot
/// be exercised from `--selftest`, so the *decisions* live here as a value type
/// and the window keeps only the plumbing — the same split `DeckClickState`
/// uses for click delivery and `PagingState` uses for scroll following.
///
/// ## The rule it encodes
///
/// A press is only a candidate. Clicks must keep working, and context menus on
/// a tile must keep working, so `mouseDown` is always **passed through** to
/// SwiftUI. The drag claims the event stream at the moment the pointer has
/// moved `DragMotion.dragSlop` points — from then on the deck owns the drag,
/// and the matching `mouseUp` is swallowed too, so a drag can never also fire
/// the tile's `onTapGesture` and launch the app it just moved.
///
/// ## What the evidence says about the session
///
/// LaunchOS starts its `NSDraggingSession` on the **first** dragged event and
/// keeps tracking in `mouseDragged:` afterwards — the branch at `0x10011ded0`
/// (`cmp w22, #0x1` / `b.ne`) sends the first event to the session start
/// (`0x1001000a8`) and every later one down the tracking path. So mouse drag
/// events continue to reach the source view for the whole gesture, which is why
/// `.started` is a terminal phase here rather than a hand-off to AppKit
/// callbacks.
struct DragSessionState: Equatable {

    enum Phase: Equatable {
        case idle
        /// The button is down on a tile but the pointer has not moved far
        /// enough to be a drag yet.
        case pressed(slot: Int, origin: CGPoint)
        /// A dragging session is open for `slot`.
        case dragging(slot: Int)
    }

    private(set) var phase: Phase = .idle

    var isDragging: Bool {
        if case .dragging = phase { return true }
        return false
    }

    /// The slot the open drag belongs to, if any.
    var draggedSlot: Int? {
        if case .dragging(let slot) = phase { return slot }
        return nil
    }

    /// A mouse-down at `point`, resolved to `slot` (`nil` when it missed every tile).
    mutating func mouseDown(slot: Int?, at point: CGPoint) -> DragRoute {
        // A second down while a drag is open means the first session never got
        // its up (a swallowed event, or a deck torn down mid-drag). Starting a
        // fresh `pressed` here would leak the old session — an open session
        // makes every later `save()` a no-op. Stay in the drag and consume.
        guard !isDragging else { return .consume }
        guard let slot else {
            phase = .idle
            return .normal
        }
        phase = .pressed(slot: slot, origin: point)
        return .normal
    }

    /// A mouse-drag to `point`.
    ///
    /// - Parameter allowsDrag: whether the deck permits reordering at all right
    ///   now (`DragState.allowsDrag(sortKey:)`). Checked *before* a session
    ///   opens, because a refused drag must not leave one behind.
    mutating func mouseDragged(to point: CGPoint, allowsDrag: Bool) -> DragRoute {
        switch phase {
        case .idle:
            return .normal
        case .pressed(let slot, let origin):
            guard DragMotion.exceedsSlop(from: origin, to: point) else { return .normal }
            guard allowsDrag else {
                phase = .idle
                return .refuse
            }
            phase = .dragging(slot: slot)
            return .beginSession(slot: slot)
        case .dragging:
            return .track
        }
    }

    /// A mouse-up. Only final when the press had already become a drag.
    mutating func mouseUp() -> DragRoute {
        switch phase {
        case .idle:
            return .normal
        case .pressed:
            // A click, not a drag: let SwiftUI deliver it, so tapping a tile
            // still opens the app.
            phase = .idle
            return .normal
        case .dragging:
            phase = .idle
            return .commit
        }
    }

    /// Drops whatever is in flight, without committing. For teardown (Esc, a
    /// display change) so a half-open drag cannot outlive its deck.
    mutating func reset() { phase = .idle }
}
