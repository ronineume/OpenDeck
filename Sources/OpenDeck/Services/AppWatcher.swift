import Foundation
import CoreServices

/// Watches the application folders and reports when their contents change.
///
/// The app list was scanned exactly once, in `DeckStore.init`, so a newly
/// installed app never appeared until the next launch. LaunchOS solves this
/// with a `FinderMonitor`; this is the same idea built on FSEvents.
///
/// Directory-level events are used (not `kFSEventStreamCreateFlagFileEvents`):
/// per-file events would fire for every write inside every bundle.
final class AppWatcher {
    static let shared = AppWatcher()

    /// FSEvents coalesces for us; this is a second, shorter debounce so a burst
    /// of copies becomes one rescan.
    private static let settleDelay: TimeInterval = 1.5

    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var onChange: (() -> Void)?

    private(set) var isRunning = false

    private init() {}

    @discardableResult
    func start(onChange: @escaping () -> Void) -> Bool {
        stop()
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<AppWatcher>.fromOpaque(info).takeUnretainedValue().schedule()
            },
            &context,
            AppScanner.searchRoots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,
            flags
        ) else {
            NSLog("OpenDeck: could not create the application-folder watcher")
            return false
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            NSLog("OpenDeck: could not start the application-folder watcher")
            return false
        }
        self.stream = stream
        isRunning = true
        return true
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.onChange?()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    func stop() {
        pending?.cancel()
        pending = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        isRunning = false
        onChange = nil
    }
}
