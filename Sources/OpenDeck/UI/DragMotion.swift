import CoreGraphics
import Foundation

/// One display-link step of the drag motion.
struct DragMotionStep: Equatable {
    /// The presented value after the step.
    var value: Double
    /// True once the motion has converged; the caller then stops the link.
    var settled: Bool
}

/// The motion maths behind a paged drag.
///
/// Ported from LaunchOS **instruction by instruction**, so every constant below
/// carries the address it was decoded from and can be re-derived instead of
/// trusted. Pure in the same way `PagingState` and `DeckClickState` are pure:
/// the real thing runs inside a `CADisplayLink` and cannot be driven from
/// `--selftest`, but the *rules* can — and these rules are exactly where the
/// "feel" lives.
///
/// ## Provenance
///
/// Report 33 §2 (archived in `docs/review/archive-2026-10-15.zip`; summary in
/// `docs/review/DECISIONS.md` §1) reconstructs the functions this
/// ports. They were disassembled from the arm64 slice with `xcrun llvm-objdump`;
/// the addresses are stable because the binary is the one shipped in
/// `/Applications/LaunchOS.app`.
///
/// ## What is deliberately *not* here
///
/// The same disassembly yielded a second pair of functions: the end-resistance
/// curve (`0x10011c790`) and the composition that turns the pointer's travel into
/// a target offset (`0x10011df70`, `targetOffsetX = helper(dx)`). Both are gone
/// from this file, and that is a **behavioural decision, not a decoding loss**
/// (report 37 §2): the strip does not follow the pointer. Feeding the pointer's
/// travel into the strip cancels the reflow — the strip gives back exactly the
/// distance the pointer covered, so the pointer stays over the cell it started
/// on for the whole drag — and on screen it reads as the entire grid sliding
/// sideways while an icon is dragged. The strip moves only when the page
/// changes. The decoded constants survive in reports 32/33 if the decision is
/// ever revisited.
enum DragMotion {

    // MARK: - Interpolation (LaunchOS `updatePagedDragFrame:` @ 0x10011ca8c)

    /// The motion settles once the remaining distance drops below this
    /// (`0x10011cad0`).
    static let settleThreshold: Double = 0.1

    /// 120 Hz — the fastest frame the ramp compensates for (`0x10011cb44`).
    static let fastestFrame: Double = 1.0 / 120.0

    /// 60 Hz — the ramp's reference frame (`0x10011cb58`).
    static let referenceFrame: Double = 1.0 / 60.0

    /// Approach factor for a 120 Hz frame (`0x10011cbb4`).
    static let alphaFastestFrame: Double = 0.21

    /// Approach factor for a 60 Hz frame and anything slower (`0x10011cb7c`).
    static let alphaReferenceFrame: Double = 0.42

    /// Ceiling on the ramp (`0x10011cb94`).
    ///
    /// Unreachable while the ramp spans `[1/120, 1/60]` — the binary carries it
    /// defensively, and so do we, because silently dropping a constant is how a
    /// port drifts from its source.
    static let alphaCap: Double = 0.58

    /// The per-frame approach factor for a measured frame duration.
    ///
    /// The factor is **ramped with the frame duration**, not fixed. A 60 Hz
    /// frame therefore takes a step twice the size of a 120 Hz frame, which
    /// holds the motion's time constant (and so its feel) steady across
    /// ProMotion and a plain 60 Hz panel.
    ///
    /// > Report 32 read this as "0.21 at both ends". The disassembly says
    /// > otherwise: `<= 1/120 → 0.21`, `>= 1/60 → 0.42`, linear between. The
    /// > distinction is not academic — a fixed 0.21 would make the deck feel
    /// > half as fast on a 120 Hz display as on a 60 Hz one.
    static func alpha(frameDuration: Double) -> Double {
        if frameDuration <= fastestFrame { return alphaFastestFrame }
        if frameDuration >= referenceFrame { return alphaReferenceFrame }
        return min(alphaReferenceFrame * (frameDuration / referenceFrame), alphaCap)
    }

    /// Advances the presented value one frame toward the goal.
    ///
    /// - Parameter frameDuration: `targetTimestamp - timestamp` from the display
    ///   link — the *real* frame duration, which is what makes the ramp
    ///   meaningful. Feeding a nominal 1/60 here would defeat it.
    static func step(value: Double, goal: Double, frameDuration: Double) -> DragMotionStep {
        guard abs(goal - value) >= settleThreshold else {
            // The binary snaps the value onto the goal rather than leaving it a
            // fraction of a point short, so a settled deck is exactly on a page.
            return DragMotionStep(value: goal, settled: true)
        }
        return DragMotionStep(value: value + (goal - value) * alpha(frameDuration: frameDuration),
                              settled: false)
    }

    // MARK: - Slop

    /// How far a press must move before it becomes a drag (`0x10011df38`).
    ///
    /// LaunchOS uses **4 points** — half the 8 OpenDeck inherited from SwiftUI's
    /// `DragGesture(minimumDistance:)`. A smaller slop is a real part of the
    /// feel: the tile starts following the pointer almost immediately, instead
    /// of after a visible dead zone.
    static let dragSlop: Double = 4

    /// Whether a press has moved far enough to count as a drag.
    ///
    /// ⚠️ The predicate on that address is a two-axis `fcmp`/`fccmp` pair whose
    /// exact conjunction could not be pinned down with certainty; "either axis
    /// reaching `dragSlop`" is the reading the instruction pair supports. It is
    /// asserted in `--selftest`, so correcting it later is a one-line change
    /// plus one mutation rather than a hunt.
    static func exceedsSlop(from origin: CGPoint, to point: CGPoint) -> Bool {
        abs(point.x - origin.x) >= dragSlop || abs(point.y - origin.y) >= dragSlop
    }

    // MARK: - Pages

    /// The offset of a deck resting on `page`.
    ///
    /// The one composition in this file, and the simplest possible one: the
    /// strip's position is stated by the page, not by the pointer. `0x10011df70`
    /// computes a page offset the same way, but from `dx`; see the note at the
    /// top for why this build does not.
    static func restingGoal(page: Int, pageWidth: Double) -> Double {
        -Double(page) * pageWidth
    }

    /// The page a settled offset lands on, clamped to the deck.
    static func settledPage(offset: Double, pageWidth: Double, pageCount: Int) -> Int {
        guard pageWidth > 0, pageCount > 0 else { return 0 }
        let raw = Int((-offset / pageWidth).rounded())
        return min(max(raw, 0), pageCount - 1)
    }
}
