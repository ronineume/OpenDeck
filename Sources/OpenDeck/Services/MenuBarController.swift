import AppKit

/// The optional menu-bar icon.
///
/// Off by default (see `DeckSettings.showMenuBarIcon`): the app already owns a
/// Dock icon, and the deck is meant to be summoned by the same key Launchpad
/// used rather than by hunting for a status item. Turning it on buys a permanent
/// target that also carries Settings and Quit, which matters for a windowless
/// overlay that has no other chrome.
///
/// The item is **never** built while headless. `--snapshot` and `--bench` build
/// the same objects the app does, and a status item is a real change to the menu
/// bar of the user's screen — the same reason `DeckSettings` drops writes and
/// `DeckStore` is handed an explicit `storeURL`.
@MainActor
final class MenuBarController {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?

    /// Whether an icon is in the menu bar right now.
    var isInstalled: Bool { statusItem != nil }

    private init() {}

    /// Creates or removes the status item to match `enabled`.
    ///
    /// Idempotent, so the launch path and the notification path can both call it
    /// without having to know whether the other already ran.
    ///
    /// - Returns: whether an icon is installed afterwards, which is `false`
    ///   whenever the process is headless — never a silent success.
    @discardableResult
    func apply(enabled: Bool) -> Bool {
        guard !AppEnvironment.isHeadless else {
            // A development tool must not put an icon in the user's menu bar.
            return false
        }
        if enabled, statusItem == nil {
            install()
        } else if !enabled, statusItem != nil {
            remove()
        }
        return isInstalled
    }

    private func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "square.grid.3x3.fill",
            accessibilityDescription: "OpenDeck"
        )
        item.menu = buildMenu()
        statusItem = item
    }

    private func remove() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let open = NSMenuItem(title: "Open OpenDeck", action: #selector(openDeck), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit OpenDeck", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // MARK: - Menu actions

    /// Posted rather than called directly: the deck's window controller belongs
    /// to `AppDelegate`, and reaching for it from here would give the menu bar a
    /// second owner of the same window.
    @objc private func openDeck() {
        NotificationCenter.default.post(name: .deckMenuBarOpen, object: nil)
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .deckOpenSettings, object: nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
