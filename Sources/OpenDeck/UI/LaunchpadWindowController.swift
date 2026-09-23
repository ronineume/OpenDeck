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

    override var canBecomeKey: Bool { clickState.canBecomeKey }
    override var canBecomeMain: Bool { clickState.canBecomeKey }

    override func sendEvent(_ event: NSEvent) {
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
    private var window: DeckWindow?
    private var keyMonitor: Any?
    private let store: DeckStore
    private let vm: LaunchpadViewModel

    private(set) var isVisible = false

    init(store: DeckStore, vm: LaunchpadViewModel) {
        self.store = store
        self.vm = vm
    }

    /// The screen the deck should appear on: wherever the pointer is.
    static func targetScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let hit = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return hit
        }
        return NSScreen.main ?? NSScreen.screens[0]
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
        if isVisible { hide(immediately: true) }

        let metrics = GridMetrics.make(for: screen)
        store.metrics = metrics
        vm.reset()
        // "Saved State": reopen on the page the user left off on.
        //
        // Only the *request* is published here — `paging` is deliberately left
        // alone. The page count is known at this point but the scroll view does
        // not exist yet, so claiming a page here leaves the model describing a
        // grid it has not moved to, and `PagesScroller` adopts that first report
        // as the user's, overwriting the jump before it lands. The grid consumes
        // this value on appear and clamps it there (see `PageJumpGuard`).
        if DeckSettings.shared.resumeLastPage {
            vm.jumper.target = DeckSettings.shared.lastPage
        }
        vm.dismiss = { [weak self] in self?.hide() }
        vm.openSettings = {
            NotificationCenter.default.post(name: .deckOpenSettings, object: nil)
        }

        let root = LaunchpadView(store: store, vm: vm, metrics: metrics, screen: screen)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: screen.frame.size)

        let window = DeckWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.contentView = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = false
        window.animationBehavior = .none
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.setFrame(screen.frame, display: true)
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
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
    ///   - then: runs after the fade-out completes.
    func hide(immediately: Bool = false, deactivate: Bool = true, then completion: (() -> Void)? = nil) {
        guard let window, isVisible else {
            completion?()
            return
        }
        isVisible = false
        removeKeyMonitor()
        // Restore the Dock before we hand focus back.
        NSApp.presentationOptions = []
        vm.reset()
        // A drag opens a session (see `handleDragChange`) and closes it in
        // `commitDrag`. If the deck is torn down mid-drag (e.g. Esc while the
        // button is held) `onEnded` never fires, so the session would stay open
        // for the rest of the session — and `save()` would then be a permanent
        // no-op (data loss on quit). Close any open session here;
        // `endDragSession()` is idempotent (no-ops when nothing is open),
        // so a normal hide remains a no-op.
        store.endDragSession()
        self.window = nil

        if immediately {
            window.orderOut(nil)
            completion?()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.13
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
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

    // MARK: - Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
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
