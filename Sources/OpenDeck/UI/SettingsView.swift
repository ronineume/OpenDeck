import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Backing state for the settings window.
final class SettingsViewModel: ObservableObject {
    @Published var hasAccessibility = Permissions.hasAccessibility
    @Published var hasFullDiskAccess = Permissions.hasFullDiskAccess
    @Published var hotKeyError: String?
    @Published var isRecordingHotKey = false
    @Published var pinchRunning = PinchMonitor.shared.isRunning
    @Published var launchpadKeyRunning = LaunchpadKeyMonitor.shared.isRunning
    @Published var statusMessage: String?
    @Published var wallpaperDetected: String?
    @Published var importMessage: String?

    private var timer: Timer?
    private var recorderMonitor: Any?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refreshWallpaperSummary()
    }

    deinit {
        timer?.invalidate()
        if let recorderMonitor { NSEvent.removeMonitor(recorderMonitor) }
    }

    func refresh() {
        hotKeyError = HotKeyManager.shared.lastError
        hasAccessibility = Permissions.hasAccessibility
        hasFullDiskAccess = Permissions.hasFullDiskAccess
        pinchRunning = PinchMonitor.shared.isRunning
        launchpadKeyRunning = LaunchpadKeyMonitor.shared.isRunning
    }

    func refreshWallpaperSummary() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            wallpaperDetected = nil
            return
        }
        wallpaperDetected = WallpaperProvider.resolve(for: screen).description
    }

    // MARK: - Hot key recording

    /// Capture the next key combination the user presses.
    func beginRecording() {
        guard recorderMonitor == nil else { return }
        isRecordingHotKey = true
        hotKeyError = nil

        recorderMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // Escape cancels without changing anything.
            if event.keyCode == 53 {
                self.endRecording()
                return nil
            }
            guard let spec = HotKeySpec.from(event: event) else {
                self.hotKeyError = "Add a modifier (⌘⌥⌃⇧), or press a function key such as F4."
                return nil
            }

            DeckSettings.shared.hotKeySpec = spec
            self.endRecording()
            NotificationCenter.default.post(name: .deckHotKeyChanged, object: nil)
            self.hotKeyError = HotKeyManager.shared.lastError
            return nil
        }
    }

    func endRecording() {
        if let recorderMonitor { NSEvent.removeMonitor(recorderMonitor) }
        recorderMonitor = nil
        isRecordingHotKey = false
    }

    func clearHotKey() {
        DeckSettings.shared.hotKeySpec = nil
        NotificationCenter.default.post(name: .deckHotKeyChanged, object: nil)
        hotKeyError = nil
    }

    // MARK: - Actions

    func chooseWallpaperImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image to use behind the deck"
        if panel.runModal() == .OK, let url = panel.url {
            DeckSettings.shared.pinnedWallpaperPath = url.path
            WallpaperProvider.invalidate()
            refreshWallpaperSummary()
        }
    }

    func followDesktopWallpaper() {
        DeckSettings.shared.pinnedWallpaperPath = nil
        WallpaperProvider.invalidate()
        refreshWallpaperSummary()
    }

    @MainActor
    func importLaunchpadLayout(into store: DeckStore) {
        guard let url = LaunchpadImporter.locateDatabase() else {
            importMessage = "No Launchpad database found on this Mac."
            return
        }
        guard let layout = LaunchpadImporter.load(from: url) else {
            importMessage = "Found \(url.path) but could not read a layout from it."
            return
        }
        let report = store.applyImported(layout)
        var message = "Imported \(report.placedApps) app(s) into \(report.pages) page(s) and \(report.folders) folder(s)."
        if !report.skipped.isEmpty {
            message += " \(report.skipped.count) not installed: \(report.skipped.prefix(4).joined(separator: ", "))."
        }
        if !report.hiddenSkipped.isEmpty {
            message += " \(report.hiddenSkipped.count) left out because they are hidden here."
        }
        importMessage = message
    }
}

struct SettingsView: View {
    @ObservedObject var store: DeckStore
    @ObservedObject var settings: DeckSettings
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                importSection
                layoutSection
                wallpaperSection
                activationSection
                hiddenAppsSection
                permissionsSection
                aboutSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 560, height: 680)
    }

    // MARK: - Import

    private var importSection: some View {
        Section2("Import Your Launchpad Layout") {
            Text("macOS keeps your old Launchpad pages and folders on disk even after Launchpad was removed. Import them to restore the exact arrangement you had before upgrading.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Import Launchpad Layout") {
                    vm.importLaunchpadLayout(into: store)
                }
                Button("Where is the database?") {
                    vm.importMessage = LaunchpadImporter.locateDatabase()?.path
                        ?? "Not found. On macOS 26 it normally lives under /private/var/folders/…/0/com.apple.dock.launchpad/db/db"
                }
                .buttonStyle(.link)
            }
            if let message = vm.importMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("Importing replaces the current arrangement. Drag icons afterwards, or use Reset Order.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Layout

    private var layoutSection: some View {
        Section2("Layout") {
            Picker("Sort By", selection: $store.sortKey) {
                ForEach(SortKey.allCases) { key in
                    Text(key.label).tag(key)
                }
            }
            .pickerStyle(.menu)
            // `sortKey`/`sortOrder` are plain `@Published` values with no `didSet`
            // and `applySort()` returns early for `.manual`, so changing a picker
            // used to update memory and the UI but never the file: the choice
            // survived only if something else happened to save before quitting.
            // Deliberately wired here rather than as a `didSet` on the property —
            // `apply(_:)` writes both during load, and a `didSet` would fire there
            // and bypass the `isLoading` guard.
            .onChange(of: store.sortKey) { _, _ in store.save() }

            Picker("Order", selection: $store.sortOrder) {
                ForEach(SortOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: store.sortOrder) { _, _ in store.save() }

            HStack(spacing: 8) {
                Button("Apply Sort") {
                    store.applySort()
                    vm.statusMessage = "Sorted by \(store.sortKey.label), \(store.sortOrder.label.lowercased())."
                }
                .disabled(store.sortKey == .manual)

                Button("Fill Gaps") {
                    store.fillEmptySlots(capacity: store.metrics.capacity)
                    vm.statusMessage = "Packed \(store.pages.count) page(s) with no gaps."
                }

                Button("Reset Order") {
                    store.restartToDefaultOrder(capacity: store.metrics.capacity)
                    vm.statusMessage = "Layout reset to alphabetical."
                }
            }

            Toggle("Show app names", isOn: $settings.showLabels)

            Picker("When reopening", selection: $settings.resumeLastPage) {
                Text("Resume where I left off").tag(true)
                Text("Return to the main page").tag(false)
            }
            .pickerStyle(.menu)

            if store.sortKey == .manual {
                Text("Drag icons to reorder. Dropping one app onto another creates a folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message = vm.statusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Wallpaper

    private var wallpaperSection: some View {
        Section2("Backdrop") {
            Picker("Style", selection: $settings.backdropMode) {
                ForEach(BackdropMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)

            Text(settings.backdropMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("Dim")
                Slider(value: $settings.dimStrength, in: 0 ... 0.55, step: 0.02)
                Text("\(Int(settings.dimStrength * 100))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }

            if settings.backdropMode == .custom {
                HStack {
                    Text("Blur")
                    Slider(value: $settings.blurRadius, in: 0 ... 90, step: 5) { editing in
                        if !editing { WallpaperProvider.invalidate() }
                    }
                    Text("\(Int(settings.blurRadius))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .trailing)
                }
                HStack(spacing: 8) {
                    Button("Choose Image…") { vm.chooseWallpaperImage() }
                    if settings.pinnedWallpaperPath != nil {
                        Button("Clear") {
                            settings.pinnedWallpaperPath = nil
                            settings.backdropMode = .glass
                            WallpaperProvider.invalidate()
                        }
                    }
                }
                if let pinned = settings.pinnedWallpaperPath {
                    Text("Pinned: \((pinned as NSString).lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("The system material samples the real desktop behind the window, so the backdrop always matches your wallpaper exactly — including a shuffling album.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let summary = vm.wallpaperDetected {
                Text("Desktop picture: \(summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Activation

    private var activationSection: some View {
        Section2("Activation") {
            HStack(spacing: 8) {
                Text("Shortcut").font(.system(size: 12))
                Spacer()
                Button {
                    vm.isRecordingHotKey ? vm.endRecording() : vm.beginRecording()
                } label: {
                    Text(vm.isRecordingHotKey
                         ? "Press keys… (Esc cancels)"
                         : (settings.hotKeySpec?.displayString ?? "Off"))
                        .frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent)
                .tint(vm.isRecordingHotKey ? .orange : .accentColor)
            }

            HStack(spacing: 6) {
                ForEach(HotKeySpec.presets, id: \.0) { label, spec in
                    Button(label) {
                        DeckSettings.shared.hotKeySpec = spec
                        NotificationCenter.default.post(name: .deckHotKeyChanged, object: nil)
                    }
                    .font(.system(size: 11))
                }
                Button("Off") { vm.clearHotKey() }
                    .font(.system(size: 11))
            }

            if let error = vm.hotKeyError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text("Click the field and press the combination you want — F4 works on its own, other keys need a modifier.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Respond to the keyboard's Launchpad key", isOn: $settings.launchpadKeyEnabled)
                .onChange(of: settings.launchpadKeyEnabled) { _, _ in
                    NotificationCenter.default.post(name: .deckLaunchpadKeyChanged, object: nil)
                }
            if settings.launchpadKeyEnabled && !vm.hasAccessibility {
                Text("Needs Accessibility permission — see below. F4 above works without it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Toggle("Pinch in on the trackpad to open", isOn: $settings.pinchEnabled)
                .onChange(of: settings.pinchEnabled) { _, _ in
                    NotificationCenter.default.post(name: .deckPinchChanged, object: nil)
                }
            Text("Fires for any finger count: macOS exposes pinch magnification but not how many fingers were used.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Picker("Open from a screen corner", selection: $settings.hotCorner) {
                ForEach(HotCorner.allCases) { corner in
                    Text(corner.label).tag(corner)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: settings.hotCorner) { _, _ in
                NotificationCenter.default.post(name: .deckHotCornerChanged, object: nil)
            }
            if settings.hotCorner.isEnabled {
                Text("System Settings → Desktop & Dock → Hot Corners can fight with this. A corner only opens the deck; it never closes one already on screen.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Toggle("Hide the Dock while the deck is open", isOn: $settings.hideDock)
        }
    }

    // MARK: - Hidden apps

    private var hiddenAppsSection: some View {
        let hidden = store.hiddenApps
        return Section2("Hidden Apps (\(hidden.count))") {
            Toggle("Also show hidden apps in search results", isOn: $settings.showHiddenInSearch)

            if hidden.isEmpty {
                Text("Right-click any app in the deck to hide it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(hidden.prefix(12), id: \.id) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: app.icon)
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(app.name).font(.system(size: 12))
                            Spacer()
                            Button("Unhide") { store.setHidden(app.id, false) }
                                .buttonStyle(.link)
                        }
                    }
                }
                if hidden.count > 12 {
                    Text("and \(hidden.count - 12) more…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Section2("Permissions") {
            HStack(spacing: 8) {
                Image(systemName: vm.hasAccessibility ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(vm.hasAccessibility ? .green : .secondary)
                Text("Accessibility — only needed for the Launchpad key")
                    .font(.system(size: 12))
                Spacer()
                if !vm.hasAccessibility {
                    Button("Open Settings") { Permissions.openAccessibilitySettings() }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: vm.hasFullDiskAccess ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(vm.hasFullDiskAccess ? .green : .secondary)
                Text("Full Disk Access — required to uninstall apps cleanly")
                    .font(.system(size: 12))
                Spacer()
                if !vm.hasFullDiskAccess {
                    Button("Open Settings") { Permissions.openFullDiskAccessSettings() }
                }
            }

            Toggle("Start at login", isOn: $settings.startAtLogin)
            if let error = settings.startAtLoginError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if let error = settings.appWatcherError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if let health = settings.layoutHealthMessage {
                Text(health).font(.caption).foregroundStyle(.orange)
            }
            // `store.lastError` is written by `save()` failures *and* by
            // `recordDataRepair` (benign repairs), and until now nothing rendered
            // it: a failed write was completely invisible, so a deck that kept
            // accepting drags looked like it was saving them. Shown after the
            // health line and skipped when it is the same string, so one incident
            // is not announced twice.
            if let error = store.lastError, error != settings.layoutHealthMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    /// Read from the bundle rather than written out by hand here: the two used
    /// to disagree — `Info.plist` said 0.1.0 while this line said 0.2.0.
    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private var aboutSection: some View {
        Section2("About") {
            Text("OpenDeck \(Self.version) — a local Launchpad replacement.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Layout file: ~/Library/Application Support/OpenDeck/layout.json")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

/// A titled group of rows, standing in for a Form section.
struct Section2<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
        }
    }
}

extension Notification.Name {
    static let deckHotKeyChanged = Notification.Name("OpenDeck.hotKeyChanged")
    static let deckPinchChanged = Notification.Name("OpenDeck.pinchChanged")
    static let deckLaunchpadKeyChanged = Notification.Name("OpenDeck.launchpadKeyChanged")
    static let deckHotCornerChanged = Notification.Name("OpenDeck.hotCornerChanged")
    /// Posted when the deck is shown, asking for a throttled rescan of the
    /// application folders (a safety net for a missed FSEvents event).
    static let deckRescanRequested = Notification.Name("OpenDeck.rescanRequested")
}
