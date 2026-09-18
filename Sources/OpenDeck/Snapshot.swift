import AppKit
import SwiftUI

/// Renders the deck to a PNG without needing Screen Recording permission.
///
/// This is a development aid: `OpenDeck --snapshot <path>` builds the real
/// view hierarchy, lets SwiftUI settle, then caches the layer to a bitmap.
enum SnapshotRunner {
    @MainActor
    static func run(outputPath: String) {
        // No desktop exists behind an offscreen render, so the backdrop draws
        // the wallpaper image instead of using the behind-window material.
        AppEnvironment.isOffscreenRender = true
        // `--folder-start` freezes the folder animation on its first frame so a
        // snapshot can prove the panel starts on top of the icon.
        AppEnvironment.freezeFolderAnimation = CommandLine.arguments.contains("--folder-start")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let store = DeckStore(readOnly: true)
        store.reloadApps()

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let metrics = GridMetrics.make(for: screen)
        store.metrics = metrics

        let wantsSettings = CommandLine.arguments.contains("--settings")

        let hosting: NSView
        var deckVM: LaunchpadViewModel?
        if wantsSettings {
            let root = SettingsView(
                store: store,
                settings: DeckSettings.shared,
                vm: SettingsViewModel()
            )
            let view = NSHostingView(rootView: root)
            view.frame = CGRect(x: 0, y: 0, width: 540, height: 640)
            hosting = view
        } else {
            let vm = LaunchpadViewModel(store: store)
            if let queryIndex = CommandLine.arguments.firstIndex(of: "--query"),
               queryIndex + 1 < CommandLine.arguments.count {
                vm.query = CommandLine.arguments[queryIndex + 1]
            }
            let root = LaunchpadView(store: store, vm: vm, metrics: metrics, screen: screen)
            let view = NSHostingView(rootView: root)
            view.frame = CGRect(origin: .zero, size: screen.frame.size)
            hosting = view
            deckVM = vm
        }
        // The hosting view must live in a window, or SwiftUI never advances
        // animations: `withAnimation` in `onAppear` would leave the folder
        // panel stuck on its first frame and the snapshot would lie.
        let snapshotWindow = NSWindow(
            contentRect: CGRect(origin: .zero, size: hosting.bounds.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        snapshotWindow.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        snapshotWindow.contentView = hosting
        snapshotWindow.orderFront(nil)

        hosting.layoutSubtreeIfNeeded()

        // Let SwiftUI run its first layout pass, so every tile has reported its
        // frame to the registry before anything tries to animate out of one.
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        hosting.layoutSubtreeIfNeeded()

        if CommandLine.arguments.contains("--open-folder"), let vm = deckVM {
            // Open a folder *after* layout, exactly as a click does, so the
            // proxy start frame comes from the registry rather than falling
            // back to a centred panel.
            let onFirstPage = store.pages.first?.compactMap { slot -> UUID? in
                if case .folder(let id) = slot { return id }
                return nil
            }.first
            if let folder = onFirstPage ?? store.folders.keys.first {
                vm.openFolder(folder)
                if let origin = vm.folderOrigin {
                    print(String(format: "proxy start frame: x=%.0f y=%.0f w=%.0f h=%.0f  (window %.0fx%.0f)",
                                 origin.minX, origin.minY, origin.width, origin.height,
                                 screen.frame.width, screen.frame.height))
                } else {
                    print("proxy start frame: MISSING — registry had no entry for the folder tile")
                }
            }
            if CommandLine.arguments.contains("--folder-rename") {
                // Enter rename mode so a snapshot can prove the panel keeps the
                // same width while the field is showing.
                vm.folderNameDraft = vm.openedFolder.flatMap { store.folder($0)?.name } ?? ""
                vm.isEditingFolderName = true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            hosting.layoutSubtreeIfNeeded()
        }

        hosting.displayIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            FileHandle.standardError.write(Data("snapshot: no bitmap rep\n".utf8))
            exit(2)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot: png encode failed\n".utf8))
            exit(3)
        }
        do {
            try png.write(to: URL(fileURLWithPath: outputPath))
            print("snapshot: wrote \(outputPath) (\(store.apps.count) apps, \(store.pages.count) pages, grid \(metrics.columns)x\(metrics.rows))")
        } catch {
            FileHandle.standardError.write(Data("snapshot: write failed \(error)\n".utf8))
            exit(4)
        }
        exit(0)
    }
}
