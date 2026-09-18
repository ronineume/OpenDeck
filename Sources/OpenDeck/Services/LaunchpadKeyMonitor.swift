import AppKit

/// Watches for the keyboard's Launchpad key (the consumer-control event that
/// older Apple keyboards send for F4).
///
/// Carbon hot keys cannot express consumer-control keys, so this needs a
/// CGEventTap, which in turn needs Accessibility permission.
final class LaunchpadKeyMonitor {
    static let shared = LaunchpadKeyMonitor()

    /// NX_KEYTYPE_LAUNCH_PANEL from IOKit's hidsystem.
    private static let launchPanelKeyType: Int64 = 12
    private static let systemDefinedEventType: UInt32 = 14

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    fileprivate var onFire: (() -> Void)?

    private(set) var isRunning = false

    private init() {}

    /// Returns false when Accessibility permission has not been granted.
    @discardableResult
    func start(onFire: @escaping () -> Void) -> Bool {
        stop()
        guard Permissions.hasAccessibility else { return false }
        self.onFire = onFire

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << Self.systemDefinedEventType)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<LaunchpadKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("OpenDeck: could not create event tap for the Launchpad key")
            return false
        }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = nil
        }
        isRunning = false
        onFire = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long; re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if type.rawValue == Self.systemDefinedEventType {
            // NSEvent carries the key type/state in the system-defined data field.
            guard let nsEvent = NSEvent(cgEvent: event) else {
                return Unmanaged.passUnretained(event)
            }
            let data = nsEvent.data1
            let keyType = (data >> 16) & 0xFFFF
            let keyState = (data >> 8) & 0xFF
            let isKeyDown = keyState == 0x0A
            if keyType == Int(Self.launchPanelKeyType), isKeyDown {
                DispatchQueue.main.async { self.onFire?() }
                return nil // swallow so the system does not act on it too
            }
        }

        return Unmanaged.passUnretained(event)
    }
}
