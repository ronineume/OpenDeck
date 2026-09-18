import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: DeckStore!
    private var vm: LaunchpadViewModel!
    private var windowController: LaunchpadWindowController!
    private var settingsController: SettingsWindowController!
    private var uninstallController: UninstallWindowController!

    /// Minimum gap between rescans triggered merely by showing the deck.
    private static let openRescanInterval: TimeInterval = 5
    /// When the app list was last scanned, so the open-rescan can be throttled.
    /// Seeded to "now": `DeckStore.init` scans at launch, and the deck is shown
    /// right after, so that first show must not trigger a second scan.
    private var lastScanAt: Date = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMainMenu()

        // The app was called LaunchDeck before the rename, which moved both the
        // layout folder and the preferences domain. The store below hands its
        // own layout over; the preferences are handed over by `DeckSettings`,
        // which has to happen before anything writes a default — so it lives
        // there, not here.
        let carriedFiles = StateHandover.adoptEverything()
        if !carriedFiles.isEmpty {
            NSLog("OpenDeck: took over %d layout file(s) from the pre-rename install",
                  carriedFiles.count)
        }

        RunningApps.start()

        store = DeckStore()
        // `DeckStore.init` runs `loadLayout()` synchronously, so `layoutHealthMessage`
        // is already final here. Bridge it to Settings for display (same pattern as
        // `appWatcherError` below); nothing here changes at runtime, so no observing.
        DeckSettings.shared.layoutHealthMessage = store.layoutHealthMessage
        vm = LaunchpadViewModel(store: store)
        windowController = LaunchpadWindowController(store: store, vm: vm)
        settingsController = SettingsWindowController(store: store, settings: DeckSettings.shared)
        uninstallController = UninstallWindowController(store: store)

        observeNotifications()

        let settings = DeckSettings.shared
        applyHotKey(settings.hotKeySpec)
        applyLaunchpadKey(settings.launchpadKeyEnabled)
        applyPinch(settings.pinchEnabled)
        applyHotCorner(settings.hotCorner)
        if !AppWatcher.shared.start(onChange: { [weak self] in self?.refreshInstalledApps() }) {
            // A failed watcher silently degrades to "scan only at launch", so
            // surface it in Settings instead of leaving the NSLog as the only trace.
            DeckSettings.shared.appWatcherError =
                "Application-folder watching could not start — newly installed or removed apps will not appear until OpenDeck is relaunched."
        } else {
            DeckSettings.shared.appWatcherError = nil
        }

        windowController.show(on: LaunchpadWindowController.targetScreen())
    }

    // MARK: - System integration

    private func applyHotKey(_ spec: HotKeySpec?) {
        HotKeyManager.shared.register(spec) { [weak self] in
            self?.toggleDeck()
        }
    }

    private func applyLaunchpadKey(_ enabled: Bool) {
        if enabled {
            if !LaunchpadKeyMonitor.shared.start(onFire: { [weak self] in self?.toggleDeck() }) {
                // Accessibility not granted yet; surfaced in the settings window.
                DeckSettings.shared.launchpadKeyEnabled = false
                Permissions.requestAccessibility()
            }
        } else {
            LaunchpadKeyMonitor.shared.stop()
        }
    }

    private func applyPinch(_ enabled: Bool) {
        if enabled {
            PinchMonitor.shared.start { [weak self] in self?.toggleDeck() }
        } else {
            PinchMonitor.shared.stop()
        }
    }

    /// A corner only *opens* the deck; it never closes one already on screen.
    private func applyHotCorner(_ corner: HotCorner) {
        HotCornersMonitor.shared.start(corner: corner) { [weak self] in
            guard let self else { return }
            if !self.windowController.isVisible { self.showDeck() }
        }
    }

    /// Rescan off the main thread: the scan touches Spotlight metadata for
    /// every bundle, which would stutter the deck if done inline.
    private func refreshInstalledApps() {
        lastScanAt = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let scanned = AppScanner.scan()
            NSLog("OpenDeck: rescan after folder change -> %d apps", scanned.count)
            DispatchQueue.main.async { self?.store.applyScan(scanned) }
        }
    }

    /// The deck was just shown. FSEvents already covers folder changes; this is a
    /// safety net for an event missed while the process was idle or suspended
    /// (see `AppWatcher`). Throttled so repeatedly opening the deck does not
    /// rescan every time, and so it cannot double up with a scan the watcher has
    /// just triggered — `lastScanAt` is stamped by every scan, whatever the cause.
    @objc private func rescanRequested() {
        guard Date().timeIntervalSince(lastScanAt) >= Self.openRescanInterval else { return }
        refreshInstalledApps()
    }

    private func toggleDeck() {
        // Never stack the deck on top of our own settings windows.
        if let window = NSApp.keyWindow, window.title.hasPrefix("OpenDeck Settings") {
            return
        }
        windowController.toggle()
    }

    private func showDeck() {
        windowController.show(on: LaunchpadWindowController.targetScreen())
    }

    // MARK: - Notifications

    private func observeNotifications() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(uninstallRequested(_:)),
            name: .deckRequestUninstall,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(hotKeyChanged(_:)),
            name: .deckHotKeyChanged,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(pinchChanged(_:)),
            name: .deckPinchChanged,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(launchpadKeyChanged(_:)),
            name: .deckLaunchpadKeyChanged,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(openSettingsRequested),
            name: .deckOpenSettings,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(hotCornerChanged),
            name: .deckHotCornerChanged,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(rescanRequested),
            name: .deckRescanRequested,
            object: nil
        )
        // Wallpaper and Space changes invalidate the cached backdrop.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    @objc private func screensChanged() {
        WallpaperProvider.invalidate()
        windowController.screenConfigurationChanged()
    }

    @objc private func workspaceChanged() {
        WallpaperProvider.invalidate()
    }

    @objc private func uninstallRequested(_ note: Notification) {
        guard let appID = note.object as? String, let app = store.app(id: appID) else { return }
        windowController.hide()
        uninstallController.show(app: app)
    }

    @objc private func hotKeyChanged(_ note: Notification) {
        applyHotKey(DeckSettings.shared.hotKeySpec)
    }

    @objc private func pinchChanged(_ note: Notification) {
        applyPinch(DeckSettings.shared.pinchEnabled)
    }

    @objc private func launchpadKeyChanged(_ note: Notification) {
        applyLaunchpadKey(DeckSettings.shared.launchpadKeyEnabled)
    }

    // MARK: - Application lifecycle

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDeck()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The deck window closing should not kill the app; the Dock icon stays.
        false
    }

    @objc private func hotCornerChanged() {
        applyHotCorner(DeckSettings.shared.hotCorner)
    }

    @objc private func openSettingsRequested() {
        openSettings()
    }

    @objc func openSettings() {
        // Show settings only after the deck has faded out, and do not deactivate
        // the app: `NSApp.hide` would take the settings window down with it.
        windowController.hide(deactivate: false) { [weak self] in
            self?.settingsController.show()
        }
    }

    /// A minimal menu bar so standard shortcuts (Cmd+Q, Cmd+,) work.
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About OpenDeck",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide OpenDeck",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit OpenDeck",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}
