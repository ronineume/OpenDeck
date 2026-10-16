import AppKit

/// One screen, reduced to what the deck's placement decision actually reads.
///
/// `NSScreen` has no public initialiser, so a decision written against it can
/// only ever be exercised on the screens the machine happens to have. This value
/// type is trivially buildable, which is what lets all four placement policies
/// be driven from `--selftest` (see `ScreenPicker`).
struct ScreenInfo: Equatable {
    /// Stable identity: the display number AppKit reports for this screen.
    let id: String
    let frame: CGRect
    let visibleFrame: CGRect

    /// Whether this screen carries the menu bar.
    ///
    /// The menu bar is the only thing that insets a screen from the **top**, so
    /// a top inset identifies it without having to guess which display is the
    /// primary one — a guess AppKit does not document an answer for. On a Mac
    /// with "Displays have separate Spaces" every screen carries its own menu
    /// bar, which is why the picker takes the first screen that reports one.
    var carriesMenuBar: Bool {
        frame.maxY - visibleFrame.maxY > 1
    }
}

extension ScreenInfo {
    /// The one place a real `NSScreen` becomes a decision input.
    init(_ screen: NSScreen) {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber)?.uint32Value ?? 0
        self.init(id: String(number), frame: screen.frame, visibleFrame: screen.visibleFrame)
    }
}

/// Where the deck opens when it is summoned.
enum ScreenPolicy: String, CaseIterable, Identifiable {
    /// Wherever the pointer is. The long-standing behaviour, and the default.
    case pointer
    /// The screen with the menu bar.
    case main
    /// The screen holding the frontmost app.
    case active
    /// The screen the Dock is parked on.
    case dock

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pointer: return "Screen with the pointer"
        case .main: return "Main screen"
        case .active: return "Screen with the active app"
        case .dock: return "Screen with the Dock"
        }
    }
}

/// Turns a `ScreenPolicy` into an index into a list of screens.
///
/// Pure, and deliberately so: the decision is the part worth testing, and the
/// four policies have to stay reachable on a machine with one display. Every
/// fallback lands on the menu-bar screen, which is where AppKit's own
/// `NSScreen.main` lands when there is no key window.
enum ScreenPicker {
    static func targetIndex(policy: ScreenPolicy,
                            screens: [ScreenInfo],
                            pointer: CGPoint,
                            activeScreenID: String?) -> Int {
        guard !screens.isEmpty else { return 0 }
        let fallback = menuBarIndex(screens)
        switch policy {
        case .pointer:
            return screens.firstIndex { $0.frame.contains(pointer) } ?? fallback
        case .main:
            return fallback
        case .active:
            if let activeScreenID,
               let hit = screens.firstIndex(where: { $0.id == activeScreenID }) {
                return hit
            }
            return fallback
        case .dock:
            return dockIndex(screens) ?? fallback
        }
    }

    /// The screen with the menu bar, falling back to the first screen — the best
    /// available answer when nothing reports a menu bar at all.
    static func menuBarIndex(_ screens: [ScreenInfo]) -> Int {
        screens.firstIndex { $0.carriesMenuBar } ?? 0
    }

    /// The screen the Dock reserves space on, or `nil` when none does.
    ///
    /// `NSScreen` never says where the Dock is, but the Dock says it for us: a
    /// Dock that is not hidden is carved out of its own screen's `visibleFrame`,
    /// so the Dock screen is the one inset on a left, right or bottom edge. The
    /// top edge is the menu bar and is therefore never considered — a screen
    /// with only a menu bar is not a Dock screen.
    ///
    /// With the Dock hidden (`autohide`) nothing qualifies, and `nil` sends the
    /// caller to the menu-bar screen: that is where a hidden Dock lives unless
    /// the user has moved it, and claiming to know better would be a guess.
    static func dockIndex(_ screens: [ScreenInfo]) -> Int? {
        /// True when `outer` exceeds `inner` by more than a rounding error. The
        /// two attributes are passed in the order that makes the call read as
        /// "this edge is reserved".
        func reserved(_ outer: CGFloat, _ inner: CGFloat) -> Bool { outer - inner > 1 }
        return screens.firstIndex { s in
            reserved(s.visibleFrame.minX, s.frame.minX)        // Dock on the left
                || reserved(s.frame.maxX, s.visibleFrame.maxX) // Dock on the right
                || reserved(s.visibleFrame.minY, s.frame.minY) // Dock at the bottom
        }
    }
}
