import AppKit

/// Grid geometry derived from the screen the deck is shown on.
///
/// The target is Launchpad's familiar 7 x 5 arrangement; the grid only shrinks
/// when a display is too small to give every icon a comfortable size. Spacing is
/// accounted for so a full page always fits without clipping.
struct GridMetrics {
    static let hSpacing: CGFloat = 12
    static let vSpacing: CGFloat = 18
    /// Horizontal breathing room kept free on each side of the grid.
    static let sideMargin: CGFloat = 80
    /// Vertical space reserved for the search field and the page dots.
    static let chromeHeight: CGFloat = 210

    let columns: Int
    let rows: Int
    let iconSize: CGFloat
    let cellWidth: CGFloat
    let cellHeight: CGFloat

    var capacity: Int { max(columns * rows, 1) }

    static func make(for screen: NSScreen) -> GridMetrics {
        let frame = screen.frame
        let usableWidth = frame.width - sideMargin * 2
        let usableHeight = frame.height - chromeHeight

        var columns = 7
        var rows = 5
        while columns > 4, usableWidth / CGFloat(columns) < 96 { columns -= 1 }
        while rows > 3, usableHeight / CGFloat(rows) < 104 { rows -= 1 }

        let cellWidth = ((usableWidth - hSpacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded()
        let cellHeight = ((usableHeight - vSpacing * CGFloat(rows - 1)) / CGFloat(rows)).rounded()
        let iconSize = min(max(min(cellWidth - 34, cellHeight - 54), 56), 116).rounded()

        return GridMetrics(
            columns: columns,
            rows: rows,
            iconSize: iconSize,
            cellWidth: cellWidth,
            cellHeight: cellHeight
        )
    }
}
