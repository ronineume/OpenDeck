import Foundation

/// The one place that decides how many columns a folder panel uses.
///
/// LaunchOS lays a folder out with the **page's column count** — its
/// `AppState::columnsPerPage`, read in the folder-present path (the "one row is
/// seven" a user sees on the default grid; a user who picks 8×5 or 10×6 gets 8
/// or 10 per row). The panel is therefore **fixed in width** and its icons
/// **left-align**; as a folder gains members the panel only grows **downward**
/// (more rows) — it never widens, and a two-app folder is a wide panel with two
/// icons at the top-left.
///
/// This replaced the earlier count-driven 1/2/3/4 rule, which made the panel
/// *narrower* for small folders — the opposite of LaunchOS. The keyboard
/// navigation in `LaunchpadViewModel` reads the same rule, so ↑/↓ stay
/// aligned with the drawn grid.
enum FolderLayout {
    /// Columns for a folder panel: the page's column count, clamped to at least
    /// one. `memberCount` is accepted (and documented) but deliberately does not
    /// change the width — a folder keeps the page's columns whatever its size.
    static func columns(pageColumns: Int, memberCount: Int = 0) -> Int {
        max(pageColumns, 1)
    }
}
