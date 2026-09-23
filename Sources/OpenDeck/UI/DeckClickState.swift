import AppKit

/// What `DeckWindow.sendEvent` should do with an event that arrives while the
/// deck is on screen but not key.
enum DeckClickRoute: Equatable {
    /// Nothing special: deliver it and let AppKit do what it does.
    case normal
    /// Deliver it without letting AppKit spend it on activating the app, then
    /// reclaim activation ourselves.
    case deliverThenActivate
    /// Deliver it without activation. The click's own mouse-up has nothing to
    /// activate: the down either already did, or was itself delivered without it.
    case deliverOnly
}

/// The click-delivery rule behind `DeckWindow`.
///
/// A value type so the rule can be asserted in `--selftest`, the same way
/// `PagingState` carries the scroll-follow rules. The window itself cannot be
/// tested headlessly: it needs a window server, a screen and a genuine user
/// click.
///
/// What it encodes. While a window is on screen but *not* key, AppKit treats the
/// next mouse-down as the click that activates the application: the event is
/// spent on bringing the app forward and the window key, and it never reaches the
/// content view. The deck is summoned by a hotkey, a hot corner or a pinch —
/// usually while another app is frontmost — and it stays on screen when the user
/// switches away, so that is exactly the state it is in when the first icon is
/// clicked. The icon never saw the click, and nothing launched.
///
/// No longer claiming to be keyable for the duration of that one click removes
/// the activation duty, and the event goes straight to the hit view — SwiftUI's
/// gesture recogniser included. Activation is reclaimed afterwards, so the search
/// field still ends up in a key window and takes keystrokes.
struct DeckClickState {
    /// True only while such a click is being delivered.
    private(set) var isRouting = false

    /// Withdrawing this is the whole trick: a window that cannot become key has no
    /// activation duty to perform.
    var canBecomeKey: Bool { !isRouting }

    /// How `sendEvent` should handle an event of this type.
    mutating func route(_ type: NSEvent.EventType, isKeyWindow: Bool) -> DeckClickRoute {
        // A key window has no activation duty left. A *re-entrant* call means a
        // delivery is already in progress, and routing it again would only risk
        // giving the permission back while the first click is still in flight.
        guard !isRouting, !isKeyWindow else { return .normal }
        switch type {
        case .leftMouseDown:
            isRouting = true
            return .deliverThenActivate
        case .leftMouseUp:
            isRouting = true
            return .deliverOnly
        default:
            return .normal
        }
    }

    /// The event has been delivered; the deck may be keyable again.
    mutating func finishRouting() {
        isRouting = false
    }
}
