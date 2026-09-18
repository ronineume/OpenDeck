import SwiftUI
import AppKit

/// An AppKit-backed button that behaves the way LaunchOS's `PassthroughButton`
/// is named for. Its exact internals are not recoverable from the binary (only
/// `hitTest:` / `acceptsFirstResponder` appear in the symbol table), so this
/// implements the two properties such a control needs in an overlay:
///
/// - it responds to the *first* click even when the deck window is not yet key,
/// - it never becomes first responder, so clicking it cannot pull focus out of
///   the search field.
struct PassthroughButton: View {
    let systemImage: String
    var pointSize: CGFloat = 13.5
    var accessibilityLabel: String = ""
    let action: () -> Void

    @StateObject private var hover = HoverState()

    var body: some View {
        PassthroughRepresentable(
            systemImage: systemImage,
            pointSize: pointSize,
            action: action
        )
        .frame(width: pointSize + 12, height: pointSize + 12)
        .help(accessibilityLabel)
    }
}

private struct PassthroughRepresentable: NSViewRepresentable {
    let systemImage: String
    let pointSize: CGFloat
    let action: () -> Void

    func makeNSView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        configure(view)
        return view
    }

    func updateNSView(_ view: PassthroughView, context: Context) {
        configure(view)
    }

    private func configure(_ view: PassthroughView) {
        view.action = action
        view.pointSize = pointSize
        view.symbol = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        view.needsDisplay = true
    }
}

final class PassthroughView: NSView {
    var action: (() -> Void)?
    var symbol: NSImage?
    var pointSize: CGFloat = 13

    private var isPressed = false
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    /// Respond to the first click without requiring the window to be activated.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Never take keyboard focus from the search field.
    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        needsDisplay = true
        if inside { action?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let symbol else { return }
        // Tint through the symbol's own palette: drawing a template and then
        // filling over it produced a solid block instead of the glyph.
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let configured = symbol.withSymbolConfiguration(configuration) else { return }

        let alpha: CGFloat = isPressed ? 0.5 : (isHovered ? 1.0 : 0.62)
        let size = configured.size
        let rect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        configured.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
    }
}
