import AppKit
import SwiftUI

/// Measures the cost of a state change that re-renders the deck.
///
/// Page switching is what the user notices, so this drives real page changes
/// through the real view hierarchy. Reports percentiles rather than averages:
/// a single slow frame is what reads as a stutter.
@MainActor
enum BenchRunner {
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private static func report(_ label: String, _ samples: [Double]) {
        let ms = samples.map { $0 * 1000 }.sorted()
        let p50 = percentile(ms, 0.50)
        let p95 = percentile(ms, 0.95)
        let worst = ms.last ?? 0
        let budget = 16.67
        print(String(format: "  %@", label))
        print(String(format: "    p50 %.2f ms   p95 %.2f ms   worst %.2f ms", p50, p95, worst))
        print(String(format: "    60 fps budget is %.2f ms -> p95 %@",
                     budget, p95 <= budget ? "OK" : "OVER BUDGET"))
    }

    static func run(frames: Int) {
        AppEnvironment.isOffscreenRender = true

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let store = DeckStore(readOnly: true)
        store.reloadApps()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { exit(1) }
        let metrics = GridMetrics.make(for: screen)
        store.metrics = metrics

        let pageCount = max(store.pages.count, 1)
        let reps = max(frames, 1)
        let vm = LaunchpadViewModel(store: store)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: screen.frame.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))

        let root = LaunchpadView(store: store, vm: vm, metrics: metrics, screen: screen)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: screen.frame.size)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        func time(_ work: () -> Void) -> Double {
            let start = Date()
            work()
            hosting.layoutSubtreeIfNeeded()
            return Date().timeIntervalSince(start)
        }

        // Warm-up so the first sample is not a cold-cache outlier.
        for _ in 0 ..< 5 {
            _ = time { vm.jumper.target = (vm.paging.resolved(count: pageCount) + 1) % pageCount }
            _ = time { vm.selection = (vm.selection + 1) % max(metrics.capacity, 1) }
        }

        var pageSamples: [Double] = []
        for _ in 0 ..< reps {
            pageSamples.append(time {
                let next = (vm.paging.resolved(count: pageCount) + 1) % pageCount
                vm.jumper.target = vm.paging.set(next, count: pageCount)
            })
        }

        var selectionSamples: [Double] = []
        for _ in 0 ..< reps {
            selectionSamples.append(time {
                vm.selection = (vm.selection + 1) % max(metrics.capacity, 1)
            })
        }

        // The swipe path: a programmatic scroll must move the page indicator.
        // This is the wiring the user sees as "the dots do not follow".
        let probe = LaunchpadViewModel(store: store)
        let probeRoot = LaunchpadView(store: store, vm: probe, metrics: metrics, screen: screen)
        let probeHost = NSHostingView(rootView: probeRoot)
        let probeWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 700, height: 460),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        probeHost.frame = CGRect(x: 0, y: 0, width: 700, height: 460)
        probeWindow.contentView = probeHost
        probeWindow.setFrameOrigin(NSPoint(x: 20, y: 20))
        probeWindow.alphaValue = 0.01
        probeWindow.orderFront(nil)
        probeHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        var scrollFailures = 0
        for target in [1, 2, 0] where target < pageCount {
            probe.jumper.target = target
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            let settled = probe.paging.resolved(count: pageCount)
            let ok = settled == target
            if !ok { scrollFailures += 1 }
            print("  \(ok ? "PASS" : "FAIL")  scroll to page \(target) -> indicator reports \(settled)")
        }
        probeWindow.orderOut(nil)

        print("bench: \(reps) iterations, \(pageCount) pages, \(store.apps.count) apps, \(metrics.columns)x\(metrics.rows) grid")
        report("page switch (indicator + jump + selection)", pageSamples)
        report("selection move only", selectionSamples)
        print("scroll-follow failures: \(scrollFailures)")
        exit(scrollFailures == 0 ? 0 : 1)
    }
}
