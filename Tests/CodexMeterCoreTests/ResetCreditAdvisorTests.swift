@testable import CodexMeterCore
import XCTest

final class ResetCreditAdvisorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

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

    func testCreditIsSpentNowWhenQuotaCannotWaitForItsReset() {
        let target = window(remaining: 40, resetsAt: now.addingTimeInterval(4 * 3600))
        let summary = summary(expiresAt: now.addingTimeInterval(10 * 24 * 3600))

        let recommendation = ResetCreditAdvisor.recommend(
            windows: [target],
            samples: drainingSamples(for: target, from: 60, per: 5, stepMinutes: 10, count: 5),
            summary: summary,
            forecast: nil,
            now: now
        )

        XCTAssertEqual(recommendation?.action, .useNow)
        XCTAssertEqual(recommendation?.windowName, target.name)
        XCTAssertNotNil(recommendation?.exhaustionAt)
    }

    func testCreditIsHeldWhenTheOfficialResetArrivesFirst() {
        // Fifty points left burning at one point per minute still outlives a reset
        // that is only ten minutes away, so the window refills on its own.
        let target = window(remaining: 50, resetsAt: now.addingTimeInterval(10 * 60))

        let recommendation = ResetCreditAdvisor.recommend(
            windows: [target],
            samples: drainingSamples(for: target, from: 60, per: 5, stepMinutes: 5, count: 5),
            summary: summary(expiresAt: now.addingTimeInterval(30 * 24 * 3600)),
            forecast: nil,
            now: now
        )

        XCTAssertNotEqual(recommendation?.action, .useNow)
    }

    func testAdviceWaitsForALikelyAutomaticReset() {
        let summary = summary(expiresAt: now.addingTimeInterval(10 * 24 * 3600))
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
            windows: [window(remaining: 80, resetsAt: now.addingTimeInterval(6 * 24 * 3600))],
            samples: [],
            summary: summary,
            forecast: forecast,
            now: now
        )

        XCTAssertEqual(recommendation?.action, .waitForAutomaticReset)
        XCTAssertEqual(recommendation?.probability ?? 0, 0.72, accuracy: 0.001)
    }

    func testAdviceDoesNotWaitWhenTheCreditExpiresBeforeTheExpectedReset() {
        let summary = summary(expiresAt: now.addingTimeInterval(6 * 3600))
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
            windows: [window(remaining: 90, resetsAt: now.addingTimeInterval(6 * 24 * 3600))],
            samples: [],
            summary: summary,
            forecast: forecast,
            now: now
        )

        XCTAssertNotEqual(recommendation?.action, .waitForAutomaticReset)
    }

    func testAdviceSpendsAnExpiringCreditWhileQuotaBurnsFast() {
        // Eighty percent used with most of the window left is above the ideal pace.
        let target = window(remaining: 20, resetsAt: now.addingTimeInterval(4 * 24 * 3600), durationMins: 7 * 24 * 60)
        let summary = summary(expiresAt: now.addingTimeInterval(12 * 3600))

        let recommendation = ResetCreditAdvisor.recommend(
            windows: [target],
            samples: [],
            summary: summary,
            forecast: nil,
            now: now
        )

        XCTAssertEqual(recommendation?.action, .useBeforeExpiry)
        XCTAssertNotNil(recommendation?.expiresAt)
    }

    func testAdviceHoldsWhenNothingIsUrgent() {
        let target = window(remaining: 95, resetsAt: now.addingTimeInterval(5 * 24 * 3600), durationMins: 7 * 24 * 60)
        let summary = summary(expiresAt: now.addingTimeInterval(20 * 24 * 3600))

        let recommendation = ResetCreditAdvisor.recommend(
            windows: [target],
            samples: [],
            summary: summary,
            forecast: nil,
            now: now
        )

        XCTAssertEqual(recommendation?.action, .hold)
        XCTAssertNotNil(recommendation?.expiresAt)
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

    func testMaximizeUsesACreditWhenAWindowIsAtTheFloor() {
        let target = window(remaining: 3, resetsAt: now.addingTimeInterval(2 * 3600))

        let recommendation = ResetCreditAdvisor.recommend(
            windows: [target],
            samples: [],
            summary: summary(expiresAt: now.addingTimeInterval(20 * 24 * 3600)),
            forecast: nil,
            now: now,
            strategy: .maximize
        )

        XCTAssertEqual(recommendation?.action, .useAtFloor)
        XCTAssertEqual(recommendation?.windowName, target.name)
    }

    func testBridgeHoldsWhenAWindowIsAtTheFloorButItsResetIsStillAhead() {
        let target = window(remaining: 3, resetsAt: now.addingTimeInterval(2 * 3600))

        let recommendation = ResetCreditAdvisor.recommend(
            windows: [target],
            samples: [],
            summary: summary(expiresAt: now.addingTimeInterval(20 * 24 * 3600)),
            forecast: nil,
            now: now,
            strategy: .bridge
        )

        XCTAssertEqual(recommendation?.action, .hold)
    }

    func testMaximizeHoldsWhileQuotaStillHasRoomToBurn() {
        let target = window(
            remaining: 90,
            resetsAt: now.addingTimeInterval(5 * 24 * 3600),
            durationMins: 7 * 24 * 60
        )

        let recommendation = ResetCreditAdvisor.recommend(
            windows: [target],
            samples: [],
            summary: summary(expiresAt: now.addingTimeInterval(20 * 24 * 3600)),
            forecast: nil,
            now: now,
            strategy: .maximize
        )

        XCTAssertEqual(recommendation?.action, .hold)
    }

    func testMaximizeSpendsAnExpiringCreditWhileQuotaIsStillBurnable() {
        let target = window(
            remaining: 50,
            resetsAt: now.addingTimeInterval(5 * 24 * 3600),
            durationMins: 7 * 24 * 60
        )

        let recommendation = ResetCreditAdvisor.recommend(
            windows: [target],
            samples: [],
            summary: summary(expiresAt: now.addingTimeInterval(12 * 3600)),
            forecast: nil,
            now: now,
            strategy: .maximize
        )

        XCTAssertEqual(recommendation?.action, .useBeforeExpiry)
    }

    // MARK: - Fixtures

    private func window(
        remaining: Int,
        resetsAt: Date? = nil,
        durationMins: Int = 300
    ) -> UsageWindow {
        UsageWindow(
            id: "codex-primary",
            name: "5 hours",
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
