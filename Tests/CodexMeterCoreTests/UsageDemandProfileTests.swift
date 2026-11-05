import XCTest
@testable import CodexMeterCore

final class UsageDemandProfileTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    /// Drains `percentPerHour`, recording one sample every ten minutes. Quota moves
    /// in whole points, so the helper floors the cumulative drain the same way the
    /// real sampler does.
    private func samples(
        windowID: String,
        from start: Date,
        hours: Int,
        startPercent: Int,
        percentPerHour: Double,
        resetsAt: Date? = nil,
        durationMins: Int? = 10_080,
        windowName: String = "每周额度"
    ) -> [QuotaHistorySample] {
        let count = hours * 6
        return (0...count).map { step in
            let drained = (Double(step) / 6) * percentPerHour
            let remaining = max(0, startPercent - Int(drained))
            return QuotaHistorySample(
                id: Int64(step),
                windowID: windowID,
                windowName: windowName,
                sampledAt: start.addingTimeInterval(Double(step) * 600),
                remainingPercent: remaining,
                windowDurationMins: durationMins,
                resetsAt: resetsAt,
                startsSegment: step == 0,
                isAnchor: step == 0,
                isStale: false,
                source: .refresh
            )
        }
    }

    func testShortHistoryFallsBackToTheAverageRate() {
        let start = date("2026-11-01T00:00:00Z")
        let samples = samples(
            windowID: "duration:10080:weekly",
            from: start,
            hours: 48,
            startPercent: 100,
            percentPerHour: 1
        )

        let profile = UsageDemandProfile.build(
            samples: samples,
            now: start.addingTimeInterval(48 * 3600),
            calendar: calendar
        )

        XCTAssertNotNil(profile)
        XCTAssertTrue(profile?.isFlat == true)
        XCTAssertEqual(profile?.averagePercentPerHour ?? 0, 1, accuracy: 0.2)
    }

    func testTwoWeeksOfHistoryLearnsTheBusyHours() {
        let start = date("2026-10-01T00:00:00Z")
        // Sixteen days: 6 points during 09:00, 0.2 points per hour otherwise.
        var samples: [QuotaHistorySample] = []
        var remaining = 600.0
        for hour in 0...(16 * 24) {
            let sampledAt = start.addingTimeInterval(Double(hour) * 3600)
            let consumed = calendar.component(.hour, from: sampledAt) == 9 ? 6.0 : 0.2
            remaining = max(0, remaining - consumed)
            samples.append(
                QuotaHistorySample(
                    id: Int64(hour),
                    windowID: "duration:10080:weekly",
                    windowName: "每周额度",
                    sampledAt: sampledAt,
                    remainingPercent: Int(remaining.rounded(.down)),
                    windowDurationMins: 10_080,
                    resetsAt: nil,
                    startsSegment: hour == 0,
                    isAnchor: hour == 0,
                    isStale: false,
                    source: .refresh
                )
            )
        }

        let profile = UsageDemandProfile.build(
            samples: samples,
            now: start.addingTimeInterval(Double(16 * 24) * 3600),
            calendar: calendar
        )

        // A drop of six points is observed at 10:00, so the busy hour is the one
        // just before it; compare the extremes rather than a fixed bucket.
        let busy = profile?.hourlyPercentPerHour.max() ?? 0
        let quiet = profile?.hourlyPercentPerHour.min() ?? 0

        XCTAssertFalse(profile?.isFlat ?? true)
        XCTAssertGreaterThan(busy, quiet * 2)
        XCTAssertLessThan(quiet, 1)
    }

    func testSurgeRaisesConsumptionOnlyInsideItsWindow() {
        let start = date("2026-11-05T00:00:00Z")
        let surge = UsageSurge(startedAt: start, hours: 4)
        let profile = UsageDemandProfile(
            hourlyPercentPerHour: Array(repeating: 1, count: 168),
            averagePercentPerHour: 1,
            observedDays: 30
        )

        let during = profile.consumed(
            from: start,
            to: start.addingTimeInterval(2 * 3600),
            surge: surge,
            calendar: calendar
        )
        let after = profile.consumed(
            from: start.addingTimeInterval(5 * 3600),
            to: start.addingTimeInterval(7 * 3600),
            surge: surge,
            calendar: calendar
        )

        XCTAssertEqual(during, 6, accuracy: 0.01)
        XCTAssertEqual(after, 2, accuracy: 0.01)
    }

    func testDemandFindsTheGapBeforeTheNextRefill() {
        let now = date("2026-11-05T12:00:00Z")
        let reset = now.addingTimeInterval(48 * 3600)
        let samples = samples(
            windowID: "duration:10080:weekly",
            from: now.addingTimeInterval(-48 * 3600),
            hours: 48,
            startPercent: 34,
            percentPerHour: 0.5,
            resetsAt: reset
        )
        let window = UsageWindow(
            id: "opencode-go-weekly",
            name: "每周额度",
            usedPercent: 90,
            windowDurationMins: 10_080,
            resetsAt: reset
        )

        let demand = ResetCreditDemand.evaluate(
            windows: [window],
            samples: samples,
            surge: nil,
            now: now,
            calendar: calendar
        )

        XCTAssertNotNil(demand)
        // Ten points left at half a point per hour: dry after twenty hours, so the
        // account sits at zero for the remaining twenty-eight.
        XCTAssertEqual(demand?.blockedMinutesWithoutCredit ?? 0, 28 * 60, accuracy: 90)
        XCTAssertEqual(demand?.blockedMinutesAfterCredit ?? -1, 0, accuracy: 30)
        XCTAssertEqual(demand?.wastedPercent, 90)
        XCTAssertEqual(demand?.refillAfterCredit, now.addingTimeInterval(7 * 24 * 3600))
    }

    func testShortWindowsNeverProduceDemand() {
        let now = date("2026-11-05T12:00:00Z")
        let window = UsageWindow(
            id: "codex",
            name: "5 小时额度",
            usedPercent: 100,
            windowDurationMins: 300,
            resetsAt: now.addingTimeInterval(3600)
        )

        let demand = ResetCreditDemand.evaluate(
            windows: [window],
            samples: [],
            surge: nil,
            now: now,
            calendar: calendar
        )

        XCTAssertNil(demand)
    }

    func testBurstCreatesABlockThatIsNotThereOtherwise() {
        let now = date("2026-11-05T12:00:00Z")
        let reset = now.addingTimeInterval(36 * 3600)
        // Eight points left at 0.2 per hour lasts forty hours, past the reset. A
        // three-fold burst burns through it in about a day.
        let samples = samples(
            windowID: "duration:10080:weekly",
            from: now.addingTimeInterval(-72 * 3600),
            hours: 72,
            startPercent: 22,
            percentPerHour: 0.2,
            resetsAt: reset
        )
        let window = UsageWindow(
            id: "opencode-go-weekly",
            name: "每周额度",
            usedPercent: 92,
            windowDurationMins: 10_080,
            resetsAt: reset
        )

        let calm = ResetCreditDemand.evaluate(
            windows: [window],
            samples: samples,
            surge: nil,
            now: now,
            calendar: calendar
        )
        let bursting = ResetCreditDemand.evaluate(
            windows: [window],
            samples: samples,
            surge: UsageSurge(startedAt: now, hours: 8),
            now: now,
            calendar: calendar
        )

        XCTAssertNil(calm)
        XCTAssertNotNil(bursting)
        XCTAssertGreaterThan(bursting?.blockedMinutesWithoutCredit ?? 0, 60)
        XCTAssertEqual(bursting?.blockedMinutesAfterCredit ?? -1, 0, accuracy: 30)
    }
}
