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

        /// A probe deck in its own window, so a programmatic scroll has something
        /// to scroll.
        func probeWindow(_ vm: LaunchpadViewModel) -> NSWindow {
            let root = LaunchpadView(store: store, vm: vm, metrics: metrics, screen: screen)
            let host = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 700, height: 460),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            host.frame = CGRect(x: 0, y: 0, width: 700, height: 460)
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: 20, y: 20))
            window.alphaValue = 0.01
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            return window
        }

        var scrollFailures = 0

        // The swipe path: a programmatic scroll must move the page indicator.
        // This is the wiring the user sees as "the dots do not follow".
        let probe = LaunchpadViewModel(store: store)
        let pageWindow = probeWindow(probe)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        for target in [1, 2, 0] where target < pageCount {
            probe.jumper.target = target
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            let settled = probe.paging.resolved(count: pageCount)
            // `reportedPage` is the page the **scroll view** last reported, so
            // asserting it is what proves the grid moved rather than only that
            // the model was told to.
            let reported = probe.jumpGuard.reportedPage
            let ok = settled == target && reported == target
            if !ok { scrollFailures += 1 }
            print("  \(ok ? "PASS" : "FAIL")  scroll to page \(target)"
                  + " -> indicator \(settled), scroll view reports \(reported)")
        }
        pageWindow.orderOut(nil)

        // The resume path, which the loop above does **not** cover: that loop
        // publishes its target once the view is already up, so `onChange`
        // delivers it. The window controller publishes the remembered page
        // *while* it builds the view, and `onChange` reports changes — a target
        // that is already set when the grid appears is one it never sees. So the
        // target is set here before the window exists, exactly as
        // `LaunchpadWindowController.show` does it.
        if pageCount > 1 {
            let resumed = min(2, pageCount - 1)
            let resumeProbe = LaunchpadViewModel(store: store)
            resumeProbe.jumper.target = resumed
            let resumeWindow = probeWindow(resumeProbe)
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            let settled = resumeProbe.paging.resolved(count: pageCount)
            let reported = resumeProbe.jumpGuard.reportedPage
            let ok = settled == resumed && reported == resumed
            if !ok { scrollFailures += 1 }
            print("  \(ok ? "PASS" : "FAIL")  resume on page \(resumed)"
                  + " -> indicator \(settled), scroll view reports \(reported)")
            resumeWindow.orderOut(nil)
        }

        print("bench: \(reps) iterations, \(pageCount) pages, \(store.apps.count) apps, \(metrics.columns)x\(metrics.rows) grid")
        report("page switch (indicator + jump + selection)", pageSamples)
        report("selection move only", selectionSamples)
        print("scroll-follow failures: \(scrollFailures)")
        exit(scrollFailures == 0 ? 0 : 1)
    }
}
