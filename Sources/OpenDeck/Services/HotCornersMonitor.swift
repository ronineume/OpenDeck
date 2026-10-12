import AppKit

/// A screen corner that opens the deck, mirroring LaunchOS's `HotCornersMonitor`.
enum HotCorner: String, CaseIterable, Identifiable {
    case off
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }

    /// Which corner of a screen frame this refers to.
    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isEnabled: Bool { self != .off }
}

/// Fires when the pointer is pushed into a chosen screen corner.
///
/// Implemented with a global mouse-moved monitor. Mouse events, unlike key
/// events, do not require Accessibility permission, so this works out of the box.
final class HotCornersMonitor {
    static let shared = HotCornersMonitor()

    /// How close to the corner counts as "in" it.
    private static let margin: CGFloat = 4
    /// Ignore repeats until the pointer leaves and comes back.
    private static let rearmDelay: TimeInterval = 1.0

    private var monitor: Any?
    private var corner: HotCorner = .off
    private var inside = false
    private var lastFire: TimeInterval = 0
    fileprivate var onTrigger: (() -> Void)?

    private(set) var isRunning = false

    private init() {}

    @discardableResult
    func start(corner: HotCorner, onTrigger: @escaping () -> Void) -> Bool {
        stop()
        guard corner.isEnabled else { return true }
        self.corner = corner
        self.onTrigger = onTrigger

        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.evaluate()
        }
        isRunning = monitor != nil
        return isRunning
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRunning = false
        inside = false
        corner = .off
        onTrigger = nil
    }

    private func evaluate() {
        guard corner.isEnabled else { return }
        let location = NSEvent.mouseLocation
        // NSScreen frames are in Cocoa coordinates: y grows upward.
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) }) else {
            inside = false
            return
        }

        let frame = screen.frame
        let nearX = corner.isLeft
            ? location.x <= frame.minX + Self.margin
            : location.x >= frame.maxX - Self.margin
        let nearY = corner.isTop
            ? location.y >= frame.maxY - Self.margin
            : location.y <= frame.minY + Self.margin
        let inCorner = nearX && nearY

        let now = ProcessInfo.processInfo.systemUptime
        if inCorner {
            if !inside, now - lastFire > Self.rearmDelay {
                inside = true
                lastFire = now
                DispatchQueue.main.async { self.onTrigger?() }
            }
        } else {
            inside = false
        }
    }
}

/// Whether the system has already claimed the corner the user picked.
///
/// Desktop & Dock lets each of the four corners carry its own action. When one
/// of them is taken, the system action and our monitor both fire — the deck
/// lands on top of whatever the system just did, and neither side is obviously
/// at fault. We cannot ask the system to stand down, so the honest thing is to
/// say so in Settings instead of leaving the user to work it out.
enum HotCornerConflict {
    /// The `com.apple.dock` key naming each corner's action.
    static func key(for corner: HotCorner) -> String? {
        switch corner {
        case .off: return nil
        case .topLeft: return "wvous-tl-corner"
        case .topRight: return "wvous-tr-corner"
        case .bottomLeft: return "wvous-bl-corner"
        case .bottomRight: return "wvous-br-corner"
        }
    }

    /// Whether `corner` has a system action assigned, read from a corner
    /// preference dictionary.
    ///
    /// Pure, and takes the dictionary rather than reaching for it: the self-test
    /// must neither depend on nor disturb the real Dock preferences, and the
    /// settings window reads them once per refresh instead of per redraw.
    static func systemClaims(_ corner: HotCorner, in cornerDefaults: [String: Any]) -> Bool {
        guard let key = key(for: corner) else { return false }
        // macOS stores `0` for "no action"; anything else is a live action.
        if let value = cornerDefaults[key] as? Int { return value != 0 }
        if let value = cornerDefaults[key] as? NSNumber { return value.intValue != 0 }
        return false
    }

    /// The real Dock corner preferences, or an empty dictionary when they cannot
    /// be read. An unreadable domain reads as "no conflict", so a permission or
    /// sandbox problem degrades to silence rather than to a false warning.
    static func systemCornerDefaults() -> [String: Any] {
        guard let dock = UserDefaults(suiteName: "com.apple.dock") else { return [:] }
        return dock.dictionaryRepresentation()
    }
}

