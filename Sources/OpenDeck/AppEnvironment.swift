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
}
