import Foundation

/// Turns banked resets, per-window outlooks, a learned demand curve, and the
/// community reset estimate into one line of advice.
///
/// Two facts shape every rule here. A banked reset does not add quota: it refills
/// immediately and restarts the weekly clock, so the refill that would have
/// arrived at the scheduled reset is displaced. And only windows at least a day
/// long matter, because a five-hour window refills several times a day, so a
/// credit spent covering it pays for capacity the account is about to receive
/// anyway.
///
/// The only question a credit really answers is whether the account would
/// otherwise sit at zero before its next refill. Answering it needs a demand
/// curve, which is why `ResetCreditDemand` simulates the cycle instead of
/// assuming a constant burn rate.
struct ResetCreditAdvisor {
    struct Recommendation: Equatable, Sendable {
        enum Action: Equatable, Sendable {
            /// A long window is projected to run out before its own reset.
            case useNow
            /// Maximising: a long window is already low, so refill to keep working.
            case useHeadroom
            /// An automatic reset is more likely than not, before the credit expires.
            case waitForAutomaticReset
            /// The credit expires soon while a long window is already drawn down.
            case useBeforeExpiry
            /// Nothing suggests spending a credit yet.
            case hold
        }

        let action: Action
        let windowName: String?
        /// Remaining quota of the window the advice refers to, for the one-liner.
        let windowPercent: Int?
        let exhaustionAt: Date?
        let probability: Double?
        let expectedResetAt: Date?
        let expiresAt: Date?
        let creditTitle: String?
        /// The moment the advice points at: when to spend the credit, when the
        /// long window runs dry, or the reset to wait for.
        let recommendedAt: Date?
        /// Minutes the account would sit at zero without a credit.
        let blockedMinutes: Int?
        /// Points a reset would discard across every window it refills.
        let wastedPercent: Int?
        /// Where the next long-window refill lands if the credit is spent now.
        let creditRefillAt: Date?
    }

    /// Remaining quota at which the maximising strategy refills a long window.
    static let headroomPercent = 20

    /// Remaining quota that makes an expiring credit worth spending.
    static let expiryPressurePercent = 50

    /// A short block is not worth a scarce credit on its own.
    static let minimumUsefulBlockMinutes = 30

    static func recommend(
        windows: [UsageWindow],
        samples: [QuotaHistorySample],
        summary: CodexRateLimitResetCreditsSummary?,
        forecast: ResetForecast?,
        now: Date,
        strategy: ResetStrategy = .bridge,
        surge: UsageSurge? = nil,
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

        let outlooks = QuotaOutlook.outlooks(windows: windows, samples: samples, now: now)
        let longOutlooks = outlooks.filter(\.isLongWindow)
        let tightest = longOutlooks.min { $0.window.remainingPercent < $1.window.remainingPercent }

        // 1. Would the account be blocked before the next refill? A learned demand
        // curve, optionally raised by a declared burst, answers what a single rate
        // cannot. This outranks every heuristic below because it is the actual cost
        // a credit removes.
        if let demand = ResetCreditDemand.evaluate(
            windows: windows, samples: samples, surge: surge, now: now
        ), demand.blockedMinutesWithoutCredit >= minimumUsefulBlockMinutes,
           demand.blockedMinutesAfterCredit <= 15 {
            return Recommendation(
                action: .useNow,
                windowName: demand.windowName,
                windowPercent: demand.remainingPercent,
                exhaustionAt: demand.emptyAt,
                probability: nil,
                expectedResetAt: nil,
                expiresAt: soonestExpiry,
                creditTitle: expiring?.title,
                recommendedAt: now,
                blockedMinutes: demand.blockedMinutesWithoutCredit,
                wastedPercent: demand.wastedPercent,
                creditRefillAt: demand.refillAfterCredit
            )
        }

        // 2. Without enough history, fall back to the active-time outlook.
        if let risk = longOutlooks
            .compactMap({ outlook -> (name: String, percent: Int, at: Date)? in
                guard let at = outlook.coverage.exhaustionDate else { return nil }
                return (outlook.window.name, outlook.window.remainingPercent, at)
            })
            .min(by: { $0.at < $1.at }) {
            return Recommendation(
                action: .useNow,
                windowName: risk.name,
                windowPercent: risk.percent,
                exhaustionAt: risk.at,
                probability: nil,
                expectedResetAt: nil,
                expiresAt: soonestExpiry,
                creditTitle: expiring?.title,
                recommendedAt: now,
                blockedMinutes: nil,
                wastedPercent: nil,
                creditRefillAt: nil
            )
        }

        // 3. A likely automatic reset removes the reason to spend anything, as long
        // as it arrives before the credit would expire.
        if let forecast,
           forecast.probability >= probabilityThreshold,
           let expected = forecast.nextExpectedAt ?? forecast.lastResetAt,
           expected > now,
           soonestExpiry.map({ expected < $0 }) ?? true {
            return Recommendation(
                action: .waitForAutomaticReset,
                windowName: tightest?.window.name,
                windowPercent: tightest?.window.remainingPercent,
                exhaustionAt: nil,
                probability: forecast.probability,
                expectedResetAt: expected,
                expiresAt: soonestExpiry,
                creditTitle: expiring?.title,
                recommendedAt: expected,
                blockedMinutes: nil,
                wastedPercent: nil,
                creditRefillAt: nil
            )
        }

        // 4. Maximising: a long window that is already low is worth refilling even
        // when it would technically last, because the point is to keep working.
        if strategy == .maximize,
           let tightest,
           tightest.window.remainingPercent <= headroomPercent {
            return Recommendation(
                action: .useHeadroom,
                windowName: tightest.window.name,
                windowPercent: tightest.window.remainingPercent,
                exhaustionAt: nil,
                probability: nil,
                expectedResetAt: nil,
                expiresAt: soonestExpiry,
                creditTitle: expiring?.title,
                recommendedAt: now,
                blockedMinutes: nil,
                wastedPercent: nil,
                creditRefillAt: nil
            )
        }

        // 5. An expiring credit is wasted once it lapses, so spend it while a long
        // window is already drawn down.
        if let soonestExpiry,
           soonestExpiry.timeIntervalSince(now) <= expiryWarning,
           let tightest,
           tightest.window.remainingPercent <= expiryPressurePercent {
            return Recommendation(
                action: .useBeforeExpiry,
                windowName: tightest.window.name,
                windowPercent: tightest.window.remainingPercent,
                exhaustionAt: nil,
                probability: nil,
                expectedResetAt: nil,
                expiresAt: soonestExpiry,
                creditTitle: expiring?.title,
                recommendedAt: soonestExpiry,
                blockedMinutes: nil,
                wastedPercent: nil,
                creditRefillAt: nil
            )
        }

        return Recommendation(
            action: .hold,
            windowName: tightest?.window.name,
            windowPercent: tightest?.window.remainingPercent,
            exhaustionAt: nil,
            probability: nil,
            expectedResetAt: tightest?.window.resetsAt,
            expiresAt: soonestExpiry,
            creditTitle: expiring?.title,
            recommendedAt: tightest?.window.resetsAt,
            blockedMinutes: nil,
            wastedPercent: nil,
            creditRefillAt: nil
        )
    }
}
