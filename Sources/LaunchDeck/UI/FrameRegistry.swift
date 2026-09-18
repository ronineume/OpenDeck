import CoreGraphics

/// Records where each grid tile actually landed, in window coordinates.
///
/// LaunchOS does the folder zoom with an animation *proxy* (a throwaway layer
/// that travels from the icon to the panel). Doing that needs the icon's real
/// frame. Two earlier attempts failed:
///
/// - `matchedGeometryEffect` broke inside the lazy grid (the source tile is
///   recycled, so the panel inherited a bogus frame and the tile vanished).
/// - A `PreferenceKey` set from inside `.background` never propagated.
///
/// Reading the frame straight from a `GeometryReader` into a plain registry and
/// consulting it once, at the moment the folder is opened, avoids both.
final class FrameRegistry {
    static let shared = FrameRegistry()

    private var frames: [String: CGRect] = [:]

    private init() {}

    func record(_ id: String, frame: CGRect) {
        // Ignore degenerate reads during teardown.
        guard frame.width > 1, frame.height > 1 else { return }
        frames[id] = frame
    }

    func frame(for id: String) -> CGRect? { frames[id] }
}
