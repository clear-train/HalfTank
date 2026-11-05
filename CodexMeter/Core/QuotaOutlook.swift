import Foundation

/// What the recorded history says about one window reaching its own reset.
///
/// The advisor and the popover need this per window rather than as one blended
/// answer: a five-hour window refills several times a day, so running it dry is
/// routine, while a weekly window that runs dry is the case a banked reset
/// actually fixes.
enum QuotaCoverage: Equatable, Sendable {
    /// Enough history says the window still has quota when its reset arrives.
    case lastsUntilReset
    /// The window is projected to run dry before its own reset.
    case runsOut(Date)
    /// Recent samples show no consumption at all, so there is no rate to project.
    case idle(since: Date)
    /// Too little history to say anything useful.
    case unknown

    var exhaustionDate: Date? {
        if case let .runsOut(date) = self { return date }
        return nil
    }
}

struct QuotaWindowOutlook: Identifiable, Equatable, Sendable {
    let window: UsageWindow
    let coverage: QuotaCoverage

    var id: String { window.historyID }

    var isLongWindow: Bool { QuotaOutlook.isLongWindow(window) }
}

/// Projects, per window, whether its current burn rate reaches the reset.
enum QuotaOutlook {
    /// Windows at least a day long are the ones where a shortfall matters; a
    /// five-hour window refills on its own long before a credit is worth spending.
    static let longWindowMinimumMinutes = 24 * 60

    /// How far back "no consumption" is judged. A quiet hour is enough to show
    /// the account is idling, and short enough to react when work resumes.
    static let idleLookback: TimeInterval = 60 * 60

    static func isLongWindow(_ window: UsageWindow) -> Bool {
        guard let duration = window.windowDurationMins else { return false }
        return duration >= longWindowMinimumMinutes
    }

    static func outlooks(
        windows: [UsageWindow],
        samples: [QuotaHistorySample],
        now: Date
    ) -> [QuotaWindowOutlook] {
        windows.map {
            QuotaWindowOutlook(
                window: $0,
                coverage: coverage(for: $0, samples: samples, now: now)
            )
        }
    }

    static func coverage(
        for window: UsageWindow,
        samples: [QuotaHistorySample],
        now: Date
    ) -> QuotaCoverage {
        let windowSamples = samples.filter { $0.windowID == window.historyID }

        if let estimate = QuotaExhaustionEstimate.calculate(
            samples: windowSamples,
            now: now,
            allowingPastReset: true
        ) {
            if let resetsAt = window.resetsAt, estimate.exhaustedAt >= resetsAt {
                return .lastsUntilReset
            }
            return .runsOut(estimate.exhaustedAt)
        }

        if let since = idleSince(windowSamples, now: now) {
            return .idle(since: since)
        }

        return .unknown
    }

    /// Start of the recent stretch in which the window did not lose quota.
    private static func idleSince(_ samples: [QuotaHistorySample], now: Date) -> Date? {
        let recent = samples
            .filter { $0.sampledAt <= now && $0.sampledAt >= now.addingTimeInterval(-idleLookback) }
            .sorted { $0.sampledAt < $1.sampledAt }
        guard recent.count >= 2, let first = recent.first, let last = recent.last else {
            return nil
        }
        guard last.remainingPercent >= first.remainingPercent else { return nil }
        return first.sampledAt
    }
}
