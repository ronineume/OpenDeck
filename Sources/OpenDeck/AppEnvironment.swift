import Foundation

/// Global flags that change how the UI renders.
enum AppEnvironment {
    /// True while rendering offscreen (snapshots, benchmarks).
    ///
    /// `NSVisualEffectView` with `.behindWindow` blending samples whatever is
    /// composited behind the window. Offscreen there is no desktop behind, so
    /// the backdrop falls back to drawing the wallpaper image instead.
    static var isOffscreenRender = false

    /// Freeze the folder-open animation at its first frame, so a snapshot can
    /// confirm the proxy really starts on top of the icon.
    static var freezeFolderAnimation = false

    /// True while running a development tool (`--selftest`, `--bench`,
    /// `--snapshot`).
    ///
    /// Those tools build the same objects the app does, and those objects change
    /// things as they are constructed: `DeckSettings` writes every property back
    /// into preferences and `startAtLogin`'s setter registers or unregisters a
    /// login item. Both are live user state. This flag is the preferences-side
    /// twin of the explicit `storeURL` that keeps `DeckStore` off the real
    /// layout folder, and it has to be set before anything reads
    /// `DeckSettings.shared`.
    static var isHeadless = false
}
