import AppKit

/// How the deck fills the screen — LaunchOS's `displayMode`
/// (`fullScreen` / `window`, report 56 §5; labels "Full Screen" / "窗口").
enum DisplayMode: String, Codable, CaseIterable, Identifiable {
    case fullScreen
    case window

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fullScreen: return "Full Screen"
        case .window: return "Window"
        }
    }
}

/// What the deck window should look like for a display mode.
///
/// Pure — a plain value derived from the mode and the screen — so the suite can
/// pin every decision (`makeDeckWindow` consumes it and nothing else decides
/// these). Window mode gives a **normal, movable, closable window** at the
/// `.normal` level: a deck still at the full-screen level (499) would sit over
/// every other app while calling itself a window, which is the bug this type
/// exists to prevent.
struct DeckWindowStyle: Equatable {
    var fullScreen: Bool
    var movableByBackground: Bool
    var hasShadow: Bool
    /// true → the deck's own level (`deckWindowLevel`); false → `.normal`.
    var usesDeckLevel: Bool
    /// The content size the grid is laid out for.
    var contentSize: CGSize
}

enum DeckWindowStyleResolver {
    /// The fraction of the screen a windowed deck takes, and its caps.
    static let windowFraction: CGFloat = 0.74
    static let maxWindowSize = CGSize(width: 1280, height: 880)
    static let minWindowSize = CGSize(width: 720, height: 520)

    static func style(for mode: DisplayMode, screen: CGSize) -> DeckWindowStyle {
        switch mode {
        case .fullScreen:
            return DeckWindowStyle(
                fullScreen: true,
                movableByBackground: false,
                hasShadow: false,
                usesDeckLevel: true,
                contentSize: screen
            )
        case .window:
            let width = min(max((screen.width * windowFraction).rounded(), minWindowSize.width),
                            maxWindowSize.width)
            let height = min(max((screen.height * windowFraction).rounded(), minWindowSize.height),
                             maxWindowSize.height)
            return DeckWindowStyle(
                fullScreen: false,
                movableByBackground: true,
                hasShadow: true,
                usesDeckLevel: false,
                contentSize: CGSize(width: width, height: height)
            )
        }
    }
}
