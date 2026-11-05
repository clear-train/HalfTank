import XCTest
@testable import CodexMeterCore

final class ResetForecastTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testParsesTheTrackerDocument() throws {
        let forecast = try parse(Self.samplePayload)

        XCTAssertEqual(forecast.didResetToday, false)
        XCTAssertEqual(forecast.probability, 0.2956254989378396, accuracy: 0.0001)
        XCTAssertEqual(forecast.probabilityPercent, 30)
        XCTAssertEqual(forecast.signals.map(\.key), ["baseline", "cooldown", "announcement", "sleep"])
        XCTAssertEqual(forecast.signals.first?.value, "~5d")
        XCTAssertEqual(forecast.signals.first?.impactPoints, 33)
        XCTAssertEqual(forecast.signals.last?.impactPoints, 0)
        XCTAssertNotNil(forecast.lastResetAt)
        XCTAssertNotNil(forecast.nextExpectedAt)
        XCTAssertEqual(forecast.fetchedAt, fetchedAt)
    }

    func testAnnouncedResetIsReported() throws {
        let forecast = try parse(Self.samplePayload.replacingOccurrences(of: "\"status\":\"no\"", with: "\"status\":\"yes\""))
        XCTAssertEqual(forecast.didResetToday, true)
    }

    func testUnknownStatusBecomesUnavailableInsteadOfGuessing() throws {
        let forecast = try parse(Self.samplePayload.replacingOccurrences(of: "\"status\":\"no\"", with: "\"status\":\"unknown\""))
        XCTAssertNil(forecast.didResetToday)
    }

    func testProbabilityIsClampedToARatio() throws {
        let high = try parse(Self.samplePayload.replacingOccurrences(of: "0.2956254989378396", with: "1.4"))
        XCTAssertEqual(high.probability, 1)
        XCTAssertEqual(high.probabilityPercent, 100)

        let low = try parse(Self.samplePayload.replacingOccurrences(of: "0.2956254989378396", with: "-0.2"))
        XCTAssertEqual(low.probability, 0)
    }

    func testSignalsTolerateNumbersAndMissingTitles() throws {
        let payload = """
        {"prediction":{"probability":0.5,"signals":[{"key":"baseline","value":5,"impactPts":33},{"value":"orphan"}]}}
        """
        let forecast = try parse(payload)
        XCTAssertEqual(forecast.signals.count, 1)
        XCTAssertEqual(forecast.signals[0].value, "5")
        XCTAssertNil(forecast.lastResetAt)
        XCTAssertNil(forecast.nextExpectedAt)
        XCTAssertNil(forecast.didResetToday)
    }

    func testHalfHourlyAndSecondPrecisionTimestampsParse() throws {
        let payload = """
        {"status":{"status":"no","lastResetAt":"2026-11-02T05:42:26Z"},
         "prediction":{"probability":0.4,"nextExpectedAt":"2026-11-06T18:32:17.000Z"}}
        """
        let forecast = try parse(payload)
        XCTAssertNotNil(forecast.lastResetAt)
        XCTAssertNotNil(forecast.nextExpectedAt)
    }

    func testMissingPredictionIsRejected() {
        XCTAssertThrowsError(try parse(#"{"status":{"status":"no"}}"#)) { error in
            XCTAssertEqual(error as? ResetForecastError, .invalidPayload)
        }
    }

    func testMalformedDocumentIsRejected() {
        XCTAssertThrowsError(try parse("not json"))
        XCTAssertThrowsError(try parse(#"{"prediction":"nope"}"#))
    }

    func testRefreshIsThrottledToTheHourlyTrackerCadence() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertTrue(ResetForecastSchedule.shouldRefresh(lastAttemptAt: nil, now: now))
        XCTAssertFalse(ResetForecastSchedule.shouldRefresh(lastAttemptAt: now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(ResetForecastSchedule.shouldRefresh(lastAttemptAt: now.addingTimeInterval(-59 * 60), now: now))
        XCTAssertTrue(ResetForecastSchedule.shouldRefresh(lastAttemptAt: now.addingTimeInterval(-61 * 60), now: now))
    }

    private func parse(_ payload: String) throws -> ResetForecast {
        try ResetForecastParser.parse(Data(payload.utf8), fetchedAt: fetchedAt)
    }

    private static let samplePayload = """
    {
      "status": {"status":"no","decidedAt":"2026-11-02T05:42:26.000Z","lastResetAt":"2026-11-02T05:42:26.000Z"},
      "prediction": {
        "probability": 0.2956254989378396,
        "signals": [
          {"key":"baseline","value":"~5d","impactPts":33},
          {"key":"cooldown","value":"50h","impactPts":-3},
          {"key":"announcement","value":"0","impactPts":0},
          {"key":"sleep","value":"0","impactPts":0}
        ],
        "nextExpectedAt": "2026-11-06T18:32:17.000Z"
      },
      "statusHash": "no::2026-11-02T05:42:26.000Z:2026-11-02T05:42:26.000Z",
      "lastPolledAt": "2026-11-04T07:00:14.283Z",
      "nextSyncAt": "2026-11-04T08:00:14.283Z",
      "seeded": true,
      "resets": [{"at":"2026-10-29T16:56:07.000Z","tweetId":"2115850175868727621"}]
    }
    """
}
