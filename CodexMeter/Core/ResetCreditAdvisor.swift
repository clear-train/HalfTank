import Foundation

/// Turns banked resets, projected exhaustion, and the community reset estimate
/// into one piece of advice.
///
/// The rules stay pure and ordered so the result can be tested and explained:
/// spend a credit when the window cannot wait for its own reset, hold it when a
/// community-predicted reset is likely to arrive first, and spend it soon when it
/// would otherwise expire while quota is already burning fast.
struct ResetCreditAdvisor {
    struct Recommendation: Equatable, Sendable {
        enum Action: Equatable, Sendable {
            /// Quota is projected to run out before its own reset arrives.
            case useNow
            /// A window has already run dry, so a credit keeps the work going.
            case useAtFloor
            /// An automatic reset is more likely than not, before the credit expires.
            case waitForAutomaticReset
            /// The credit expires soon and consumption is above the ideal pace.
            case useBeforeExpiry
            /// Nothing suggests spending a credit yet.
            case hold
        }

        let action: Action
        let windowName: String?
        let exhaustionAt: Date?
        let probability: Double?
        let expectedResetAt: Date?
        let expiresAt: Date?
        let creditTitle: String?
    }

    static func recommend(
        windows: [UsageWindow],
        samples: [QuotaHistorySample],
        summary: CodexRateLimitResetCreditsSummary?,
        forecast: ResetForecast?,
        now: Date,
        strategy: ResetStrategy = .bridge,
        riskHorizon: TimeInterval = 6 * 60 * 60,
        probabilityThreshold: Double = 0.6,
        expiryWarning: TimeInterval = 48 * 60 * 60
    ) -> Recommendation? {
        guard let summary, summary.hasAvailableCredits else { return nil }
        let usable = summary.usableCredits(at: now)
        guard !usable.isEmpty else { return nil }

        let expiring = usable
            .filter { $0.expiresAt != nil }
            .min { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        let soonestExpiry = expiring?.expiresAt

        if strategy == .maximize {
            return maximizeRecommendation(
                windows: windows,
                samples: samples,
                now: now,
                riskHorizon: riskHorizon,
                expiryWarning: expiryWarning,
                soonestExpiry: soonestExpiry,
                expiring: expiring
            )
        }

        // 1. Quota that cannot survive until its own reset needs a credit now.
        if let risk = exhaustionRisk(windows: windows, samples: samples, now: now, horizon: riskHorizon) {
            return Recommendation(
                action: .useNow,
                windowName: risk.name,
                exhaustionAt: risk.at,
                probability: nil,
                expectedResetAt: nil,
                expiresAt: soonestExpiry,
                creditTitle: expiring?.title
            )
        }

        // 2. A likely automatic reset removes the reason to spend anything, as long
        // as it is expected to arrive before the credit would expire.
        if let forecast,
           forecast.probability >= probabilityThreshold,
           let expected = forecast.nextExpectedAt ?? forecast.lastResetAt,
           expected > now,
           soonestExpiry.map({ expected < $0 }) ?? true {
            return Recommendation(
                action: .waitForAutomaticReset,
                windowName: nil,
                exhaustionAt: nil,
                probability: forecast.probability,
                expectedResetAt: expected,
                expiresAt: soonestExpiry,
                creditTitle: expiring?.title
            )
        }

        // 3. An expiring credit is worth spending once quota is already over pace,
        // because holding it past that point would waste it.
        if let soonestExpiry,
           soonestExpiry.timeIntervalSince(now) <= expiryWarning,
           let burning = windows.first(where: { $0.pace(at: now) == .overPace }) {
            return Recommendation(
                action: .useBeforeExpiry,
                windowName: burning.name,
                exhaustionAt: nil,
                probability: nil,
                expectedResetAt: nil,
                expiresAt: soonestExpiry,
                creditTitle: expiring?.title
            )
        }

        return Recommendation(
            action: .hold,
            windowName: nil,
            exhaustionAt: nil,
            probability: nil,
            expectedResetAt: nil,
            expiresAt: soonestExpiry,
            creditTitle: expiring?.title
        )
    }

    /// Returns the window that will run dry within the horizon, if any.
    private static func exhaustionRisk(
        windows: [UsageWindow],
        samples: [QuotaHistorySample],
        now: Date,
        horizon: TimeInterval
    ) -> (name: String, at: Date)? {
        let deadline = now.addingTimeInterval(horizon)
        var best: (name: String, at: Date)?

        for window in windows {
            let windowSamples = samples.filter { $0.windowID == window.historyID }
            guard let estimate = QuotaExhaustionEstimate.calculate(
                samples: windowSamples,
                now: now
            ) else {
                continue
            }
            guard estimate.exhaustedAt <= deadline else { continue }
            // The official reset already refills the window, so a credit would be
            // spent on capacity the account is about to receive anyway.
            if let resetsAt = window.resetsAt, estimate.exhaustedAt >= resetsAt {
                continue
            }
            if best == nil || estimate.exhaustedAt < (best?.at ?? .distantFuture) {
                best = (window.name, estimate.exhaustedAt)
            }
        }

        return best
    }

    /// Maximising strategy: keep burning quota instead of parking it until the
    /// official reset. A credit is worth spending as soon as a window runs dry,
    /// and an expiring credit should be spent while capacity remains to use it.
    private static func maximizeRecommendation(
        windows: [UsageWindow],
        samples: [QuotaHistorySample],
        now: Date,
        riskHorizon: TimeInterval,
        expiryWarning: TimeInterval,
        soonestExpiry: Date?,
        expiring: CodexRateLimitResetCredit?
    ) -> Recommendation {
        // 1. A window at the floor blocks work right now; refilling it keeps the
        //    account consuming quota that would otherwise sit unused.
        if let floor = windows.filter({ $0.remainingPercent <= 5 }).min(by: { $0.remainingPercent < $1.remainingPercent }) {
            return Recommendation(
                action: .useAtFloor,
                windowName: floor.name,
                exhaustionAt: nil,
                probability: nil,
                expectedResetAt: nil,
                expiresAt: soonestExpiry,
                creditTitle: expiring?.title
            )
        }

        // 2. Quota that cannot survive until its own reset still needs a credit.
        if let risk = exhaustionRisk(windows: windows, samples: samples, now: now, horizon: riskHorizon) {
            return Recommendation(
                action: .useNow,
                windowName: risk.name,
                exhaustionAt: risk.at,
                probability: nil,
                expectedResetAt: nil,
                expiresAt: soonestExpiry,
                creditTitle: expiring?.title
            )
        }

        // 3. An expiring credit is wasted once it lapses, so spend it while quota
        //    still has room to absorb the refill.
        if let soonestExpiry,
           soonestExpiry.timeIntervalSince(now) <= expiryWarning,
           let burnable = windows.first(where: { $0.remainingPercent <= 70 }) {
            return Recommendation(
                action: .useBeforeExpiry,
                windowName: burnable.name,
                exhaustionAt: nil,
                probability: nil,
                expectedResetAt: nil,
                expiresAt: soonestExpiry,
                creditTitle: expiring?.title
            )
        }

        return Recommendation(
            action: .hold,
            windowName: nil,
            exhaustionAt: nil,
            probability: nil,
            expectedResetAt: nil,
            expiresAt: soonestExpiry,
            creditTitle: expiring?.title
        )
    }
}
