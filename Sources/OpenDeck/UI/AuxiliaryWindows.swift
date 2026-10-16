import AppKit
import SwiftUI

/// Holds a weak window reference so a view closure can dismiss its own window.
private final class WindowBox {
    weak var window: NSWindow?
}

/// Which window level the settings window should sit at.
///
/// Opening settings is **not** leaving the deck. LaunchOS's `openPreferences`
/// (`0x10011f650`) only dispatches its preferences window through
/// `MenuBarManager`; nothing hides the launchpad, so the deck stays on screen
/// and the settings window has to be placed **above** it. The deck's level is a
/// hair under the dragging level (499) and it is full-screen, so a `.normal`
/// settings window would simply be invisible behind it.
///
/// Pure, so the rule is driven by plain numbers instead of a window server —
/// the same reason `DeckClickState` and `PagingState` exist.
enum SettingsPanelLevel {
    /// `nil` means "leave the window at the default level": with no deck on
    /// screen there is nothing to be above (the menu-bar route opens settings
    /// with the deck already away).
    static func resolve(deckVisible: Bool, deckLevel: NSWindow.Level) -> NSWindow.Level? {
        guard deckVisible else { return nil }
        return NSWindow.Level(rawValue: deckLevel.rawValue + 1)
    }
}

/// Hosts the settings window.
///
/// An `NSObject` because it is the window's delegate: `NSWindowDelegate` is an
/// `NSObjectProtocol`, so the conformance cannot be declared on a plain Swift
/// class.
@MainActor
final class SettingsWindowController: NSObject {
    private var window: NSWindow?
    private let store: DeckStore
    private let settings: DeckSettings
    private let vm = SettingsViewModel()

    /// Runs when the settings window is closed by the user. The deck stays up
    /// behind it (report 47), so it has to take the keyboard back afterwards.
    var onClose: (() -> Void)?

    init(store: DeckStore, settings: DeckSettings) {
        self.store = store
        self.settings = settings
        super.init()
    }

    /// Shows the settings window. `level` comes from `SettingsPanelLevel` — it
    /// is non-nil exactly when the deck is on screen and the panel has to be
    /// raised above it.
    func show(above level: NSWindow.Level? = nil) {
        if let window {
            window.level = level ?? .normal
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let root = SettingsView(store: store, settings: settings, vm: vm)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(x: 0, y: 0, width: 540, height: 640)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenDeck Settings"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.level = level ?? .normal
        window.delegate = self
        window.center()

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

extension SettingsWindowController: NSWindowDelegate {
    /// The red button — and only the red button. Our own `close()` uses
    /// `orderOut`, which never reports here, which is what we want: the deck
    /// only needs the keyboard back when the user actually dismisses settings.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            window = nil
            onClose?()
        }
    }
}

/// The level the uninstall confirmation panel sits at (report 51).
///
/// **Not `.floating`.** The panel is opened from the deck's own context menu, so
/// the deck it was opened from is still on screen behind it — at
/// `LaunchpadWindowController.deckWindowLevel` (499), which is above `.floating`
/// (3). At `.floating` the panel the user had just asked for was drawn *under*
/// the window they asked from it.
///
/// LaunchOS solves the same problem the same way. Its presenter (`0x1000246e0`,
/// and the identical idiom at `0x10001d600` and `0x100023500`) ends with
/// `mov w8, #0x3e8` (1000) and `mov w8, #0x1` feeding `NSWindow.Level.+`, then
/// `setLevel:` at `0x1000248ac` — i.e. `.screenSaver + 1`: a fixed level above
/// everything, not "floats a little".
///
/// These panels also do **not** take the launchpad down: LaunchOS's
/// `-[UninstallWindowController windowWillClose:]` (`0x100024a54` → `0x10002497c`)
/// only clears the delegate, the content view and the window. Had the launchpad
/// been hidden for the panel, closing it would leave the user on a bare desktop
/// with nothing to come back to — which is exactly the trap OpenDeck fell into.
enum UninstallPanelLevel {
    /// `.screenSaver + 1` — the value LaunchOS writes, measured.
    static let panel: NSWindow.Level = .screenSaver + 1
}

/// Hosts a one-off uninstall confirmation window per app.
@MainActor
final class UninstallWindowController {
    private var windows: [NSWindow] = []

    /// Runs when a panel is dismissed. The deck stays up behind it (report 51),
    /// so it has to take the keyboard back afterwards — the same contract as
    /// `SettingsWindowController.onClose`.
    var onClose: (() -> Void)?

    init(store: DeckStore) {
        _ = store
    }

    func show(app: AppInfo) {
        let vm = UninstallViewModel(app: app)
        vm.scan()

        let box = WindowBox()
        let root = UninstallView(vm: vm) { [weak self, weak box] in
            guard let window = box?.window else { return }
            window.orderOut(nil)
            self?.windows.removeAll { $0 === window }
            self?.onClose?()
        }

        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(x: 0, y: 0, width: 520, height: 420)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Uninstall \(app.name)"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        // Above the deck, which is where this panel is opened from (report 51).
        window.level = UninstallPanelLevel.panel
        box.window = window

        windows.append(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
