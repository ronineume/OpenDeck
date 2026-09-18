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
            height: min(metrics.cellHeight, metrics.iconSize + (hasLabel ? 48 : 12))
        )
    }

    static func shape(hasLabel: Bool) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }
}

/// Renders a single application as an icon plus label, Launchpad-style.
struct AppCell: View {
    let app: AppInfo
    let metrics: GridMetrics
    var isSelected: Bool = false
    var isRunning: Bool = false
    var showLabel: Bool = true
    var onOpen: () -> Void

    @StateObject private var hover = HoverState()

    private var hitSize: CGSize { CellHitArea.size(metrics: metrics, hasLabel: showLabel) }

    var body: some View {
        ZStack {
            // Interaction region: sized to the icon, not to the grid cell.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(hover.isHovered || isSelected ? 0.16 : 0.0001))
                .frame(width: hitSize.width, height: hitSize.height)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onHover { hover.isHovered = $0 }
                .onTapGesture(perform: onOpen)

            VStack(spacing: 8) {
                ZStack(alignment: .bottom) {
                    Image(nsImage: app.icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: metrics.iconSize, height: metrics.iconSize)

                    if isRunning {
                        Circle()
                            .fill(.white.opacity(0.85))
                            .frame(width: 6, height: 6)
                            .offset(y: 8)
                    }
                }

                if showLabel {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                        .frame(width: metrics.cellWidth - 10)
                }
            }
            // Visuals only: the interaction rectangle above owns hit testing.
            .allowsHitTesting(false)
        }
        .scaleEffect(hover.isHovered ? 1.06 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover.isHovered)
        .frame(width: metrics.cellWidth, height: metrics.cellHeight)
    }
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
    var onOpen: () -> Void

    @StateObject private var hover = HoverState()

    private var hitSize: CGSize { CellHitArea.size(metrics: metrics, hasLabel: showLabel) }

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
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                        .frame(width: metrics.cellWidth - 10)
                }
            }
            .allowsHitTesting(false)
        }
        .scaleEffect(hover.isHovered ? 1.06 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover.isHovered)
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
                    Image(nsImage: app.icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: miniSize, height: miniSize)
                }
            }
            .padding(9)
        }
        .frame(width: metrics.iconSize, height: metrics.iconSize)
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
