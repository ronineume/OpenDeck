import AppKit
import SwiftUI
import QuartzCore

/// Borderless window that is allowed to become key so the search field can take
/// keyboard input — but not while it is busy delivering a click.
///
/// The rule, and why the permission has to be withdrawn for one click, is in
/// `DeckClickState`. In short: a window that is on screen but not key is treated
/// by AppKit as owing the application an activation, so the mouse-down on an icon
/// is spent on that instead of being delivered — and the icon never launches.
final class DeckWindow: NSWindow {
    private var clickState = DeckClickState()

    /// The deck's drag, for as long as the deck is on screen.
    ///
    /// Weak: the host already points back at this window, and the controller
    /// owns the host's lifetime.
    weak var dragHost: DeckDragHost?

    override var canBecomeKey: Bool { clickState.canBecomeKey }
    override var canBecomeMain: Bool { clickState.canBecomeKey }

    override func sendEvent(_ event: NSEvent) {
        // The drag gets first refusal. It never takes a press — clicks and
        // context menus must keep working — so this can only swallow the events
        // of a drag that has already passed the slop.
        if let dragHost, dragHost.handle(event, in: self) { return }

        let route = clickState.route(event.type, isKeyWindow: isKeyWindow)
        guard route != .normal else {
            super.sendEvent(event)
            return
        }

        super.sendEvent(event)
        // Give the permission back before activating, or `makeKeyAndOrderFront`
        // would be asking a window that still says it cannot become key.
        clickState.finishRouting()

        // Only the down reclaims activation: by the time the up arrives the window
        // is key again. If the down could not get it, the up is routed the same
        // way instead — and activating there would risk resurrecting a deck that
        // this very click has just dismissed.
        if route == .deliverThenActivate {
            activateAndBecomeKey()
        }
    }

    /// Reclaim activation now that the click has been handled, so the deck is a
    /// normal key window again for keyboard input.
    private func activateAndBecomeKey() {
        // The click may have launched an app and dismissed the deck; ordering a
        // hidden window back to the front would bring it straight back.
        guard isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }
}

/// Owns the full-screen deck window, its show/hide animation and its key handling.
@MainActor
final class LaunchpadWindowController {
    /// The deck window's show/hide fade — measured from LaunchOS, not invented.
    ///
    /// LaunchOS's `LaunchpadWindowSurfaceView` controller runs an AppKit
    /// `NSAnimationContext.runAnimationGroup` alpha fade on **both** show and
    /// hide at **0.24 s** on the default (ease-in-out) curve — recovered from the
    /// arm64 binary at `0x100015708` (show: `makeKeyAndOrderFront` + alpha→1)
    /// and `0x100016290` (hide: alpha→0), each of which multiplies its duration
    /// by the remaining alpha (`(1 − alpha)·0.24` to open, `alpha·0.24` to close)
    /// so a fade interrupted part-way still completes on schedule rather than
    /// restarting — the toggle reads as continuous. The show path also sets a
    /// `CAFrameRateRange(60, 240)` for the duration (ProMotion); that hook is not
    /// ported here because it needs a whole-window implicit `CAAnimation`, which
    /// is a separate change (tracked, not silently dropped).
    ///
    /// OpenDeck's earlier 0.16 s easeOut / 0.13 s easeIn asymmetry was its own
    /// choice, not LaunchOS's — replaced by the measured 0.24 s here.
    private enum WindowMotion {
        static let fadeDuration: Double = 0.24
    }

    /// The fade duration toward `target` alpha, scaled by the remaining distance
    /// exactly as LaunchOS does — ported from `(target − current) · 0.24`.
    private func fadeDuration(toward target: CGFloat, current: CGFloat) -> Double {
        let here = Swift.max(0, Swift.min(1, Double(current)))
        return abs(Double(target) - here) * WindowMotion.fadeDuration
    }

    private var window: DeckWindow?
    private var keyMonitor: Any?
    /// The deck's drag. Rebuilt on every showing, because it holds live state —
    /// a display link, dwell timers, an open store session — that must never
    /// outlive the deck it belongs to.
    private var dragHost: DeckDragHost?
    private let store: DeckStore
    private let vm: LaunchpadViewModel

    private(set) var isVisible = false

    init(store: DeckStore, vm: LaunchpadViewModel) {
        self.store = store
        self.vm = vm
    }

    /// The screen the deck should appear on, per `DeckSettings.screenPolicy`.
    ///
    /// The decision itself lives in `ScreenPicker`, which is pure and therefore
    /// drivable from `--selftest` — including the three policies a single-display
    /// machine cannot demonstrate. All this does is hand the picker the real
    /// geometry and resolve the index it returns.
    ///
    /// `NSScreen.main` is passed as the frontmost app's screen because that is
    /// what it is: AppKit documents it as the screen holding the window with the
    /// keyboard focus, falling back to the menu-bar screen when there is none.
    static func targetScreen() -> NSScreen {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return NSScreen.main! }
        let index = ScreenPicker.targetIndex(
            policy: DeckSettings.shared.screenPolicy,
            screens: screens.map { ScreenInfo($0) },
            pointer: NSEvent.mouseLocation,
            activeScreenID: NSScreen.main.map { ScreenInfo($0).id }
        )
        return screens[min(max(index, 0), screens.count - 1)]
    }

    /// The level the deck window is put at.
    ///
    /// **It must stay below `kCGDraggingWindowLevel`.** The icon in the air is
    /// handed to AppKit as an `NSDraggingItem`, and AppKit puts its window at
    /// that level — measured at **500**, and measured to be 500 *whatever* level
    /// the source window is at (probe `/tmp/probe-dragsession/main11.swift`;
    /// AppKit never raises the drag image above the window it came from).
    ///
    /// A deck above that level is composited **over** the icon. The deck is
    /// full-screen and carries a frosted `NSVisualEffectView`, so what the icon
    /// falls behind is the blur: it looks like the icon stopped being dragged and
    /// became part of the backdrop. `CGShieldingWindowLevel()` — measured
    /// 2147483628 — did exactly that.
    ///
    /// One below the dragging level still leaves the deck above everything it is
    /// meant to cover: the Dock (20), the menu bar (24), popup menus (101) and the
    /// overlay level (102). A screen saver (1000) now comes up over it, which is
    /// what should happen to a full-screen app.
    nonisolated static var deckWindowLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.draggingWindow)) - 1)
    }

    /// Builds the deck window.
    ///
    /// **This is the only place a deck window is configured, on purpose.** The
    /// level used to be set from `show()`, and that made the fix fragile in a way
    /// the suite could not see: mutation **M89** rewrote the line and stayed
    /// green (the checks only drove `deckWindowLevel` — the *decision*), and when
    /// the level was moved into `applyDeckLevel(to:)` the same hole simply
    /// reappeared one level up: a mutation reverting the line in `show()` also
    /// stayed green, because **nothing in the suite can run `show()`** (it posts
    /// notifications, starts FSEvents, sets `presentationOptions` and activates
    /// the app).
    ///
    /// Folding the whole construction here removes the second site instead of
    /// trying to guard it, and gives the suite something it can actually drive.
    ///
    /// Internal so `--selftest` can build one; the window it returns is never
    /// ordered on screen.
    ///
    /// - Parameter mode: overrides `DeckSettings.shared.displayMode`. The
    ///   suite passes one explicitly: this window is otherwise built from the
    ///   **user's** live setting, and a check that only passes while the user
    ///   happens to be in full-screen mode is not a check.
    static func makeDeckWindow(on screen: NSScreen,
                               mode: DisplayMode? = nil) -> DeckWindow {
        let style = DeckWindowStyleResolver.style(
            for: mode ?? DeckSettings.shared.displayMode,
            screen: screen.frame.size
        )
        let rect = style.fullScreen
            ? screen.frame
            : CGRect(origin: .zero, size: style.contentSize)
        let window = DeckWindow(
            contentRect: rect,
            styleMask: style.fullScreen ? [.borderless]
                : [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = style.hasShadow
        // A borderless full-screen deck is not movable; a windowed one is —
        // by its title bar and by its own background.
        window.isMovable = !style.fullScreen
        window.isMovableByWindowBackground = style.movableByBackground
        window.animationBehavior = .none
        // Deliberately **not** `CGShieldingWindowLevel()`. See `deckWindowLevel`.
        // A windowed deck drops to `.normal`: the whole point of the mode is
        // that other apps can come over it (report 56 §5).
        window.level = style.usesDeckLevel ? deckWindowLevel : .normal
        window.collectionBehavior = style.fullScreen
            ? [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            : [.canJoinAllSpaces]
        if style.fullScreen {
            window.title = "OpenDeck"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
        } else {
            window.title = "OpenDeck"
        }
        return window
    }

    func toggle(on screen: NSScreen? = nil) {
        if isVisible {
            hide()
        } else {
            show(on: screen ?? Self.targetScreen())
        }
    }

    func show(on screen: NSScreen) {
        // Rebuilding is cheap and picks up a possibly different screen geometry.
        // Not a dismissal: the deck is being replaced, not put away, and stamping
        // `lastPageLeftAt` here would make every re-show look like it happened a
        // moment after the last one — so a timed `ReturnToHome` policy would
        // always resume.
        if isVisible { hide(immediately: true, recordDismissal: false) }

        // The mode decides both the window and the space the grid is laid out
        // for: full screen lays out for the screen, window mode for the window
        // it is about to become (report 56 §5).
        let style = DeckWindowStyleResolver.style(
            for: DeckSettings.shared.displayMode,
            screen: screen.frame.size
        )
        let metrics = GridMetrics.make(
            in: style.contentSize,
            preset: DeckSettings.shared.gridPreset,
            iconScale: CGFloat(DeckSettings.shared.iconScale)
        )
        store.metrics = metrics
        vm.reset()
        // Reopen on the page the user left off on, when the policy says to.
        //
        // Only the *request* is published here — `paging` is deliberately left
        // alone. The page count is known at this point but the scroll view does
        // not exist yet, so claiming a page here leaves the model describing a
        // grid it has not moved to, and `PagesScroller` adopts that first report
        // as the user's, overwriting the jump before it lands. The grid consumes
        // this value on appear and clamps it there (see `PageJumpGuard`).
        let settings = DeckSettings.shared
        if settings.returnToHome.resumes(lastPage: settings.lastPage,
                                         closedAt: settings.lastPageLeftAt,
                                         now: Date()) {
            vm.jumper.target = settings.lastPage
        }
        vm.dismiss = { [weak self] in self?.hide() }
        vm.openSettings = {
            NotificationCenter.default.post(name: .deckOpenSettings, object: nil)
        }

        // One drag host per showing. It owns the input path (the window routes
        // mouse events to it), the strip and the drag state; the view only
        // renders them.
        let host = DeckDragHost(store: store, vm: vm)
        dragHost = host

        let root = LaunchpadView(store: store, vm: vm, metrics: metrics, screen: screen,
                                 drag: host.drag, offset: host.offset)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: style.contentSize)

        let window = Self.makeDeckWindow(on: screen)
        window.contentView = hosting
        window.dragHost = host
        if style.fullScreen {
            window.setFrame(screen.frame, display: true)
        } else {
            // Centred on the deck's screen, the way a window the user just
            // asked for should appear.
            let frame = CGRect(
                x: screen.frame.midX - style.contentSize.width / 2,
                y: screen.frame.midY - style.contentSize.height / 2,
                width: style.contentSize.width,
                height: style.contentSize.height
            )
            window.setFrame(frame, display: true)
            // A titled window's content is shorter than its frame by the title
            // bar; the grid was laid out for the content, so give it back.
            window.setContentSize(style.contentSize)
            window.center()
        }
        window.alphaValue = 0

        self.window = window
        isVisible = true

        installKeyMonitor()

        // Launchpad hides the Dock while it is open.
        if DeckSettings.shared.hideDock {
            NSApp.presentationOptions = [.autoHideDock]
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration(toward: 1, current: window.alphaValue)
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 1
        }

        // Safety net for a missed FSEvents event: ask for a rescan on every open.
        // The throttle lives in `AppDelegate.rescanRequested`, so this is cheap.
        NotificationCenter.default.post(name: .deckRescanRequested, object: nil)
    }

    /// - Parameters:
    ///   - deactivate: hand focus back to the previous app. Must be false when
    ///     another window of ours (settings) is about to be shown, otherwise
    ///     `NSApp.hide` fires afterwards and hides that window too.
    ///   - recordDismissal: stamp "the user put the deck away just now", which is
    ///     what a timed `ReturnToHome` policy measures against. False only for
    ///     the internal teardown `show` performs before rebuilding.
    ///   - then: runs after the fade-out completes.
    func hide(immediately: Bool = false, deactivate: Bool = true, recordDismissal: Bool = true, then completion: (() -> Void)? = nil) {
        guard let window, isVisible else {
            completion?()
            return
        }
        isVisible = false
        if recordDismissal { DeckSettings.shared.lastPageLeftAt = Date() }
        removeKeyMonitor()
        // Restore the Dock before we hand focus back.
        NSApp.presentationOptions = []
        vm.reset()
        // A drag opens a session (see `DeckDragHost`) and closes it on release.
        // If the deck is torn down mid-drag (e.g. Esc while the button is held)
        // that release never arrives, so the session would stay open for the rest
        // of the session — and `save()` would then be a permanent no-op (data
        // loss on quit). `teardown` also stops the strip's display link and any
        // pending dwell, and `endDragSession()` is idempotent (no-ops when
        // nothing is open), so a normal hide remains a no-op.
        dragHost?.teardown()
        dragHost = nil
        self.window = nil

        if immediately {
            window.orderOut(nil)
            completion?()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration(toward: 0, current: window.alphaValue)
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
            if deactivate { NSApp.hide(nil) }
            completion?()
        }
    }

    /// Reposition when displays change while visible.
    func screenConfigurationChanged() {
        guard isVisible, let window, let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(screen.frame, display: true)
    }

    /// Take the keyboard back after one of our own windows closes.
    ///
    /// The deck deliberately stays on screen while settings is open (report 47),
    /// so when that window goes away the deck has to become key again — the key
    /// monitor is guarded on `isKeyWindow`, and `isVisible` is already true, so
    /// nothing else would ever restore the search field, the arrow keys or
    /// Escape.
    func refocus() {
        guard isVisible, let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only while the deck actually holds the keyboard. The deck now stays
            // on screen behind the settings window (report 47), and a local
            // monitor sees **every** key in the app: without this guard, Escape
            // in a settings text field put the deck away, and Return could launch
            // the deck's selected app from under the settings window.
            guard let self, self.window?.isKeyWindow == true else { return event }
            if self.vm.handleKeyDown(event) { return nil }
            if event.keyCode == 53 { // Escape with nothing left to close
                self.hide()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
