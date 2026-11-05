@testable import CodexMeterCore
import XCTest

final class QuotaOutlookTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDrainingFasterThanTheResetRunsOut() throws {
        let window = self.window(remaining: 40, resetsAt: now.addingTimeInterval(4 * 3600))

        let coverage = QuotaOutlook.coverage(
            for: window,
            samples: samples(for: window, from: 60, per: 5, stepMinutes: 10, count: 5),
            now: now
        )

        let exhaustedAt = try XCTUnwrap(coverage.exhaustionDate)
        XCTAssertLessThan(exhaustedAt, window.resetsAt ?? .distantFuture)
    }

    func testSlowConsumptionLastsUntilTheReset() {
        // One point every five minutes leaves fifty points well past a reset that
        // is only ten minutes away.
        let window = self.window(remaining: 50, resetsAt: now.addingTimeInterval(10 * 60))

        let coverage = QuotaOutlook.coverage(
            for: window,
            samples: samples(for: window, from: 60, per: 5, stepMinutes: 5, count: 5),
            now: now
        )

        XCTAssertEqual(coverage, .lastsUntilReset)
    }

    func testFlatSamplesReportIdleInsteadOfARate() throws {
        let window = self.window(remaining: 9, resetsAt: now.addingTimeInterval(15 * 3600))
        let flat = (0..<4).map { index in
            sample(
                window: window,
                remaining: 9,
                at: now.addingTimeInterval(TimeInterval((index - 3) * 15 * 60))
            )
        }

        let coverage = QuotaOutlook.coverage(for: window, samples: flat, now: now)

        guard case let .idle(since) = coverage else {
            return XCTFail("Expected idle coverage, got \(coverage)")
        }
        XCTAssertEqual(since, flat.first?.sampledAt)
    }

    func testNoHistoryIsUnknown() {
        let window = self.window(remaining: 9, resetsAt: now.addingTimeInterval(15 * 3600))

        XCTAssertEqual(QuotaOutlook.coverage(for: window, samples: [], now: now), .unknown)
    }

    func testOnlyDayLongWindowsCountAsLong() {
        XCTAssertTrue(QuotaOutlook.isLongWindow(window(remaining: 9, durationMins: 7 * 24 * 60)))
        XCTAssertTrue(QuotaOutlook.isLongWindow(window(remaining: 9, durationMins: 24 * 60)))
        XCTAssertFalse(QuotaOutlook.isLongWindow(window(remaining: 9, durationMins: 5 * 60)))
        XCTAssertFalse(QuotaOutlook.isLongWindow(window(remaining: 9, durationMins: nil)))
    }

    func testOutlooksKeepOneRowPerWindow() {
        let fiveHour = window(remaining: 89, durationMins: 300, id: "five")
        let weekly = window(remaining: 9, durationMins: 7 * 24 * 60, id: "weekly")

        let outlooks = QuotaOutlook.outlooks(
            windows: [fiveHour, weekly],
            samples: samples(for: weekly, from: 60, per: 5, stepMinutes: 10, count: 5),
            now: now
        )

        XCTAssertEqual(outlooks.map(\.window.id), ["five", "weekly"])
        XCTAssertFalse(outlooks[0].isLongWindow)
        XCTAssertTrue(outlooks[1].isLongWindow)
        XCTAssertNotNil(outlooks[1].coverage.exhaustionDate)
    }

    // MARK: - Fixtures

    private func window(
        remaining: Int,
        resetsAt: Date? = nil,
        durationMins: Int? = 300,
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

    private func sample(window: UsageWindow, remaining: Int, at date: Date) -> QuotaHistorySample {
        QuotaHistorySample(
            id: 0,
            windowID: window.historyID,
            windowName: window.name,
            sampledAt: date,
            remainingPercent: remaining,
            windowDurationMins: window.windowDurationMins,
            resetsAt: window.resetsAt,
            startsSegment: false,
            isAnchor: false,
            isStale: false,
            source: .refresh
        )
    }

    private func samples(
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
