import Foundation

/// How an app's caption is spelled.
///
/// **LaunchOS shows the localised name.** Its own database (ground truth, read
/// from `~/Library/Application Support/LaunchOS/LaunchOS.sqlite`, `ZAPPENTITY`)
/// stores, per app, `ZBUNDLENAME` (the base plist's `CFBundleName`) and
/// `ZNAME` (what it displays):
///
/// ```
/// WeChat          ZBUNDLENAME=WeChat         ZNAME=微信
/// TencentMeeting  ZBUNDLENAME=腾讯会议        ZNAME=腾讯会议
/// Freeform        ZBUNDLENAME=Freeform       ZNAME=无边记
/// Grammarly       ZBUNDLENAME=Grammarly…     ZNAME=Grammarly for Safari
/// ```
///
/// `ZNAME` is the **localised `CFBundleDisplayName`** — the value from the
/// best-matching `.lproj/InfoPlist.strings` (WeChat's `zh-Hans.lproj` carries
/// `CFBundleDisplayName = 微信`; its base plist says `WeChat`). That is also
/// what Finder and the system Launchpad show.
///
/// Report 50 read the binary's name resolver (`0x1000b5608` →
/// `-[NSFileManager displayNameAtPath:]`) as the whole story. Measured on this
/// machine, that API returns the **folder name** — `TencentMeeting.app` for
/// `/Applications/TencentMeeting.app`, `Safari.app` for Safari — in a CLI
/// process, a GUI process, an `open`-launched process and under `sandbox-exec`
/// alike; it never localises here. So a caption taken from it alone is English
/// on a Chinese system, which is the bug this report exists to fix. The
/// resolver stays in the chain as the fallback for bundles with no plist
/// name; the localised plist wins.
///
/// The `.app` tail is dropped on top of the finder answer:
/// `displayNameAtPath:` honours the "show all filename extensions" Finder
/// preference — measured on for this machine (`defaults read -g
/// AppleShowAllExtensions` = 1), where the API answers `"Siri.app"`. Neither
/// Launchpad nor a deck wants every caption to end in `.app`.
///
/// Pure, so the rule is checkable without a file system.
enum AppNaming {
    /// - Parameters:
    ///   - localizedDisplayName: `CFBundleDisplayName` from the best-matching
    ///     `.lproj/InfoPlist.strings` — what LaunchOS displays. nil when the
    ///     bundle ships no localised name (or none the user's languages pick).
    ///   - finderDisplayName: `FileManager.displayName(atPath:)`, or nil when it
    ///     could not be asked.
    ///   - bundleDisplayName: `CFBundleDisplayName`.
    ///   - bundleName: `CFBundleName`.
    ///   - fallback: the filename without its extension.
    static func displayName(localizedDisplayName: String?,
                            finderDisplayName: String?,
                            bundleDisplayName: String?,
                            bundleName: String?,
                            fallback: String) -> String {
        let candidates = [
            cleaned(localizedDisplayName),
            withoutBundleExtension(finderDisplayName),
            cleaned(bundleDisplayName),
            cleaned(bundleName),
            cleaned(fallback),
        ]
        return candidates.compactMap { $0 }.first { !$0.isEmpty } ?? fallback
    }

    /// The localised name the way LaunchOS resolves it: match the user's
    /// preferred languages against the bundle's localizations, then read
    /// `CFBundleDisplayName` (falling back to `CFBundleName`) from that
    /// `.lproj`'s `InfoPlist.strings`.
    ///
    /// Pure — the table loading is injected — so both the matching order and
    /// the key priority are assertable headlessly.
    ///
    /// The matching is Foundation's own (`Bundle.preferredLocalizations`),
    /// measured to reproduce LaunchOS's choice: a `zh-Hans-HK` user with a
    /// bundle localizing `zh-Hans, en, zh-HK, zh-Hant` gets **`zh-Hans`** —
    /// the script match beats the region-only one, which is exactly the
    /// TencentMeeting case (`zh-HK`/`zh-Hant` carry the English
    /// `TencentMeeting`; only `zh-Hans` carries `腾讯会议`).
    static func localizedDisplayName(localizations: [String],
                                     preferences: [String],
                                     loadTable: (String) -> [String: String]?) -> String? {
        let matched = Bundle.preferredLocalizations(from: localizations, forPreferences: preferences)
        for localization in matched {
            guard let table = loadTable(localization) else { continue }
            if let value = cleaned(table["CFBundleDisplayName"]), !value.isEmpty { return value }
            if let value = cleaned(table["CFBundleName"]), !value.isEmpty { return value }
        }
        return nil
    }

    /// Production `loadTable`: the bundle's `InfoPlist.strings` for one
    /// localization, parsed as a plist (these files are UTF-16 or binary).
    static func localizedDisplayName(bundle: Bundle,
                                     preferences: [String] = Locale.preferredLanguages) -> String? {
        localizedDisplayName(localizations: bundle.localizations, preferences: preferences) { localization in
            guard let path = bundle.path(forResource: "InfoPlist", ofType: "strings",
                                         inDirectory: nil, forLocalization: localization) else {
                return nil
            }
            return NSDictionary(contentsOfFile: path) as? [String: String]
        }
    }

    /// The Finder's answer, minus a trailing `.app`. Only the extension is
    /// treated this way; anything else is passed through untouched.
    static func withoutBundleExtension(_ value: String?) -> String? {
        guard let trimmed = cleaned(value) else { return nil }
        guard trimmed.hasSuffix(".app") else { return trimmed }
        let stripped = String(trimmed.dropLast(4))
        // A bundle literally named ".app" would strip to nothing; keep the
        // original rather than producing an empty caption.
        return stripped.isEmpty ? trimmed : stripped
    }

    private static func cleaned(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
