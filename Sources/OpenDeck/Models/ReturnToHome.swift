import Foundation

/// How long the deck may remember which page it was on.
///
/// A superset of the old `resumeLastPage` boolean: `never` is the old "resume
/// where I left off" and `always` is the old "return to the main page". The five
/// timed tiers in between reopen on the saved page only while the deck was left
/// less than that long ago, so a deck opened once a week still starts at home
/// instead of on whatever page was last touched.
enum ReturnToHome: String, CaseIterable, Identifiable {
    case always
    case never
    case after5Sec
    case after15Sec
    case after30Sec
    case after1Min
    case after5Min

    var id: String { rawValue }

    /// How long a saved page stays valid. `nil` for the two untimed tiers.
    var grace: TimeInterval? {
        switch self {
        case .always, .never: return nil
        case .after5Sec: return 5
        case .after15Sec: return 15
        case .after30Sec: return 30
        case .after1Min: return 60
        case .after5Min: return 300
        }
    }

    var label: String {
        switch self {
        case .always: return "Always start at the main page"
        case .never: return "Always resume where I left off"
        case .after5Sec: return "Resume if closed for under 5 seconds"
        case .after15Sec: return "Resume if closed for under 15 seconds"
        case .after30Sec: return "Resume if closed for under 30 seconds"
        case .after1Min: return "Resume if closed for under a minute"
        case .after5Min: return "Resume if closed for under 5 minutes"
        }
    }

    /// Whether the deck should reopen on the saved page.
    ///
    /// The single decision point for the whole policy, so the rule is checkable
    /// without a window or a clock: the caller reads it and does nothing else
    /// (see `LaunchpadWindowController.show`).
    ///
    /// - Parameters:
    ///   - closedAt: when the deck was last dismissed, or `nil` if that is not on
    ///     record (a first launch, or a preference written before this existed).
    ///     A timed tier treats "no record" as too long ago, which is the safe
    ///     reading: the deck opens at home rather than on a stale page.
    func resumes(lastPage: Int, closedAt: Date?, now: Date) -> Bool {
        switch self {
        case .always:
            return false
        case .never:
            return true
        case .after5Sec, .after15Sec, .after30Sec, .after1Min, .after5Min:
            guard let closedAt else { return false }
            return now.timeIntervalSince(closedAt) <= (grace ?? 0)
        }
    }
}
