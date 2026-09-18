import CoreGraphics

/// Maps a pointer position to a grid slot.
///
/// Kept as a pure value type so it can be unit-tested: the previous
/// implementation leaned on SwiftUI's `.onDrag`/`.onDrop`, whose failure mode
/// was silent — nothing happened and there was no way to tell why.
struct GridHitTester {
    let metrics: GridMetrics
    let itemCount: Int
    /// Size of the area the grid is centred in (the page viewport).
    let containerSize: CGSize
    /// Slots that may be dropped into. Defaults to the item count, which means
    /// a full page offers no target at all; passing the grid capacity lets a
    /// drop land in a trailing empty slot.
    var slotCount: Int?

    private var targets: Int { max(slotCount ?? itemCount, itemCount) }

    var gridWidth: CGFloat {
        CGFloat(metrics.columns) * metrics.cellWidth
            + CGFloat(max(metrics.columns - 1, 0)) * GridMetrics.hSpacing
    }

    /// Rows drawn for the page: driven by how many slots exist, not just how
    /// many items, so trailing empty rows remain droppable.
    var rows: Int {
        max(Int(ceil(Double(targets) / Double(max(metrics.columns, 1)))), 1)
    }

    var gridHeight: CGFloat {
        CGFloat(rows) * metrics.cellHeight + CGFloat(max(rows - 1, 0)) * GridMetrics.vSpacing
    }

    /// Top-left of the grid inside the container: it is centred both ways.
    var origin: CGPoint {
        CGPoint(
            x: (containerSize.width - gridWidth) / 2,
            y: (containerSize.height - gridHeight) / 2
        )
    }

    /// The slot under `point`, or nil when the point is outside the grid.
    /// A point past the last item on a row still resolves to that row's slot,
    /// clamped to the item count, so drops near the end behave predictably.
    func index(at point: CGPoint) -> Int? {
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        // Clamp to the area actually drawn. Without this the last row's stride
        // (which includes trailing spacing) would accept drops below the grid.
        guard local.x >= 0, local.y >= 0, local.x < gridWidth, local.y < gridHeight else { return nil }

        let columnStride = metrics.cellWidth + GridMetrics.hSpacing
        let rowStride = metrics.cellHeight + GridMetrics.vSpacing
        let column = Int(local.x / columnStride)
        let row = Int(local.y / rowStride)

        guard column >= 0, column < metrics.columns, row < rows else { return nil }
        let index = row * metrics.columns + column
        return index < targets ? index : nil
    }

    /// Centre of a slot, used to place the drag proxy.
    func centre(of index: Int) -> CGPoint {
        let column = index % max(metrics.columns, 1)
        let row = index / max(metrics.columns, 1)
        return CGPoint(
            x: origin.x + CGFloat(column) * (metrics.cellWidth + GridMetrics.hSpacing) + metrics.cellWidth / 2,
            y: origin.y + CGFloat(row) * (metrics.cellHeight + GridMetrics.vSpacing) + metrics.cellHeight / 2
        )
    }
}
