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
/// How much bigger or smaller the user wants app icons than the derived size.
///
/// The base size is still derived from the display (see `GridMetrics.make`);
/// this only scales it. Clamped, so a slider cannot push an icon out of the cell
/// that holds it — the same "a preset is a request, not a guarantee" rule the
/// grid shape already follows.
enum IconScale {
    static let minimum: CGFloat = 0.7
    static let maximum: CGFloat = 1.4
    static let `default`: CGFloat = 1.0

    static func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }
}

/// The point size an icon's caption is drawn at (report 49, corrected).
///
/// **Derived from the user's icon scale — not from the icon's measured size.**
/// LaunchOS reads the size off a base font object instead of naming one
/// (`0x100126d6c` → `pointSize`, then `setFontSize:` at `0x100126d78`), which is
/// why the caption is not a hard-coded 13; but that font is a constant, so the
/// *icon's* size never enters the value.
///
/// Deriving it from `metrics.iconSize` instead — the first cut of report 49 —
/// was wrong twice over. `iconSize` is mostly the **display's** decision: on a
/// 1512 pt-wide screen the default preset hands the grid 86 pt icons against a
/// 116 pt cap, so that rule asked for `round(86 × 13 / 116) = 10` and put a
/// 10 pt name under the 13 pt name it was meant to preserve. The caption should
/// follow the setting the user actually moved, so the input is `IconScale`.
///
/// A pure value type so the rule is checkable without a display — the same
/// reason `IconScale` and `GridMetrics.make(in:)` are.
enum LabelMetrics {
    /// The size at 100 % — the constant OpenDeck shipped before, so a deck at
    /// the default scale looks exactly as it always did.
    static let referencePointSize: CGFloat = 13
    /// Below this the caption stops being readable; above it two lines stop
    /// fitting the band under the icon.
    static let minimumPointSize: CGFloat = 10
    static let maximumPointSize: CGFloat = 20

    static func pointSize(scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return referencePointSize }
        let scaled = (referencePointSize * scale).rounded()
        return min(max(scaled, minimumPointSize), maximumPointSize)
    }

    /// The vertical room the caption needs under its icon. Kept at the value the
    /// layout already used — 48 pt of a 13 pt caption — so nothing moves at the
    /// default size, and scaled from there so the press target keeps covering
    /// the text.
    static func hitBlock(scale: CGFloat) -> CGFloat {
        (48 * pointSize(scale: scale) / referencePointSize).rounded()
    }
}

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
    /// The user's icon scale, clamped. Stored because the caption is derived
    /// from **this** and not from `iconSize` (see `LabelMetrics`). Defaults to
    /// 100 % so the hand-built metrics in the suite and in `DeckStore`'s
    /// fallback keep the caption at the size the deck has always drawn.
    var iconScale: CGFloat = IconScale.default

    var capacity: Int { max(columns * rows, 1) }

    /// The caption point size for this grid.
    var captionPointSize: CGFloat { LabelMetrics.pointSize(scale: iconScale) }
    /// The press target's caption band for this grid.
    var captionHitBlock: CGFloat { LabelMetrics.hitBlock(scale: iconScale) }

    static func make(
        for screen: NSScreen,
        preset: GridPreset = GridPreset.macOSDefault,
        iconScale: CGFloat = IconScale.default
    ) -> GridMetrics {
        make(in: screen.frame.size, preset: preset, iconScale: iconScale)
    }

    /// The geometry for a display of `size`.
    ///
    /// Split out from `make(for:)` so the rule is checkable without a display:
    /// the self-test drives it with plain sizes instead of whatever monitors
    /// this machine happens to have attached.
    static func make(
        in size: CGSize,
        preset: GridPreset = GridPreset.macOSDefault,
        iconScale: CGFloat = IconScale.default
    ) -> GridMetrics {
        let usableWidth = size.width - sideMargin * 2
        let usableHeight = size.height - chromeHeight

        var columns = preset.columns
        var rows = preset.rows
        while columns > 4, usableWidth / CGFloat(columns) < 96 { columns -= 1 }
        while rows > 3, usableHeight / CGFloat(rows) < 104 { rows -= 1 }

        let cellWidth = ((usableWidth - hSpacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded()
        let cellHeight = ((usableHeight - vSpacing * CGFloat(rows - 1)) / CGFloat(rows)).rounded()
        // The display decides the base size; the user's scale only multiplies it.
        // The second clamp keeps a scaled-up icon inside its cell, so no scale can
        // make neighbouring icons overlap.
        let baseIcon = min(max(min(cellWidth - 34, cellHeight - 54), 56), 116)
        let ceiling = max(min(cellWidth - 8, cellHeight - 8), 40)
        let scale = IconScale.clamped(iconScale)
        let scaled = (baseIcon * scale).rounded()
        let iconSize = min(max(scaled, 40), ceiling)

        return GridMetrics(
            columns: columns,
            rows: rows,
            iconSize: iconSize,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            // The grid carries the scale the caption is derived from, so the
            // view never has to re-derive it from `iconSize` (report 49).
            iconScale: scale
        )
    }
}
