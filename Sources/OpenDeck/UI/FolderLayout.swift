import Foundation

/// The one place that decides how many columns a folder panel uses.
///
/// This used to live only inside `FolderOverlayView`, while the keyboard
/// navigation in `LaunchpadViewModel` hard-coded four columns. For any folder
/// that is not ten-plus apps those disagreed, so ↑/↓ inside a folder skipped or
/// mis-aligned rows. Both the view and the view model now read the rule from
/// here, so the two can never drift apart again.
enum FolderLayout {
    /// Column count for a folder holding `count` apps.
    static func columns(forMemberCount count: Int) -> Int {
        switch count {
        case 0 ... 1: return 1
        case 2 ... 4: return 2
        case 5 ... 9: return 3
        default: return 4
        }
    }
}
