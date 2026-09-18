import AppKit

/// Fires when the user pinches in on the trackpad, anywhere in the system.
///
/// Note: public AppKit APIs expose magnification but not the number of fingers
/// involved, so this triggers on a pinch with any finger count rather than
/// distinguishing three from four or five.
final class PinchMonitor {
    static let shared = PinchMonitor()

    /// Total inward magnification that counts as a deliberate pinch.
    private static let triggerThreshold: CGFloat = -0.32
    /// Ignore follow-up gestures briefly after firing.
    private static let cooldown: TimeInterval = 1.0
    /// A gap longer than this starts a fresh gesture.
    private static let gestureGap: TimeInterval = 0.45

    private var globalMonitor: Any?
    private var localMonitor: Any?
    fileprivate var onPinchIn: (() -> Void)?

    private var accumulated: CGFloat = 0
    private var lastEventTime: TimeInterval = 0
    private var cooldownUntil: TimeInterval = 0

    private(set) var isRunning = false

    private init() {}

    @discardableResult
    func start(onPinchIn: @escaping () -> Void) -> Bool {
        stop()
        self.onPinchIn = onPinchIn

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .gesture) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .gesture) { [weak self] event in
            self?.handle(event)
            return event
        }

        isRunning = globalMonitor != nil
        return isRunning
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        isRunning = false
        onPinchIn = nil
    }

    private func handle(_ event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastEventTime > Self.gestureGap {
            accumulated = 0
        }
        lastEventTime = now

        // Magnify gestures report a per-event delta; everything else is ignored.
        let magnification = event.magnification
        guard magnification != 0 else { return }

        accumulated += magnification
        guard now >= cooldownUntil else { return }

        if accumulated <= Self.triggerThreshold {
            accumulated = 0
            cooldownUntil = now + Self.cooldown
            DispatchQueue.main.async { self.onPinchIn?() }
        }
    }
}
