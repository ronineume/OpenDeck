import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: DeckStore!
    private var vm: LaunchpadViewModel!
    private var windowController: LaunchpadWindowController!
    private var settingsController: SettingsWindowController!
    private var uninstallController: UninstallWindowController!
    private var reorganizeController: ReorganizeWindowController!

    /// Minimum gap between rescans triggered merely by showing the deck.
    private static let openRescanInterval: TimeInterval = 5
    /// When the app list was last scanned, so the open-rescan can be throttled.
    /// Seeded to "now": `DeckStore.init` scans at launch, and the deck is shown
    /// right after, so that first show must not trigger a second scan.
    private var lastScanAt: Date = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Repair the impossible pair before anything reads either setting.
        // Done here rather than in the toggle, because a check in the settings UI
        // can only see values written after it existed — an install that already
        // holds both icons off would keep its trap forever.
        let icons = DockIconPolicy.resolveIcons(
            showDockIcon: DeckSettings.shared.showDockIcon,
            showMenuBarIcon: DeckSettings.shared.showMenuBarIcon
        )
        if icons.menuBar != DeckSettings.shared.showMenuBarIcon {
            DeckSettings.shared.showMenuBarIcon = true
        }
        NSApp.setActivationPolicy(DockIconPolicy.policy(showDockIcon: icons.dock))
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
        // Report 47: settings sits **over** the deck instead of replacing it, so
        // closing it hands the keyboard back rather than leaving a live but deaf
        // deck on screen.
        settingsController.onClose = { [weak self] in
            self?.windowController.refocus()
        }
        uninstallController = UninstallWindowController(store: store)
        // Report 51: the uninstall panel is raised above the deck instead of
        // replacing it, so closing it hands the keyboard back — the same
        // contract as settings above.
        uninstallController.onClose = { [weak self] in
            self?.windowController.refocus()
        }
        reorganizeController = ReorganizeWindowController()
        // Same contract as the two panels above (reports 47/51): the sheet
        // never takes the deck down, and the deck gets the keyboard back.
        reorganizeController.onClose = { [weak self] in
            self?.windowController.refocus()
        }

        observeNotifications()

        let settings = DeckSettings.shared
        applyHotKey(settings.hotKeySpec)
        applyLaunchpadKey(settings.launchpadKeyEnabled)
        applyPinch(settings.pinchEnabled)
        applyHotCorner(settings.hotCorner)
        applyMenuBarIcon(settings.showMenuBarIcon)
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

    /// Add or remove the menu-bar icon. A no-op while headless, so a development
    /// tool cannot leave an icon on the user's screen (see `MenuBarController`).
    private func applyMenuBarIcon(_ enabled: Bool) {
        MenuBarController.shared.apply(enabled: enabled)
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
            selector: #selector(reorganizeRequested),
            name: .deckRequestReorganize,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(displayModeChanged),
            name: .deckDisplayModeChanged,
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
            selector: #selector(menuBarIconChanged),
            name: .deckMenuBarIconChanged,
            object: nil
        )
        // The status item does not own the deck window; it asks for it.
        center.addObserver(
            self,
            selector: #selector(menuBarOpened),
            name: .deckMenuBarOpen,
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
        // **Asking to uninstall something is not a reason to take the deck down**
        // (report 51). This used to `windowController.hide()` — with the default
        // `deactivate: true` — and then show the panel. That is precisely the
        // trap `hide(deactivate:)` documents: `NSApp.hide(nil)` fires 0.13 s
        // later, when the fade ends, and takes the panel down with the rest of
        // the app, so the user saw the confirmation window flash and vanish. The
        // panel is raised above the deck instead (`UninstallPanelLevel`) and
        // closing it hands the keyboard back.
        uninstallController.show(app: app)
    }

    /// Opens the Reorganize Layout sheet (report 53, LaunchOS Pro feature).
    ///
    /// The sheet reopens on the rules the user last used (`DeckSettings`
    /// persists the `Organize*` keys, as LaunchOS does). The deck stays up
    /// behind it — the same contract as the settings and uninstall panels.
    @objc private func reorganizeRequested() {
        reorganizeController.show(
            options: DeckSettings.shared.organizeOptions,
            pageCount: store.pages.count,
            above: ReorganizePanelLevel.panel,
            onApply: { [weak self] options in
                DeckSettings.shared.organizeOptions = options
                self?.confirmReorganize(options)
            }
        )
    }

    /// The display mode changed (report 56 §5). The window is built per showing,
    /// so the honest thing is to rebuild it now: the user picked a mode and
    /// expects to see it, not to be told to reopen the deck.
    @objc private func displayModeChanged() {
        guard windowController.isVisible else { return }
        let screen = LaunchpadWindowController.targetScreen()
        windowController.show(on: screen)
    }

    /// The overwrite confirmation, with LaunchOS's own wording
    /// (`localization.json`): "The current app layout and folders will be
    /// overwritten.\nThis action cannot be undone.\nDo you want to continue?"
    private func confirmReorganize(_ options: OrganizeOptions) {
        guard !AppEnvironment.isHeadless else { return }
        let alert = NSAlert()
        alert.messageText = "The current app layout and folders will be overwritten.\n"
            + "This action cannot be undone.\n"
            + "Do you want to continue?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reorganize")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.reorganize(with: options)
        windowController.refocus()
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

    @objc private func menuBarIconChanged() {
        applyMenuBarIcon(DeckSettings.shared.showMenuBarIcon)
    }

    /// The menu-bar item asked to show the deck. `showDeck` rather than
    /// `toggleDeck`: a menu click is never a request to close what is on screen.
    @objc private func menuBarOpened() {
        showDeck()
    }

    @objc private func openSettingsRequested() {
        openSettings()
    }

    @objc func openSettings() {
        // **Opening settings is not leaving the app** (report 47).
        //
        // This used to `windowController.hide(deactivate: false)` first and only
        // then show settings. That took the whole deck down — the desktop came
        // back, and since `hide()` also tears the host down and resets the view
        // model, closing settings left the user looking at their wallpaper with
        // nothing to return to. LaunchOS does not do that: `openPreferences`
        // (`0x10011f650`) only dispatches its preferences window through
        // `MenuBarManager`; nothing hides the launchpad.
        //
        // So the deck stays up and the panel is raised above it. `deactivate`
        // never mattered here — the previous comment worried about `NSApp.hide`
        // taking the settings window down with it, which is exactly why the
        // window is given a level instead.
        settingsController.show(
            above: SettingsPanelLevel.resolve(
                deckVisible: windowController.isVisible,
                deckLevel: LaunchpadWindowController.deckWindowLevel
            )
        )
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
