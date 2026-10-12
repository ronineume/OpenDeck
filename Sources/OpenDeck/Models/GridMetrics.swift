import AppKit

/// A page shape the user can ask for.
///
/// The eight combinations a comparable Launchpad replacement offers — seven to
/// ten columns by five or six rows. `grid7x5` is the arrangement macOS shipped,
/// so it is the default and an untouched install renders exactly as before.
///
/// A preset is a **request**, not a guarantee: `GridMetrics.make` still shrinks
/// it when the display cannot seat that many icons at a comfortable size, which
/// is why the geometry is derived rather than read straight off the preset.
enum GridPreset: String, CaseIterable, Identifiable {
    case grid7x5
    case grid8x5
    case grid9x5
    case grid10x5
    case grid7x6
    case grid8x6
    case grid9x6
    case grid10x6

    var id: String { rawValue }

    /// The shape macOS shipped, and what every caller gets unless it asks for
    /// another one. Kept as a constant so the default lives in one place and the
    /// self-test can name it rather than repeating the literal.
    static let macOSDefault: GridPreset = .grid7x5

    var columns: Int {
        switch self {
        case .grid7x5, .grid7x6: return 7
        case .grid8x5, .grid8x6: return 8
        case .grid9x5, .grid9x6: return 9
        case .grid10x5, .grid10x6: return 10
        }
    }

    var rows: Int {
        switch self {
        case .grid7x5, .grid8x5, .grid9x5, .grid10x5: return 5
        case .grid7x6, .grid8x6, .grid9x6, .grid10x6: return 6
        }
    }

    /// What the settings picker shows.
    var label: String { "\(columns) × \(rows)" }
}

/// Grid geometry derived from the screen the deck is shown on.
///
/// The target used to be Launchpad's familiar 7 x 5 arrangement; it is now
/// whatever `GridPreset` the user asked for, and the grid only shrinks when a
/// display is too small to give every icon a comfortable size. Spacing is
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

    static func make(for screen: NSScreen, preset: GridPreset = GridPreset.macOSDefault) -> GridMetrics {
        make(in: screen.frame.size, preset: preset)
    }

    /// The geometry for a display of `size`.
    ///
    /// Split out from `make(for:)` so the rule is checkable without a display:
    /// the self-test drives it with plain sizes instead of whatever monitors
    /// this machine happens to have attached.
    static func make(in size: CGSize, preset: GridPreset = GridPreset.macOSDefault) -> GridMetrics {
        let usableWidth = size.width - sideMargin * 2
        let usableHeight = size.height - chromeHeight

        var columns = preset.columns
        var rows = preset.rows
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
