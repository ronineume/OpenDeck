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
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let hotKeyEnabled = "hotKeyEnabled"
        static let pinchEnabled = "pinchEnabled"
        static let launchpadKeyEnabled = "launchpadKeyEnabled"
        static let showHiddenInSearch = "showHiddenInSearch"
        static let showLabels = "showLabels"
        static let hotCorner = "hotCorner"
        static let hideDock = "hideDock"
        static let resumeLastPage = "resumeLastPage"
        static let lastPage = "lastPage"
        static let startAtLogin = "startAtLogin"
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

    /// Blur applied to a custom backdrop image.
    @Published var blurRadius: Double {
        didSet { defaults.set(blurRadius, forKey: Key.blurRadius) }
    }

    /// Image used by `.custom`.
    @Published var pinnedWallpaperPath: String? {
        didSet { defaults.set(pinnedWallpaperPath, forKey: Key.pinnedWallpaperPath) }
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

    /// Screen corner that opens the deck.
    @Published var hotCorner: HotCorner {
        didSet { defaults.set(hotCorner.rawValue, forKey: Key.hotCorner) }
    }

    /// Resume on the page you left off on, instead of returning to page one.
    /// LaunchOS exposes this as "Saved State" vs "Return To Main Page".
    @Published var resumeLastPage: Bool {
        didSet { defaults.set(resumeLastPage, forKey: Key.resumeLastPage) }
    }

    /// The page the deck was last on. Not published: nothing renders from it.
    var lastPage: Int {
        get { defaults.integer(forKey: Key.lastPage) }
        set { defaults.set(newValue, forKey: Key.lastPage) }
    }

    /// Hide the Dock while the deck is open, as Launchpad does.
    @Published var hideDock: Bool {
        didSet { defaults.set(hideDock, forKey: Key.hideDock) }
    }

    @Published var startAtLogin: Bool {
        didSet {
            defaults.set(startAtLogin, forKey: Key.startAtLogin)
            applyStartAtLogin()
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
            Key.hotKeyEnabled: true,
            Key.hotKeyCode: Int(HotKeySpec.optionSpace.keyCode),
            Key.hotKeyModifiers: Int(HotKeySpec.optionSpace.modifiers),
            Key.pinchEnabled: false,
            Key.launchpadKeyEnabled: false,
            Key.showHiddenInSearch: false,
            Key.showLabels: true,
            Key.hotCorner: HotCorner.off.rawValue,
            Key.hideDock: false,
            Key.resumeLastPage: true,
            Key.lastPage: 0,
            Key.startAtLogin: false,
        ])

        backdropMode = BackdropMode(rawValue: defaults.string(forKey: Key.backdropMode) ?? "") ?? .glass
        dimStrength = defaults.double(forKey: Key.dimStrength)
        blurRadius = defaults.double(forKey: Key.blurRadius)
        pinnedWallpaperPath = defaults.string(forKey: Key.pinnedWallpaperPath)
        pinchEnabled = defaults.bool(forKey: Key.pinchEnabled)
        launchpadKeyEnabled = defaults.bool(forKey: Key.launchpadKeyEnabled)
        showHiddenInSearch = defaults.bool(forKey: Key.showHiddenInSearch)
        showLabels = defaults.bool(forKey: Key.showLabels)
        hotCorner = HotCorner(rawValue: defaults.string(forKey: Key.hotCorner) ?? "") ?? .off
        hideDock = defaults.bool(forKey: Key.hideDock)
        resumeLastPage = defaults.bool(forKey: Key.resumeLastPage)
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
