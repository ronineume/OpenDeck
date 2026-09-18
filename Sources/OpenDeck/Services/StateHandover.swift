import Foundation

/// One-time handover from the app's pre-rename identity.
///
/// The app was called **LaunchDeck** until it was renamed **OpenDeck**. That
/// rename moved two pieces of persistent state, and neither move happens on its
/// own:
///
/// - the layout folder, `~/Library/Application Support/LaunchDeck` → `…/OpenDeck`
/// - the preferences domain, `local.launchdeck.app` → `local.opendeck.app`
///
/// Without a handover the upgrade is indistinguishable from a fresh install:
/// the grid comes back empty and the hot key, the hidden marks, the sort rule
/// and the backdrop settings are back at their defaults.
///
/// The handover only ever **copies**. The legacy folder and the legacy
/// preferences domain are left exactly as they were, so an upgrade can be
/// undone by deleting the new ones. Nothing here moves, and nothing here
/// deletes.
enum StateHandover {
    /// The Application Support folder name used before the rename.
    static let legacyFolderName = "LaunchDeck"

    /// The bundle identifier used before the rename.
    static let legacyBundleID = "local.launchdeck.app"

    /// Preferences carried into the new domain.
    ///
    /// Listed explicitly rather than by dumping the legacy domain wholesale: a
    /// preferences domain also carries keys the system writes there, and moving
    /// those into another app's domain is not ours to do.
    static let preferenceKeys = [
        "backdropMode", "dimStrength", "blurRadius", "pinnedWallpaperPath",
        "hotKeyCode", "hotKeyModifiers", "hotKeyEnabled",
        "pinchEnabled", "launchpadKeyEnabled", "showHiddenInSearch", "showLabels",
        "hotCorner", "hideDock", "resumeLastPage", "lastPage", "startAtLogin",
    ]

    /// The layout files carried over. The backup travels with the main file
    /// because it is the only recovery source when the main file fails to
    /// decode — carrying one without the other would drop that safety net.
    static let layoutFiles = ["layout.json", "layout.json.bak"]

    // MARK: - Which layout file to open

    /// Resolves the layout file a store should open.
    ///
    /// Pure on purpose: the rule is checkable without touching a real folder,
    /// which matters because exercising it for real would mean writing into the
    /// user's live Application Support directory.
    ///
    /// - A **writable** store always opens `current`. Routing a write into the
    ///   pre-rename folder is the one outcome this must never allow.
    /// - A **read-only** caller falls back to `legacy` only while `current` does
    ///   not exist yet, so `--bench` and `--snapshot` keep reporting on the
    ///   user's real layout instead of an empty deck in the window between the
    ///   rename and the first writable launch. `readOnly` is part of the
    ///   condition precisely so a writable store cannot reach this branch.
    static func resolveLayout(
        storeURL: URL?,
        readOnly: Bool,
        current: URL,
        legacy: URL,
        exists: (URL) -> Bool
    ) -> URL {
        if let storeURL { return storeURL }
        guard readOnly, !exists(current), exists(legacy) else { return current }
        return legacy
    }

    // MARK: - Layout files

    /// Copies the legacy layout into `base`, for each file `base` does not have.
    ///
    /// - Returns: the names **verified to have landed**. Callers report this and
    ///   nothing else: a file is never listed unless it was confirmed on disk
    ///   after the copy, so a failed copy cannot be announced as a success.
    @discardableResult
    static func adoptLayout(
        from legacyBase: URL,
        into base: URL,
        seams: FileSeams = FileSeams()
    ) -> [String] {
        let fm = FileManager.default
        var adopted: [String] = []
        for name in layoutFiles {
            let source = legacyBase.appendingPathComponent(name)
            let destination = base.appendingPathComponent(name)
            // Never overwrite: a file already sitting in the new folder is live
            // state, and the legacy copy is by definition the older one.
            guard !fm.fileExists(atPath: destination.path),
                  fm.fileExists(atPath: source.path) else { continue }
            do {
                try seams.copyItem(source, destination)
            } catch {
                NSLog("OpenDeck: could not carry over \(name): \(error.localizedDescription)")
                continue
            }
            if fm.fileExists(atPath: destination.path) { adopted.append(name) }
        }
        return adopted
    }

    // MARK: - Preferences

    /// The preferences to carry over, as a plain dictionary.
    ///
    /// Pure, and deliberately returns values rather than writing them: the rule
    /// is then checkable without a preferences domain existing at all, and the
    /// caller owns the only write.
    ///
    /// A key the current domain already carries is skipped — it belongs to the
    /// current install, which outranks the legacy one. A key the legacy domain
    /// does not carry is skipped too, so a migration cannot invent settings the
    /// user never made.
    static func preferencesToAdopt(
        from legacy: [String: Any],
        current: [String: Any],
        keys: [String] = preferenceKeys
    ) -> [String: Any] {
        var adopt: [String: Any] = [:]
        for key in keys where current[key] == nil {
            guard let value = legacy[key] else { continue }
            adopt[key] = value
        }
        return adopt
    }

    /// What the pre-rename install left behind.
    static func legacyPreferences() -> [String: Any] {
        guard let legacy = UserDefaults(suiteName: legacyBundleID) else { return [:] }
        return legacy.persistentDomain(forName: legacyBundleID) ?? [:]
    }

    /// The preferences to carry over into this install, ready to be written.
    ///
    /// Returns nothing when there is no bundle identifier, i.e. no domain of our
    /// own to write into — a bare test binary, for one.
    ///
    /// "Already present here" is read from the **persisted** domain. Measured on
    /// this machine: `object(forKey:)` and `dictionaryRepresentation()` both
    /// return registered defaults as well, so a key that only has a built-in
    /// default looks like something the user chose, and their real value gets
    /// skipped. `persistentDomain(forName:)` excludes the registration domain
    /// and is the only one of the three that answers the question being asked.
    static func preferencesToCarryOver() -> [String: Any] {
        guard let ownDomain = Bundle.main.bundleIdentifier else { return [:] }
        let current = UserDefaults.standard.persistentDomain(forName: ownDomain) ?? [:]
        return preferencesToAdopt(from: legacyPreferences(), current: current)
    }

    // MARK: - Real locations

    /// Runs the layout half of the handover against the real folders.
    ///
    /// Called once from the app's startup path, and skipped by `DeckStore` when
    /// it was handed an explicit `storeURL`: a headless tool must not write into
    /// live user state.
    ///
    /// - Returns: the file names carried over, already verified.
    @discardableResult
    static func adoptEverything(seams: FileSeams = FileSeams()) -> [String] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = support.appendingPathComponent("OpenDeck", isDirectory: true)
        let legacyBase = support.appendingPathComponent(legacyFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return adoptLayout(from: legacyBase, into: base, seams: seams)
    }
}
