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
