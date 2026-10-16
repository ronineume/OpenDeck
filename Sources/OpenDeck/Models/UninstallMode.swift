import AppKit

/// "Hold Option for Uninstall" — LaunchOS's uninstall mode (report 56 §4).
///
/// Decoded: `LaunchpadAppView.mouseDown:` (`0x1000e9160`) reads the event's
/// `modifierFlags` and, when the tested bit is set, forwards the click to
/// `rightMouseDown:` — i.e. a modified left click opens the context menu
/// instead of launching the app, so Uninstall is one click away.
///
/// **Documented vs decoded — an honest discrepancy.** Both the en string
/// (`Hold Option for Uninstall`) and the zh-Hans string (`按住 Option 进入卸载模式`)
/// name **Option**, and the feature's own name is the uninstall mode; the
/// binary tests bit 18 of the flags (`tbnz w0, #0x12` at `0x1000e91a4`),
/// which is `NSEvent.ModifierFlags.control` (measured: control = 1<<18 =
/// 262144, option = 1<<19 = 524288). A modifier that is already right-click
/// on every macOS pointer would make the feature redundant, so OpenDeck
/// implements the **documented** modifier (Option) and enters the uninstall
/// flow directly — the zh string's own words — rather than opening the menu.
enum UninstallMode {
    /// Whether a click taken with these modifier flags should enter uninstall
    /// mode instead of launching the app.
    static func isActive(modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.contains(.option)
    }

    /// The live modifier state, read at click time. A held modifier is
    /// reflected here while the click happens.
    static var currentModifierFlags: NSEvent.ModifierFlags { NSEvent.modifierFlags }
}
