import AppKit
import ServiceManagement

/// The half of `UserDefaults` this file uses.
///
/// A protocol so the self-test can hand `Preferences` a plain dictionary.
/// Exercising the guard through a real preferences domain would mean inventing a
/// file in `~/Library/Preferences` in order to assert that nothing is written to
/// it — the litter the guard exists to stop.
protocol PreferenceStore: AnyObject {
    func set(_ value: Any?, forKey key: String)
    func object(forKey key: String) -> Any?
    func string(forKey key: String) -> String?
    func double(forKey key: String) -> Double
    func bool(forKey key: String) -> Bool
    func integer(forKey key: String) -> Int
    func register(defaults: [String: Any])
}

extension UserDefaults: PreferenceStore {}

/// Preferences with every write dropped while running headless.
///
/// The guard sits in front of the store rather than at the call sites: every
/// property below writes itself back through its `didSet`, and the initialiser
/// writes too, so twenty-odd scattered conditions would be twenty-odd chances to
/// miss one. Behind this single point a headless process cannot write a
/// preference even by accident — the same guarantee `DeckStore` gets from being
/// handed an explicit `storeURL`.
///
/// Reads are deliberately **not** gated: `--snapshot` renders the real settings,
/// and gating reads would make the picture it produces a lie. `register` is not
/// gated either — a registration is in-memory only, and the reads depend on it.
struct Preferences {
    let persists: Bool
    let store: PreferenceStore

    func set(_ value: Any?, forKey key: String) {
        guard persists else { return }
        store.set(value, forKey: key)
    }

    func object(forKey key: String) -> Any? { store.object(forKey: key) }
    func string(forKey key: String) -> String? { store.string(forKey: key) }
    func double(forKey key: String) -> Double { store.double(forKey: key) }
    func bool(forKey key: String) -> Bool { store.bool(forKey: key) }
    func integer(forKey key: String) -> Int { store.integer(forKey: key) }
    func register(defaults: [String: Any]) { store.register(defaults: defaults) }
}

/// The activation policy that matches the user's Dock-icon choice.
///
/// `.accessory` removes the Dock icon; `.regular` restores it. The deck is a
/// borderless overlay with no menu bar of its own, so dropping to `.accessory`
/// costs nothing — `--bench` and `--snapshot` already run that way.
enum DockIconPolicy {
    static func policy(showDockIcon: Bool) -> NSApplication.ActivationPolicy {
        showDockIcon ? .regular : .accessory
    }

    /// Makes sure at least one way out of the app stays on.
    ///
    /// OpenDeck is a borderless overlay with no menu bar of its own, and with no
    /// window open Cmd-Q has nothing to reach. Turning off *both* the Dock icon
    /// and the menu bar icon therefore leaves no way to quit from the UI at all:
    /// not an inconvenience, a trap — and one the two toggles reach in two clicks,
    /// because the menu bar icon is off by default.
    ///
    /// Only that impossible pair is touched. The Dock-icon choice is left exactly
    /// as the user set it, and the menu bar icon is the one that comes back,
    /// because it is the quieter of the two.
    static func resolveIcons(showDockIcon: Bool,
                             showMenuBarIcon: Bool) -> (dock: Bool, menuBar: Bool) {
        if showDockIcon || showMenuBarIcon { return (showDockIcon, showMenuBarIcon) }
        return (showDockIcon, true)
    }
}

/// App-level preferences, persisted in UserDefaults.
///
/// Layout (pages, folders, sort) lives in `DeckStore`; this holds everything
/// that is not part of the grid layout itself.
final class DeckSettings: ObservableObject {
    static let shared = DeckSettings()

    private enum Key {
        static let backdropMode = "backdropMode"
        static let dimStrength = "dimStrength"
        static let blurRadius = "blurRadius"
        static let pinnedWallpaperPath = "pinnedWallpaperPath"
        static let glassMaterial = "glassMaterial"
        static let gridPreset = "gridPreset"
        static let iconScale = "iconScale"
        static let showDockIcon = "showDockIcon"
        static let screenPolicy = "screenPolicy"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let hotKeyEnabled = "hotKeyEnabled"
        static let pinchEnabled = "pinchEnabled"
        static let launchpadKeyEnabled = "launchpadKeyEnabled"
        static let showHiddenInSearch = "showHiddenInSearch"
        static let showLabels = "showLabels"
        static let holdOptionForUninstall = "holdOptionForUninstall"
        /// LaunchOS `displayMode` (report 56 §5).
        static let displayMode = "displayMode"
        /// LaunchOS `browsingStyle` (report 56 §6).
        static let browsingStyle = "browsingStyle"
        static let hotCorner = "hotCorner"
        static let hideDock = "hideDock"
        static let returnToHome = "returnToHome"
        /// The old boolean this replaced. Still **read** — see
        /// `migratedReturnToHome` — but never written.
        static let resumeLastPage = "resumeLastPage"
        static let lastPage = "lastPage"
        static let lastPageLeftAt = "lastPageLeftAt"
        static let startAtLogin = "startAtLogin"
        static let showMenuBarIcon = "showMenuBarIcon"
        /// The Reorganize sheet's rule set (report 53). LaunchOS persists the
        /// same five `Organize*` keys (`bin-strings.txt`: `OrganizePageScope`,
        /// `OrganizeAppleAppPlacement`, `OrganizeFolderPlacement`,
        /// `OrganizeSortMethod`, `OrganizeSortDirection`) so the sheet reopens
        /// on the rules the user last used. The page *selection* is session
        /// state — deliberately not persisted.
        static let organizePageScope = "OrganizePageScope"
        static let organizeAcrossPages = "OrganizeAcrossPages"
        static let organizeAppleAppPlacement = "OrganizeAppleAppPlacement"
        static let organizeFolderPlacement = "OrganizeFolderPlacement"
        static let organizeSortMethod = "OrganizeSortMethod"
        static let organizeSortDirection = "OrganizeSortDirection"
        static let organizeAlsoSortInFolders = "OrganizeAlsoSortInFolders"
        static let organizeUngroupAllFolders = "OrganizeUngroupAllFolders"
    }

    /// Named `defaults` on purpose: every existing call site reads exactly as it
    /// did, so none of them can have bypassed the guard by being missed.
    private let defaults = Preferences(
        persists: !AppEnvironment.isHeadless,
        store: UserDefaults.standard
    )

    /// Whether this process may change state that outlives it.
    ///
    /// One predicate for both the preferences domain and the login item, so a
    /// later edit cannot gate one of the two and forget the other. Checked by the
    /// self-test, which is what proves `AppEnvironment.isHeadless` really reaches
    /// this object rather than merely being set.
    var mayPersist: Bool { defaults.persists }

    /// What sits behind the grid.
    @Published var backdropMode: BackdropMode {
        didSet {
            defaults.set(backdropMode.rawValue, forKey: Key.backdropMode)
            WallpaperProvider.invalidate()
        }
    }

    /// How dark the backdrop scrim is.
    @Published var dimStrength: Double {
        didSet { defaults.set(dimStrength, forKey: Key.dimStrength) }
    }

    /// Blur applied to a backdrop image the user pinned themselves.
    ///
    /// Deliberately applies to the **pinned image only**. The desktop picture is
    /// never blurred here — the `.glass` backdrop gets its frost from the system
    /// material instead (see `GlassMaterial`), which stays in sync with a
    /// wallpaper the system is free to change.
    @Published var blurRadius: Double {
        didSet { defaults.set(blurRadius, forKey: Key.blurRadius) }
    }

    /// Image used by `.custom`.
    @Published var pinnedWallpaperPath: String? {
        didSet { defaults.set(pinnedWallpaperPath, forKey: Key.pinnedWallpaperPath) }
    }

    /// Which frosted-glass tier the backdrop uses.
    @Published var glassMaterial: GlassMaterial {
        didSet { defaults.set(glassMaterial.rawValue, forKey: Key.glassMaterial) }
    }

    /// How many columns and rows a page offers.
    ///
    /// Read by the window controller each time the deck is shown, so a change
    /// takes effect on the next open — and flows through `DeckStore.metrics`,
    /// whose `didSet` repacks the pages when the capacity differs.
    @Published var gridPreset: GridPreset {
        didSet { defaults.set(gridPreset.rawValue, forKey: Key.gridPreset) }
    }

    /// How much larger or smaller the user wants app icons than the derived size.
    ///
    /// Multiplies the display-derived icon size (see `IconScale`), which is why
    /// the range is clamped rather than trusted. Read by the window controller
    /// each time the deck is shown, so a change lands on the next open.
    @Published var iconScale: Double {
        didSet { defaults.set(iconScale, forKey: Key.iconScale) }
    }

    /// Whether the app keeps a Dock icon.
    ///
    /// On by default: an overlay with no Dock icon and no menu bar icon would be
    /// impossible to quit from the UI. Applies immediately (`applyDockIcon`).
    @Published var showDockIcon: Bool {
        didSet {
            defaults.set(showDockIcon, forKey: Key.showDockIcon)
            applyDockIcon()
        }
    }

    /// Which screen the deck opens on.
    ///
    /// Read every time the deck is shown (`LaunchpadWindowController.targetScreen`)
    /// and deliberately not observed: unlike the hot key there is no registration
    /// to redo, so a change simply lands on the next open.
    @Published var screenPolicy: ScreenPolicy {
        didSet { defaults.set(screenPolicy.rawValue, forKey: Key.screenPolicy) }
    }

    @Published var hotKeySpec: HotKeySpec? {
        didSet {
            if let hotKeySpec {
                defaults.set(Int(hotKeySpec.keyCode), forKey: Key.hotKeyCode)
                defaults.set(Int(hotKeySpec.modifiers), forKey: Key.hotKeyModifiers)
            }
            defaults.set(hotKeySpec != nil, forKey: Key.hotKeyEnabled)
        }
    }

    @Published var pinchEnabled: Bool {
        didSet { defaults.set(pinchEnabled, forKey: Key.pinchEnabled) }
    }

    @Published var launchpadKeyEnabled: Bool {
        didSet { defaults.set(launchpadKeyEnabled, forKey: Key.launchpadKeyEnabled) }
    }

    @Published var showHiddenInSearch: Bool {
        didSet { defaults.set(showHiddenInSearch, forKey: Key.showHiddenInSearch) }
    }

    /// Show app names under the icons.
    @Published var showLabels: Bool {
        didSet { defaults.set(showLabels, forKey: Key.showLabels) }
    }

    /// Hold Option and click an app to enter uninstall mode (report 56 §4).
    ///
    /// Off by default: it changes what a plain click does, and a user who
    /// never asked for it must not lose app launches to a held Option.
    @Published var holdOptionForUninstall: Bool {
        didSet { defaults.set(holdOptionForUninstall, forKey: Key.holdOptionForUninstall) }
    }

    /// Screen corner that opens the deck.
    @Published var hotCorner: HotCorner {
        didSet { defaults.set(hotCorner.rawValue, forKey: Key.hotCorner) }
    }

    /// How long the deck remembers the page it was on.
    ///
    /// Supersedes the old `resumeLastPage` boolean, which could only say "always
    /// resume" or "never resume". Read by the window controller every time the
    /// deck is shown.
    @Published var returnToHome: ReturnToHome {
        didSet { defaults.set(returnToHome.rawValue, forKey: Key.returnToHome) }
    }

    /// The page the deck was last on. Not published: nothing renders from it.
    var lastPage: Int {
        get { defaults.integer(forKey: Key.lastPage) }
        set { defaults.set(newValue, forKey: Key.lastPage) }
    }

    /// When the deck was last dismissed. Not published: nothing renders from it.
    ///
    /// Stored as a `Date`, a type `UserDefaults` round-trips natively, rather
    /// than as a "now" interval, so a reboot does not poison it.
    var lastPageLeftAt: Date? {
        get { defaults.object(forKey: Key.lastPageLeftAt) as? Date }
        set { defaults.set(newValue, forKey: Key.lastPageLeftAt) }
    }

    /// The new spelling of the old `resumeLastPage` boolean.
    ///
    /// Consulted only when `returnToHome` has never been written. `true` meant
    /// "resume where I left off", which is now the untimed `never`; `false` meant
    /// "always go home", which is now `always`.
    static func migratedReturnToHome(fromLegacyResume legacy: Bool) -> ReturnToHome {
        legacy ? .never : .always
    }

    /// Hide the Dock while the deck is open, as Launchpad does.
    @Published var hideDock: Bool {
        didSet { defaults.set(hideDock, forKey: Key.hideDock) }
    }

    /// Whether the deck covers the screen or sits in a window (report 56 §5).
    ///
    /// Read when the window is built, so a change lands the next time the deck
    /// opens — the same contract `gridPreset` and `iconScale` keep.
    @Published var displayMode: DisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: Key.displayMode) }
    }

    /// Whether the deck pages or scrolls (report 56 §6). Same contract as
    /// `displayMode`: read when the deck is shown.
    @Published var browsingStyle: BrowsingStyle {
        didSet { defaults.set(browsingStyle.rawValue, forKey: Key.browsingStyle) }
    }

    /// Whether a status item lives in the menu bar.
    ///
    /// Off by default: the app already owns a Dock icon, and an icon appearing in
    /// the menu bar for every existing install without being asked for would be
    /// an unrequested change to their screen.
    @Published var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) }
    }

    @Published var startAtLogin: Bool {
        didSet {
            defaults.set(startAtLogin, forKey: Key.startAtLogin)
            applyStartAtLogin()
        }
    }

    /// The Reorganize sheet's rule set, persisted across launches (report 53).
    ///
    /// `selectedPages` is deliberately **not** part of this: it is a choice
    /// about the current layout, and a stale selection would silently
    /// reorganize pages the user no longer has.
    var organizeOptions: OrganizeOptions {
        get {
            var o = OrganizeOptions()
            o.pageScope = OrganizePageScope(
                rawValue: defaults.string(forKey: Key.organizePageScope) ?? ""
            ) ?? .allPages
            o.acrossPages = defaults.object(forKey: Key.organizeAcrossPages) as? Bool ?? true
            o.appleAppPlacement = AppleAppPlacement(
                rawValue: defaults.string(forKey: Key.organizeAppleAppPlacement) ?? ""
            ) ?? .afterOtherApps
            o.folderPlacement = FolderPlacement(
                rawValue: defaults.string(forKey: Key.organizeFolderPlacement) ?? ""
            ) ?? .afterApps
            o.sortMethod = SortKey(
                rawValue: defaults.string(forKey: Key.organizeSortMethod) ?? ""
            ) ?? .name
            o.sortDirection = SortOrder(
                rawValue: defaults.string(forKey: Key.organizeSortDirection) ?? ""
            ) ?? .ascending
            o.alsoSortInFolders = defaults.bool(forKey: Key.organizeAlsoSortInFolders)
            o.ungroupAllFolders = defaults.bool(forKey: Key.organizeUngroupAllFolders)
            return o
        }
        set {
            defaults.set(newValue.pageScope.rawValue, forKey: Key.organizePageScope)
            defaults.set(newValue.acrossPages, forKey: Key.organizeAcrossPages)
            defaults.set(newValue.appleAppPlacement.rawValue, forKey: Key.organizeAppleAppPlacement)
            defaults.set(newValue.folderPlacement.rawValue, forKey: Key.organizeFolderPlacement)
            defaults.set(newValue.sortMethod.rawValue, forKey: Key.organizeSortMethod)
            defaults.set(newValue.sortDirection.rawValue, forKey: Key.organizeSortDirection)
            defaults.set(newValue.alsoSortInFolders, forKey: Key.organizeAlsoSortInFolders)
            defaults.set(newValue.ungroupAllFolders, forKey: Key.organizeUngroupAllFolders)
        }
    }

    /// Human readable status for the settings window.
    @Published var startAtLoginError: String?

    /// Set when the application-folder watcher could not start, which silently
    /// degrades syncing to "scan once at launch". Not persisted: recomputed on
    /// every launch.
    @Published var appWatcherError: String?

    /// Plain-language note that the on-disk layout had to be recovered, was
    /// preserved as a sibling file, or that saving is disabled for this session
    /// (the data-safety load paths). Not persisted: recomputed on every launch.
    @Published var layoutHealthMessage: String?

    private init() {
        // Hand the pre-rename preferences over before anything else in here.
        //
        // Every `@Published` property below carries a `didSet` that writes back
        // to `defaults`, and `hotKeySpec` is assigned a spec built from the
        // registration defaults — so a process that constructs this object
        // before the handover has run stamps the built-in defaults into the new
        // domain. `--selftest` does exactly that: it builds a
        // `LaunchpadViewModel`, which reads `DeckSettings.shared`. The handover
        // would then find those keys already present, skip them, and quietly
        // replace the user's own hot key with the default one.
        let carried = StateHandover.preferencesToCarryOver()
        for (key, value) in carried { defaults.set(value, forKey: key) }
        if !carried.isEmpty {
            NSLog("OpenDeck: took over %d preference(s) from the pre-rename install", carried.count)
        }

        defaults.register(defaults: [
            Key.backdropMode: BackdropMode.glass.rawValue,
            Key.dimStrength: 0.18,
            Key.blurRadius: 26.0,
            Key.glassMaterial: GlassMaterial.regular.rawValue,
            Key.gridPreset: GridPreset.macOSDefault.rawValue,
            Key.iconScale: 1.0,
            Key.showDockIcon: true,
            Key.screenPolicy: ScreenPolicy.pointer.rawValue,
            Key.hotKeyEnabled: true,
            Key.hotKeyCode: Int(HotKeySpec.optionSpace.keyCode),
            Key.hotKeyModifiers: Int(HotKeySpec.optionSpace.modifiers),
            Key.pinchEnabled: false,
            Key.launchpadKeyEnabled: false,
            Key.showHiddenInSearch: false,
            Key.showLabels: true,
            Key.holdOptionForUninstall: false,
            Key.displayMode: DisplayMode.fullScreen.rawValue,
            Key.browsingStyle: BrowsingStyle.paged.rawValue,
            Key.hotCorner: HotCorner.off.rawValue,
            Key.hideDock: false,
            // `returnToHome` is deliberately NOT registered here: a registered
            // default is returned by `string(forKey:)` too, which would make the
            // migration below unable to tell "the user chose this" from "nobody
            // ever wrote it" — and an install that had `resumeLastPage == false`
            // would silently lose that choice. The fallback chain in `init`
            // supplies the default instead. The old boolean stays registered
            // because the migration reads it.
            Key.resumeLastPage: true,
            Key.lastPage: 0,
            Key.startAtLogin: false,
            Key.showMenuBarIcon: false,
        ])

        backdropMode = BackdropMode(rawValue: defaults.string(forKey: Key.backdropMode) ?? "") ?? .glass
        dimStrength = defaults.double(forKey: Key.dimStrength)
        blurRadius = defaults.double(forKey: Key.blurRadius)
        pinnedWallpaperPath = defaults.string(forKey: Key.pinnedWallpaperPath)
        glassMaterial = GlassMaterial(rawValue: defaults.string(forKey: Key.glassMaterial) ?? "") ?? .regular
        gridPreset = GridPreset(rawValue: defaults.string(forKey: Key.gridPreset) ?? "") ?? .macOSDefault
        // Both are registered above, so an install that predates them keeps the
        // old behaviour (unscaled icons, Dock icon shown) rather than reading a
        // zero out of an absent key.
        iconScale = defaults.double(forKey: Key.iconScale)
        showDockIcon = defaults.bool(forKey: Key.showDockIcon)
        screenPolicy = ScreenPolicy(rawValue: defaults.string(forKey: Key.screenPolicy) ?? "") ?? .pointer
        pinchEnabled = defaults.bool(forKey: Key.pinchEnabled)
        launchpadKeyEnabled = defaults.bool(forKey: Key.launchpadKeyEnabled)
        showHiddenInSearch = defaults.bool(forKey: Key.showHiddenInSearch)
        showLabels = defaults.bool(forKey: Key.showLabels)
        holdOptionForUninstall = defaults.bool(forKey: Key.holdOptionForUninstall)
        displayMode = DisplayMode(rawValue: defaults.string(forKey: Key.displayMode) ?? "") ?? .fullScreen
        browsingStyle = BrowsingStyle(rawValue: defaults.string(forKey: Key.browsingStyle) ?? "") ?? .paged
        hotCorner = HotCorner(rawValue: defaults.string(forKey: Key.hotCorner) ?? "") ?? .off
        hideDock = defaults.bool(forKey: Key.hideDock)
        // `returnToHome` wins whenever it has been written; the old boolean is the
        // fallback, so an install that predates the policy keeps the behaviour it
        // actually had rather than being reset to a default.
        returnToHome = ReturnToHome(rawValue: defaults.string(forKey: Key.returnToHome) ?? "")
            ?? Self.migratedReturnToHome(fromLegacyResume: defaults.bool(forKey: Key.resumeLastPage))
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
        startAtLogin = defaults.bool(forKey: Key.startAtLogin)

        if defaults.bool(forKey: Key.hotKeyEnabled) {
            hotKeySpec = HotKeySpec(
                keyCode: UInt32(defaults.integer(forKey: Key.hotKeyCode)),
                modifiers: UInt32(defaults.integer(forKey: Key.hotKeyModifiers))
            )
        } else {
            hotKeySpec = nil
        }
    }

    /// Puts the Dock icon in the state the user chose.
    ///
    /// Like `applyStartAtLogin`, this is a real change to the user's system, so a
    /// headless run must not make it — and must say so by returning `false`
    /// rather than pretending to have done it. Same contract as
    /// `MenuBarController.apply`.
    @discardableResult
    func applyDockIcon() -> Bool {
        guard mayPersist else { return false }
        NSApp.setActivationPolicy(DockIconPolicy.policy(showDockIcon: showDockIcon))
        return true
    }

    private func applyStartAtLogin() {
        // `init` assigns `startAtLogin` like any other property, so a headless
        // run reaches this and calls `SMAppService` — registering or
        // unregistering a login item. That is a real change to the user's system,
        // and a self-test has no business making one.
        guard mayPersist else { return }
        do {
            if startAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            startAtLoginError = nil
        } catch {
            startAtLoginError = error.localizedDescription
            NSLog("OpenDeck: start at login failed: \(error)")
        }
    }
}
