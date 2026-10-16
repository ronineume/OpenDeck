import Foundation
import SwiftUI

/// The folder merge motion of LaunchOS, decoded from its binary — evidence,
/// not invention (report 44 §2).
///
/// At `0x1000e6538` (absorb) and `0x1000e68a0` (release) the original drives
/// two parallel `CABasicAnimation`s on the affected view:
///
/// | key                 | keyPath    | from                  | to                    |
/// |---------------------|------------|-----------------------|-----------------------|
/// | `merge.scale.in`    | transform  | scale(0.80901699...)  | identity              |
/// | `merge.opacity.in`  | opacity    | 0                     | 1                     |
/// | `merge.scale.out`   | transform  | identity              | scale(0.80901699...)  |
/// | `merge.opacity.out` | opacity    | current               | 0                     |
///
/// both directions over 0.18 s with `kCAMediaTimingFunctionEaseOut`; release
/// runs its teardown in a `CATransaction` completion block. The scale constant
/// is `0x3FE9EB851EB851EC` — φ/2, cos 36° — and the duration is
/// `0x3FC70A3D70A3D70A`. OpenDeck keeps both as pure values the headless suite
/// can pin; the SwiftUI presentation consumes them, but the numbers are
/// measurements.
enum MergeMotion {
    /// The scale a joining tile starts from, and a released tile shrinks to.
    static let scale: CGFloat = 0.8090169943749475
    /// Seconds, for both directions.
    static let duration: Double = 0.18

    /// The drop-hover zoom on the folder tile the pointer is over during a
    /// drag. Decoded: `0x1000171d4` feeds `0x3FF0CCCCCCCCCCCD` = **1.05** into
    /// `CATransform3DMakeScale(1.05, 1.05, 1.0)` and then straight into
    /// `setTransform:` — an implicit animation, no explicit duration anywhere;
    /// the sibling site `0x100014760` computes `1.05 - 0.075x` for the same
    /// transform, so 1.05 is the resting amplitude. (The 1.4 at `0x1000e43e4`
    /// belongs to the "open.app" open-panel family, not the tile — landing it
    /// on the tile read as the tile jumping, and was reverted.) Position is
    /// fixed: the transform is centre-anchored.
    static let hoverZoom: CGFloat = 1.05
}

/// The folder **open** motion of LaunchOS, decoded (report 54 §1).
///
/// `LaunchpadFolderView.openFolder` (`0x1001245a8`) → `FUN_100124470` walks the
/// superview chain to the `LaunchpadGroupView`, checks `isFolder`, then calls
/// `FUN_10010c17c(contentView, group, 0)`. That presents through
/// `NSAnimationContext.runAnimationGroup` whose group block
/// (`FUN_100111da4` → `FUN_10010df6c`) sets:
///
/// - `setDuration_(ctx, 0x3fd1eb851eb851ec)` = **0.28 s**
/// - `CAMediaTimingFunction.functionWithName(kCAMediaTimingFunctionEaseInEaseOut)`
///   → `setTimingFunction_` — and the same duration + curve on every
///   `CABasicAnimation` the `FolderAnimationProxyLayer` adds.
///
/// SwiftUI's `.easeInOut(duration:)` is the same curve family (no spring). The
/// previous `spring(response: 0.34, dampingFraction: 0.84)` was a stand-in —
/// settling 0.626 s, measured in report 06 — not a measurement.
///
/// The **close** reuses the open's group: no separate `runAnimationGroup` was
/// located for the dismiss, and the open block (`FUN_10010df6c`) animates
/// frame/opacity/transform from↔to — so the collapse runs the same **0.28 s**
/// ease-in-out reversed. `FolderOverlayView.collapseThen` now drives both
/// directions with this, resolving the report-54 §4 open item that had left the
/// close a spring placeholder.
enum OpenMotion {
    /// Seconds, as `0x3fd1eb851eb851ec` decodes.
    static let duration: Double = 0.28
    /// The presentation the two open sites use.
    static var animation: Animation { .easeInOut(duration: duration) }
}

/// One merge-motion request, published by the store when a folder absorbs or
/// releases members. `token` strictly increases so two flashes on the same
/// folder in a row still re-trigger the animation.
struct MergeFlash: Equatable {
    enum Kind: Equatable { case absorbed, released }
    let folderID: UUID
    let kind: Kind
    let token: Int
}
