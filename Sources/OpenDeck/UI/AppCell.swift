import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Per-cell hover state.
///
/// Hover lives per cell rather than in the shared view model, so hovering
/// repaints one icon instead of the entire deck.
final class HoverState: ObservableObject {
    @Published var isHovered = false
}

/// The clickable region of an app or folder tile.
///
/// Deliberately tighter than the grid cell. A cell is `cellWidth` wide while the
/// icon is only `iconSize`, so a full-cell hit area made every app swallow the
/// space around it and starved the click-to-dismiss background.
enum CellHitArea {
    static func size(metrics: GridMetrics, hasLabel: Bool) -> CGSize {
        CGSize(
            width: min(metrics.cellWidth, metrics.iconSize + 48),
            // The caption's block scales with the caption, which scales with the
            // user's icon scale (report 49). A fixed 48 was fine while the label
            // was pinned at 13 pt, but at 20 pt two lines are ~56 pt tall and the
            // press target would stop covering the text it is drawn around.
            height: min(metrics.cellHeight,
                        metrics.iconSize + (hasLabel ? metrics.captionHitBlock : 12))
        )
    }

    static func shape(hasLabel: Bool) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }
}

/// The caption shadow of LaunchOS, decoded (report 54 §3).
///
/// The label's `NSShadow` is built by the lazy initializer at `0x100003f34`
/// (its object is the one the label's attribute dictionary references):
///
/// | property | decoded value | immediate |
/// |---|---|---|
/// | color | black @ 0.26 | `0x3fd0a3d70a3d70a4` |
/// | blur radius | 2.0 | `0x4000000000000000` |
/// | offset | (0, −1) | `0xbff0000000000000` |
///
/// The previous `.black.opacity(0.85), y: 1` mixed up two different constants
/// from the label builder (`0x100126b40`): 0.85 is the **text** colour's alpha
/// in that function's alternate branch (black text, trigger not decoded —
/// the main branch is plain white, which is what OpenDeck draws), and the
/// shadow was never 0.85 at all.
enum CaptionShadow {
    static let alpha: Double = 0.26
    static let radius: CGFloat = 2
    static let offsetY: CGFloat = -1
}

/// The LaunchOS hidden-app badge, decoded (report 54 §2).
///
/// `HiddenBadgeView.draw(_:)` (`0x1000e5b9c`): integral bounds → `CGRectInset`
/// → `NSColor.white` fill of `bezierPathWithOvalInRect` → the `symbolImage`
/// drawn in `NSColor.black` at `0.64 × min(bounds)` centred, with a **+0.5 pt**
/// x nudge; the image itself is `eye.slash.fill` (SF Symbol, 14 pt, semibold,
/// `isTemplate`) loaded at `0x1000e58ec`; `symbolScale` = `0x3fe47ae147ae147b`
/// and `wantsLayer = false` (`0x1000e5ab4`).
///
/// **Not decoded**: the badge's diameter and where it hangs on the icon — the
/// layout code that creates the view was not located (no nib in the bundle;
/// no direct caller of `initWithFrame:`). The 0.34 diameter and the
/// top-leading placement are OpenDeck's choice; the 0.64 symbol ratio is the
/// measurement.
struct HiddenBadge: View {
    /// Symbol edge as a fraction of the badge diameter — the decoded 0.64.
    static let symbolFraction: CGFloat = 0.64
    /// Badge diameter as a fraction of the icon it decorates — **not decoded**.
    static let diameterFraction: CGFloat = 0.34

    var diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(.white)
            Image(systemName: "eye.slash.fill")
                .font(.system(size: diameter * Self.symbolFraction, weight: .semibold))
                .foregroundStyle(.black)
                // The decoded optical nudge: the original adds 0.5 pt on x.
                .offset(x: 0.5)
        }
        .frame(width: diameter, height: diameter)
    }
}

/// Renders a single application as an icon plus label, Launchpad-style.
struct AppCell: View {
    let app: AppInfo
    let metrics: GridMetrics
    var isSelected: Bool = false
    var isRunning: Bool = false
    var showLabel: Bool = true
    /// True when this app is on the hidden list — draws the decoded
    /// `HiddenBadge` (report 54 §2). Hidden apps never reach the grid; the
    /// only place the badge can show is search (when the user asked for
    /// hidden apps there).
    var isHidden: Bool = false
    /// True while the pointer hovers this app during a drag with a merge
    /// armed — the store's drop-hover mirror, the same channel `FolderCell`
    /// consumes. Drives the decoded drop-hover zoom (1.05) and the merge ring.
    /// The resting hover bloom cannot cover this: AppKit's dragging session
    /// swallows mouse events, so `onHover` never fires mid-drag.
    var isDropHover: Bool = false
    /// Runs instead of `onOpen` when uninstall mode is armed — the setting is
    /// on and Option is held (report 56 §4). nil disables the mode.
    var onUninstallMode: (() -> Void)?
    var onOpen: () -> Void

    @StateObject private var hover = HoverState()

    private var hitSize: CGSize { CellHitArea.size(metrics: metrics, hasLabel: showLabel) }

    /// The tap routing: uninstall mode wins when armed, otherwise launch.
    private func activate() {
        if let onUninstallMode,
           UninstallMode.isActive(modifierFlags: UninstallMode.currentModifierFlags) {
            onUninstallMode()
        } else {
            onOpen()
        }
    }

    var body: some View {
        ZStack {
            // Interaction region: sized to the icon, not to the grid cell.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(hover.isHovered || isSelected ? 0.16 : 0.0001))
                .frame(width: hitSize.width, height: hitSize.height)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onHover { hover.isHovered = $0 }
                .onTapGesture(perform: activate)

            VStack(spacing: 8) {
                ZStack(alignment: .bottom) {
                    Image(nsImage: app.rasterIcon(at: metrics.iconSize))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: metrics.iconSize, height: metrics.iconSize)
                        // The drop-hover merge affordance (report 45): a
                        // tile-shaped ring around the icon. It lives **on the
                        // icon**, not on the cell — the first cut hung it in the
                        // cell-level ZStack, whose centre sits below the icon's
                        // (the label pushes the icon into the VStack's upper
                        // half), so the ring read as offset downward. Anchored
                        // here it is concentric with the icon, and being inside
                        // the cell's `scaleEffect` subtree it tracks the 1.05
                        // zoom exactly. LaunchOS marks the merge target at the
                        // tile level (`isDraggingMerge`); the ring is OpenDeck's
                        // SwiftUI mapping and is not headlessly assertable —
                        // the signal that drives it is.
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(
                                    .white.opacity(isDropHover ? 0.55 : 0.0),
                                    lineWidth: 2
                                )
                                .frame(width: metrics.iconSize + 14, height: metrics.iconSize + 14)
                                .allowsHitTesting(false)
                        }
                        // The decoded hidden-app badge (report 54 §2): white
                        // circle + `eye.slash.fill` at 0.64 of the badge,
                        // hanging top-leading on the icon (placement itself
                        // not decoded — see `HiddenBadge`).
                        .overlay(alignment: .topLeading) {
                            if isHidden {
                                HiddenBadge(diameter: metrics.iconSize * HiddenBadge.diameterFraction)
                                    .padding(2)
                                    .allowsHitTesting(false)
                            }
                        }

                    if isRunning {
                        Circle()
                            .fill(.white.opacity(0.85))
                            .frame(width: 6, height: 6)
                            .offset(y: 8)
                    }
                }

                if showLabel {
                    Text(app.name)
                        .font(.system(size: metrics.captionPointSize, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(CaptionShadow.alpha), radius: CaptionShadow.radius, x: 0, y: CaptionShadow.offsetY)
                        .frame(width: metrics.cellWidth - 10)
                }
            }
            // Visuals only: the interaction rectangle above owns hit testing.
            .allowsHitTesting(false)
        }
        // The resting-hover scale 1.06 and its spring (0.25 / 0.7) are
        // **OpenDeck's own affordance, not LaunchOS's.** Its `LaunchpadAppView`
        // (arm64) carries no resting hover-scale; the only zoom decoded from it is
        // the *drop*-hover zoom `MergeMotion.hoverZoom` = 1.05 (report 45). This is
        // kept because it reads well, but it makes no parity claim and must not be
        // presented as "aligned with LaunchOS".
        .scaleEffect(isDropHover ? MergeMotion.hoverZoom : (hover.isHovered ? 1.06 : 1.0))
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover.isHovered)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDropHover)
        .frame(width: metrics.cellWidth, height: metrics.cellHeight)
    }
}

/// Holds a folder tile's merge-pulse state. A plain `ObservableObject` with
/// `@Published` — deliberately **not** `@State`: `@State` is a macro in this
/// SwiftUI, and expanding it needs `swift-plugin-server`, which cannot run
/// inside the headless sandbox (observed: `sandbox_apply: Operation not
/// permitted`, then "malformed response" — ten errors, all pointing at the
/// macro, and the old binary left behind looking green).
final class MergePulse: ObservableObject {
    @Published var scale: CGFloat = 1
    @Published var opacity: Double = 0
}

/// A folder rendered as a frosted tile containing up to nine mini icons.
struct FolderCell: View {
    let apps: [AppInfo]
    let name: String
    let metrics: GridMetrics
    var isSelected: Bool = false
    var showLabel: Bool = true
    /// True while this folder's expanded panel is on screen.
    var isOpen: Bool = false
    /// The store's merge flash, narrowed to this folder by the caller. The
    /// constants come from `MergeMotion` (decoded, report 44 §2); the
    /// presentation — a ring pulse over the tile — is OpenDeck's mapping of
    /// LaunchOS's per-view CAAnimation onto SwiftUI, and is not headlessly
    /// assertable (the signal it consumes is).
    var mergePulse: MergeFlash? = nil
    /// True while the pointer hovers this folder during a drag — the store's
    /// drop-hover mirror. Drives the decoded drop-hover zoom (1.05). The
    /// resting hover bloom cannot cover this: AppKit's dragging session swallows
    /// mouse events, so `onHover` never fires mid-drag.
    var isDropHover: Bool = false
    var onOpen: () -> Void

    @StateObject private var hover = HoverState()

    private var hitSize: CGSize { CellHitArea.size(metrics: metrics, hasLabel: showLabel) }

    @StateObject private var pulse = MergePulse()

    private var miniColumns: Int { apps.count <= 4 ? 2 : 3 }

    private var miniSize: CGFloat {
        let count = CGFloat(miniColumns)
        return (metrics.iconSize - 18 - (count - 1) * 6) / count
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(hover.isHovered || isSelected ? 0.16 : 0.0001))
                .frame(width: hitSize.width, height: hitSize.height)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onHover { hover.isHovered = $0 }
                .onTapGesture(perform: onOpen)

            VStack(spacing: 8) {
                tile
                if showLabel {
                    Text(name)
                        .font(.system(size: metrics.captionPointSize, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(CaptionShadow.alpha), radius: CaptionShadow.radius, x: 0, y: CaptionShadow.offsetY)
                        .frame(width: metrics.cellWidth - 10)
                }
            }
            .allowsHitTesting(false)
        }
        // The drop-hover zoom suppresses the resting hover scale: stacking
        // 1.05 x 1.06 would exaggerate both.
        .scaleEffect(hover.isHovered && !isDropHover ? 1.06 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover.isHovered)
        .onChange(of: mergePulse?.token) { _, _ in
            guard let flash = mergePulse, flash.kind == .absorbed else { return }
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) {
                pulse.scale = MergeMotion.scale
                pulse.opacity = 0
            }
            withAnimation(.easeOut(duration: MergeMotion.duration)) {
                pulse.scale = 1
                pulse.opacity = 1
            }
        }
        .frame(width: metrics.cellWidth, height: metrics.cellHeight)
    }

    private var tile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: metrics.iconSize * 0.22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: metrics.iconSize * 0.22, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                }

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(miniSize), spacing: 6), count: miniColumns),
                spacing: 6
            ) {
                ForEach(apps.prefix(9), id: \.id) { app in
                    Image(nsImage: app.rasterIcon(at: miniSize))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: miniSize, height: miniSize)
                }
            }
            .padding(9)
        }
        .frame(width: metrics.iconSize, height: metrics.iconSize)
        .overlay {
            // The merge-pulse ring, drawn **on the tile** — not on the cell.
            // On the cell it centred on the whole cell while the tile sits in
            // the VStack's upper half, which read as a frame offset from the
            // folder (the misaligned frame the review round caught).
            RoundedRectangle(cornerRadius: metrics.iconSize * 0.22, style: .continuous)
                .fill(.white.opacity(0.10 * pulse.opacity))
                .strokeBorder(.white.opacity(0.45 * pulse.opacity), lineWidth: 1.5)
                .scaleEffect(pulse.scale)
                .allowsHitTesting(false)
        }
        // The drop-hover zoom (MergeMotion.hoverZoom, decoded 1.05): the same
        // spring as the resting hover, centre-anchored — the tile grows in
        // place, which is what LaunchOS's straight setTransform does. The ring
        // is inside the scale, so a pulse arriving mid-zoom tracks it.
        .scaleEffect(isDropHover ? MergeMotion.hoverZoom : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDropHover)
    }
}

/// An unoccupied grid slot. Tapping it counts as empty space and dismisses.
struct EmptySlot: View {
    let metrics: GridMetrics
    let isTargeted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.white.opacity(isTargeted ? 0.14 : 0.0001))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        .white.opacity(isTargeted ? 0.35 : 0),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
            }
            .frame(width: metrics.cellWidth, height: metrics.cellHeight)
    }
}
