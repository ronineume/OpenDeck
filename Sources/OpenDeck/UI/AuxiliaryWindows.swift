import AppKit
import SwiftUI

/// Holds a weak window reference so a view closure can dismiss its own window.
private final class WindowBox {
    weak var window: NSWindow?
}

/// Hosts the settings window.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let store: DeckStore
    private let settings: DeckSettings
    private let vm = SettingsViewModel()

    init(store: DeckStore, settings: DeckSettings) {
        self.store = store
        self.settings = settings
    }

    func show() {
        if let window {
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

/// Hosts a one-off uninstall confirmation window per app.
@MainActor
final class UninstallWindowController {
    private var windows: [NSWindow] = []

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
        window.level = .floating
        box.window = window

        windows.append(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
