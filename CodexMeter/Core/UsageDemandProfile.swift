import Foundation

/// A declared burst of work. A banked reset can only help if the account would
/// otherwise be blocked before its next refill, and the future demand is the one
/// input history cannot infer: a user knows about tomorrow morning's refactor
/// long before any sample shows it.
struct UsageSurge: Equatable, Sendable {
    /// How much harder a declared burst consumes than the learned profile.
    static let multiplier = 3.0
    static let defaultHours = 4
    static let hourOptions = [2, 4, 8]

    let startedAt: Date
    let hours: Int

    var endsAt: Date {
        startedAt.addingTimeInterval(TimeInterval(hours) * 3600)
    }

    func isActive(at date: Date) -> Bool {
        date >= startedAt && date < endsAt
    }

    func multiplier(at date: Date) -> Double {
        isActive(at: date) ? Self.multiplier : 1
    }

    func remainingLabel(at date: Date) -> String {
        let minutes = max(0, Int(endsAt.timeIntervalSince(date) / 60))
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }
}

/// Learned consumption rate per hour of the week.
///
/// The reset advice needs to answer "will this window run dry before its own
/// reset", and a single average rate cannot: quota burns in bursts, and the same
/// hour on a weekend is not the same as a workday evening. The profile turns the
/// recorded samples into 168 hourly rates, falling back to the average whenever
/// a bucket has too little evidence or the account has less than two weeks of
/// history.
struct UsageDemandProfile: Equatable, Sendable {
    static let hoursPerWeek = 168
    /// Below this much history every hour uses the average rate.
    static let minimumObservedDays = 14
    /// An hourly bucket with less observed time than this is too noisy to trust.
    static let minimumBucketHours = 2.0
    /// A single pair of samples spanning more than this is treated as unknown.
    static let maximumPairHours = 6.0

    /// Percentage points per hour, Sunday 00:00 first.
    let hourlyPercentPerHour: [Double]
    let averagePercentPerHour: Double
    let observedDays: Int

    var isFlat: Bool {
        observedDays < Self.minimumObservedDays
    }

    static func build(
        samples: [QuotaHistorySample],
        now: Date,
        calendar: Calendar = .current
    ) -> UsageDemandProfile? {
        let usable = samples
            .filter { !$0.isStale }
            .sorted { $0.sampledAt < $1.sampledAt }
        guard usable.count >= 2 else { return nil }

        var consumed = [Double](repeating: 0, count: hoursPerWeek)
        var observed = [Double](repeating: 0, count: hoursPerWeek)
        var totalConsumed = 0.0
        var totalHours = 0.0
        var earliest: Date?

        // Quota is recorded in whole points, so a "drop" of one point may have
        // happened anywhere since the last change. Attributing it to the gap
        // between samples, rather than the step between them, keeps a slow drain
        // from looking six times faster than it is.
        var lastChange: Date?
        var previousValue: Int?

        for sample in usable {
            if sample.startsSegment {
                previousValue = sample.remainingPercent
                lastChange = sample.sampledAt
                continue
            }
            let value = sample.remainingPercent
            defer { previousValue = value }

            guard let previous = previousValue else {
                lastChange = sample.sampledAt
                continue
            }
            guard value < previous else {
                // A refill or an idle stretch ends the current consumption window.
                lastChange = value == previous ? lastChange : sample.sampledAt
                continue
            }

            let from = lastChange ?? sample.sampledAt
            let hours = sample.sampledAt.timeIntervalSince(from) / 3600
            guard hours > 0, hours <= 24 else {
                lastChange = sample.sampledAt
                continue
            }

            let delta = Double(previous - value)
            earliest = earliest ?? from
            totalConsumed += delta
            totalHours += hours

            let rate = delta / hours
            var chunkStart = from
            while chunkStart < sample.sampledAt {
                let chunkEnd = min(sample.sampledAt, chunkStart.addingTimeInterval(900))
                let chunkHours = chunkEnd.timeIntervalSince(chunkStart) / 3600
                let index = hourIndex(for: chunkStart, calendar: calendar)
                consumed[index] += rate * chunkHours
                observed[index] += chunkHours
                chunkStart = chunkEnd
            }
            lastChange = sample.sampledAt
        }

        guard totalHours > 0, totalConsumed > 0 else { return nil }
        let average = totalConsumed / totalHours
        let days = earliest.map { Int(now.timeIntervalSince($0) / 86_400) } ?? 0

        var hourly = [Double](repeating: average, count: hoursPerWeek)
        if days >= minimumObservedDays {
            for index in 0..<hoursPerWeek where observed[index] >= minimumBucketHours {
                hourly[index] = consumed[index] / observed[index]
            }
        }

        return UsageDemandProfile(
            hourlyPercentPerHour: hourly,
            averagePercentPerHour: average,
            observedDays: days
        )
    }

    func percentPerHour(at date: Date, calendar: Calendar = .current) -> Double {
        guard !isFlat else { return averagePercentPerHour }
        return hourlyPercentPerHour[Self.hourIndex(for: date, calendar: calendar)]
    }

    /// Percentage points consumed between two instants, honouring a declared burst.
    func consumed(
        from start: Date,
        to end: Date,
        surge: UsageSurge? = nil,
        calendar: Calendar = .current
    ) -> Double {
        guard end > start else { return 0 }
        var total = 0.0
        var cursor = start
        while cursor < end {
            let chunkEnd = min(end, cursor.addingTimeInterval(900))
            let hours = chunkEnd.timeIntervalSince(cursor) / 3600
            let rate = percentPerHour(at: cursor, calendar: calendar)
                * (surge?.multiplier(at: cursor) ?? 1)
            total += rate * hours
            cursor = chunkEnd
        }
        return total
    }

    private static func hourIndex(for date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.weekday, .hour], from: date)
        let weekday = ((parts.weekday ?? 1) - 1) % 7
        let hour = (parts.hour ?? 0) % 24
        return min(max(weekday * 24 + hour, 0), hoursPerWeek - 1)
    }
}

/// Whether a banked reset would keep a long window alive until its next refill.
///
/// A reset is not extra quota: it refills now and restarts the weekly clock, so
/// the refill that would have arrived at the scheduled reset no longer happens.
/// Spending one is only worth it when the account would otherwise sit at zero
/// for part of the cycle, which is what the simulation here measures.
struct ResetCreditDemand: Equatable, Sendable {
    let windowName: String
    let remainingPercent: Int
    /// When the window is projected to hit zero without a credit.
    let emptyAt: Date
    let blockedMinutesWithoutCredit: Int
    /// When the next refill lands if the credit is spent now.
    let refillAfterCredit: Date
    let blockedMinutesAfterCredit: Int
    /// Points discarded across every window the reset refills.
    let wastedPercent: Int

    static func evaluate(
        windows: [UsageWindow],
        samples: [QuotaHistorySample],
        surge: UsageSurge?,
        now: Date,
        calendar: Calendar = .current
    ) -> ResetCreditDemand? {
        guard let profile = UsageDemandProfile.build(samples: samples, now: now, calendar: calendar) else {
            return nil
        }
        let longWindows = windows.filter { window in
            guard let minutes = window.windowDurationMins else { return false }
            return minutes >= 24 * 60
        }

        var worst: (window: UsageWindow, emptyAt: Date, blocked: Int)?
        for window in longWindows {
            guard let resetsAt = window.resetsAt, resetsAt > now else { continue }
            guard let result = blocked(from: now, until: resetsAt,
                                       startingQuota: Double(window.remainingPercent),
                                       profile: profile, surge: surge, calendar: calendar)
            else { continue }
            if worst == nil || result.emptyAt < worst!.emptyAt {
                worst = (window, result.emptyAt, result.blockedMinutes)
            }
        }
        guard let worst else { return nil }

        let lifetime = TimeInterval(worst.window.windowDurationMins ?? 7 * 24 * 60) * 60
        let refill = now.addingTimeInterval(lifetime)
        let after = blocked(from: now, until: refill, startingQuota: 100,
                            profile: profile, surge: surge, calendar: calendar)

        return ResetCreditDemand(
            windowName: worst.window.name,
            remainingPercent: worst.window.remainingPercent,
            emptyAt: worst.emptyAt,
            blockedMinutesWithoutCredit: worst.blocked,
            refillAfterCredit: refill,
            blockedMinutesAfterCredit: after?.blockedMinutes ?? 0,
            wastedPercent: windows.reduce(0) { $0 + max(0, 100 - $1.remainingPercent) }
        )
    }

    /// Returns the blocked time, or nil when the window survives to `deadline`.
    private static func blocked(
        from start: Date,
        until deadline: Date,
        startingQuota: Double,
        profile: UsageDemandProfile,
        surge: UsageSurge?,
        calendar: Calendar
    ) -> (emptyAt: Date, blockedMinutes: Int)? {
        var quota = startingQuota
        var cursor = start
        while cursor < deadline {
            let chunkEnd = min(deadline, cursor.addingTimeInterval(900))
            let hours = chunkEnd.timeIntervalSince(cursor) / 3600
            let rate = profile.percentPerHour(at: cursor, calendar: calendar)
                * (surge?.multiplier(at: cursor) ?? 1)
            let need = rate * hours
            if quota <= need {
                let share = need > 0 ? max(0, quota) / need : 1
                let emptyAt = cursor.addingTimeInterval(chunkEnd.timeIntervalSince(cursor) * share)
                return (emptyAt, Int((deadline.timeIntervalSince(emptyAt) / 60).rounded()))
            }
            quota -= need
            cursor = chunkEnd
        }
        return nil
    }
}
