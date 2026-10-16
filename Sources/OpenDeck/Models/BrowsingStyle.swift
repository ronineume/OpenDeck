import Foundation

/// How the deck presents the pages — LaunchOS's `browsingStyle`
/// (`paged` / `scroll`, labels "Paged" / "滚动", report 56 §6).
///
/// The **model** is pages either way: `DeckStore` keeps arranging items into
/// pages, and scroll mode lays those same pages out as one continuous column.
/// Switching back to paged therefore lands on exactly the arrangement the user
/// had — the mode is a presentation choice, not a second layout.
enum BrowsingStyle: String, Codable, CaseIterable, Identifiable {
    case paged
    case scroll

    var id: String { rawValue }

    var label: String {
        switch self {
        case .paged: return "Paged"
        case .scroll: return "Scroll"
        }
    }

    /// Whether the page indicator belongs on screen. A continuous column has no
    /// pages to point at.
    var showsPageDots: Bool { self == .paged }

    /// Whether swiping sideways moves between pages.
    var pagesWithHorizontalSwipe: Bool { self == .paged }
}
