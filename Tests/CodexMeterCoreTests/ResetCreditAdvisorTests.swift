@testable import CodexMeterCore
import XCTest

final class ResetCreditAdvisorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let week = 7 * 24 * 60

    func testNoCreditsMeansNoAdvice() {
        XCTAssertNil(ResetCreditAdvisor.recommend(
            windows: [window(remaining: 40)],
            samples: [],
            summary: nil,
            forecast: nil,
            now: now
        ))
        XCTAssertNil(ResetCreditAdvisor.recommend(
            windows: [window(remaining: 40)],
            samples: [],
            summary: CodexRateLimitResetCreditsSummary(availableCount: 0, credits: []),
            forecast: nil,
            now: now
        ))
    }

    func testLongWindowThatCannotReachItsResetIsSpentNow() {
        let target = window(
            remaining: 40,
            resetsAt: now.addingTimeInterval(4 * 3600),
            durationMins: week
        )

        let recommendation = ResetCreditAdvisor.recommend(
            windows: [target],
            samples: drainingSamples(for: target, from: 60, per: 5, stepMinutes: 10, count: 5),
            summary: summary(expiresAt: now.addingTimeInterval(10 * 24 * 3600)),
            forecast: nil,
            now: now
        )

        XCTAssertEqual(recommendation?.action, .useNow)
        XCTAssertEqual(recommendation?.windowName, target.name)
        XCTAssertEqual(recommendation?.windowPercent, 40)
        XCTAssertNotNil(recommendation?.exhaustionAt)
    }

    func testShortWindowNeverTriggersACreditSuggestion() {
        // A five-hour window refills on its own; burning a banked reset for it
        // would be waste even when it is nearly empty.
        let target = window(remaining: 3, resetsAt: now.addingTimeInterval(3 * 3600), durationMins: 5 * 60)

        let recommendation = ResetCreditAdvisor.recommend(
            windows: [target],
            samples: drainingSamples(for: target, from: 20, per: 5, stepMinutes: 5, count: 4),
            summary: summary(expiresAt: now.addingTimeInterval(10 * 24 * 3600)),
            forecast: nil,
            now: now,
            strategy: .maximize
        )

        XCTAssertEqual(recommendation?.action, .hold)
        XCTAssertNil(recommendation?.windowName)
    }

    func testHoldNamesTheLongWindowAndWhenItRefills() {
        let target = window(
            remaining: 95,
            resetsAt: now.addingTimeInterval(5 * 24 * 3600),
            durationMins: week
        )

        let recommendation = ResetCreditAdvisor.recommend(
            windows: [target],
            samples: [],
            summary: summary(expiresAt: now.addingTimeInterval(20 * 24 * 3600)),
            forecast: nil,
            now: now
        )

        XCTAssertEqual(recommendation?.action, .hold)
        XCTAssertEqual(recommendation?.windowName, target.name)
        XCTAssertEqual(recommendation?.windowPercent, 95)
        XCTAssertEqual(recommendation?.recommendedAt, target.resetsAt)
    }

    func testAdviceWaitsForALikelyAutomaticReset() {
        let forecast = ResetForecast(
            didResetToday: false,
            lastResetAt: now.addingTimeInterval(-24 * 3600),
            probability: 0.72,
            signals: [],
            nextExpectedAt: now.addingTimeInterval(2 * 24 * 3600),
            fetchedAt: now,
            sourceURL: nil
        )

        let recommendation = ResetCreditAdvisor.recommend(
            windows: [window(remaining: 80, resetsAt: now.addingTimeInterval(6 * 24 * 3600), durationMins: week)],
            samples: [],
            summary: summary(expiresAt: now.addingTimeInterval(10 * 24 * 3600)),
            forecast: forecast,
            now: now
        )

        XCTAssertEqual(recommendation?.action, .waitForAutomaticReset)
        XCTAssertEqual(recommendation?.probability ?? 0, 0.72, accuracy: 0.001)
    }

    func testAdviceDoesNotWaitWhenTheCreditExpiresBeforeTheExpectedReset() {
        let forecast = ResetForecast(
            didResetToday: false,
            lastResetAt: now.addingTimeInterval(-24 * 3600),
            probability: 0.9,
            signals: [],
            nextExpectedAt: now.addingTimeInterval(3 * 24 * 3600),
            fetchedAt: now,
            sourceURL: nil
        )

        let recommendation = ResetCreditAdvisor.recommend(
            windows: [window(remaining: 90, resetsAt: now.addingTimeInterval(6 * 24 * 3600), durationMins: week)],
            samples: [],
            summary: summary(expiresAt: now.addingTimeInterval(6 * 3600)),
            forecast: forecast,
            now: now
        )

        XCTAssertNotEqual(recommendation?.action, .waitForAutomaticReset)
    }

    func testExpiringCreditIsSpentWhileALongWindowIsDrawnDown() {
        let target = window(remaining: 40, resetsAt: now.addingTimeInterval(4 * 24 * 3600), durationMins: week)

        let recommendation = ResetCreditAdvisor.recommend(
            windows: [target],
            samples: [],
            summary: summary(expiresAt: now.addingTimeInterval(12 * 3600)),
            forecast: nil,
            now: now
        )

        XCTAssertEqual(recommendation?.action, .useBeforeExpiry)
        XCTAssertNotNil(recommendation?.expiresAt)
        XCTAssertEqual(recommendation?.windowName, target.name)
    }

    func testExpiredCreditsProduceNoAdvice() {
        let summary = CodexRateLimitResetCreditsSummary(
            availableCount: 1,
            credits: [credit(id: "c1", title: "Grant", grantedAt: now.addingTimeInterval(-72 * 3600), expiresAt: now.addingTimeInterval(-1))]
        )

        XCTAssertNil(ResetCreditAdvisor.recommend(
            windows: [window(remaining: 40)],
            samples: [],
            summary: summary,
            forecast: nil,
            now: now
        ))
    }

    // MARK: - Strategies

    func testMaximizeRefillsALongWindowThatIsAlreadyLow() {
        let target = window(remaining: 15, resetsAt: now.addingTimeInterval(2 * 24 * 3600), durationMins: week)

        let recommendation = ResetCreditAdvisor.recommend(
            windows: [target],
            samples: [],
            summary: summary(expiresAt: now.addingTimeInterval(20 * 24 * 3600)),
            forecast: nil,
            now: now,
            strategy: .maximize
        )

        XCTAssertEqual(recommendation?.action, .useHeadroom)
        XCTAssertEqual(recommendation?.windowName, target.name)
        XCTAssertEqual(recommendation?.windowPercent, 15)
    }

    func testBridgeHoldsALowLongWindowThatStillLasts() {
        let target = window(remaining: 15, resetsAt: now.addingTimeInterval(2 * 24 * 3600), durationMins: week)

        let recommendation = ResetCreditAdvisor.recommend(
            windows: [target],
            samples: [],
            summary: summary(expiresAt: now.addingTimeInterval(20 * 24 * 3600)),
            forecast: nil,
            now: now,
            strategy: .bridge
        )

        XCTAssertEqual(recommendation?.action, .hold)
        XCTAssertEqual(recommendation?.windowName, target.name)
    }

    func testMaximizeHoldsWhileTheLongWindowStillHasRoom() {
        let target = window(remaining: 90, resetsAt: now.addingTimeInterval(5 * 24 * 3600), durationMins: week)

        let recommendation = ResetCreditAdvisor.recommend(
            windows: [target],
            samples: [],
            summary: summary(expiresAt: now.addingTimeInterval(20 * 24 * 3600)),
            forecast: nil,
            now: now,
            strategy: .maximize
        )

        XCTAssertEqual(recommendation?.action, .hold)
        XCTAssertEqual(recommendation?.recommendedAt, target.resetsAt)
    }

    // MARK: - Mixed windows

    func testShortWindowIsIgnoredWhenALongWindowDecidesTheAdvice() {
        // The five-hour window is nearly empty, but the weekly window is healthy,
        // so the answer is to keep the credit.
        let fiveHour = window(
            remaining: 2,
            resetsAt: now.addingTimeInterval(2 * 3600),
            durationMins: 5 * 60,
            id: "five"
        )
        let weekly = window(
            remaining: 70,
            resetsAt: now.addingTimeInterval(5 * 24 * 3600),
            durationMins: week,
            id: "weekly"
        )

        let recommendation = ResetCreditAdvisor.recommend(
            windows: [fiveHour, weekly],
            samples: [],
            summary: summary(expiresAt: now.addingTimeInterval(20 * 24 * 3600)),
            forecast: nil,
            now: now,
            strategy: .bridge
        )

        XCTAssertEqual(recommendation?.action, .hold)
        XCTAssertEqual(recommendation?.windowName, weekly.name)
    }

    // MARK: - Demand

    func testDeclaredBurstTurnsAHoldIntoASpentCredit() {
        // Eight points left, reset in thirty-six hours, and a learned rate of a
        // fifth of a point per hour: the week survives on its own, but three-fold
        // work for eight hours runs it dry around twenty-four hours in.
        let target = window(
            remaining: 8,
            resetsAt: now.addingTimeInterval(36 * 3600),
            durationMins: week,
            id: "weekly"
        )
        let samples = drainingSamples(for: target, from: 17, per: 1, stepMinutes: 300, count: 10)
        let credits = summary(expiresAt: now.addingTimeInterval(20 * 24 * 3600))

        let calm = ResetCreditAdvisor.recommend(
            windows: [target],
            samples: samples,
            summary: credits,
            forecast: nil,
            now: now
        )
        let bursting = ResetCreditAdvisor.recommend(
            windows: [target],
            samples: samples,
            summary: credits,
            forecast: nil,
            now: now,
            surge: UsageSurge(startedAt: now, hours: 8)
        )

        XCTAssertEqual(calm?.action, .hold)
        XCTAssertEqual(bursting?.action, .useNow)
        XCTAssertGreaterThan(bursting?.blockedMinutes ?? 0, 60)
        XCTAssertEqual(bursting?.wastedPercent, 92)
        XCTAssertEqual(bursting?.creditRefillAt, now.addingTimeInterval(7 * 24 * 3600))
    }

    // MARK: - Fixtures

    private func window(
        remaining: Int,
        resetsAt: Date? = nil,
        durationMins: Int = 300,
        id: String = "codex-primary"
    ) -> UsageWindow {
        UsageWindow(
            id: id,
            name: "Window",
            usedPercent: 100 - remaining,
            windowDurationMins: durationMins,
            resetsAt: resetsAt ?? now.addingTimeInterval(2 * 3600)
        )
    }

    private func summary(expiresAt: Date) -> CodexRateLimitResetCreditsSummary {
        CodexRateLimitResetCreditsSummary(
            availableCount: 1,
            credits: [credit(id: "c1", title: "Grant", grantedAt: now.addingTimeInterval(-3600), expiresAt: expiresAt)]
        )
    }

    private func credit(
        id: String,
        title: String?,
        grantedAt: Date,
        expiresAt: Date?
    ) -> CodexRateLimitResetCredit {
        CodexRateLimitResetCredit(
            id: id,
            title: title,
            description: nil,
            grantedAt: grantedAt,
            expiresAt: expiresAt
        )
    }

    private func drainingSamples(
        for window: UsageWindow,
        from start: Int,
        per step: Int,
        stepMinutes: Int,
        count: Int
    ) -> [QuotaHistorySample] {
        (0..<count).map { index in
            QuotaHistorySample(
                id: Int64(index + 1),
                windowID: window.historyID,
                windowName: window.name,
                sampledAt: now.addingTimeInterval(
                    TimeInterval((index - (count - 1)) * stepMinutes * 60)
                ),
                remainingPercent: start - index * step,
                windowDurationMins: window.windowDurationMins,
                resetsAt: window.resetsAt,
                startsSegment: index == 0,
                isAnchor: false,
                isStale: false,
                source: .refresh
            )
        }
    }
}
