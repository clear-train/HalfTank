import XCTest
@testable import CodexMeterCore

/// Covers the two OpenCode Go payload shapes and the credential formats the app
/// reads from OpenCode's local data directory.
final class OpenCodeGoTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Command payload

    func testCommandPayloadParsesWrappedCursorResponse() throws {
        let data = Data("""
        {
          "location": {"directory": "/Users/example"},
          "data": {
            "workspace": {
              "id": "wrk_01",
              "name": "Default",
              "usageURL": "https://opencode.ai/console/wrk_01/activity/overview"
            },
            "go": {
              "rolling": {"percent": 14, "limited": false, "resetsAt": 1793700456000},
              "weekly": {"percent": 9, "limited": false, "resetsAt": 1794182400000},
              "monthly": {"percent": 11, "limited": true, "resetsAt": 1795413157000}
            },
            "budgets": []
          }
        }
        """.utf8)

        let snapshot = try OpenCodeGoUsageParser.parseCommandPayload(data, fetchedAt: now)

        XCTAssertEqual(snapshot.workspaceID, "wrk_01")
        XCTAssertEqual(snapshot.workspaceName, "Default")
        XCTAssertEqual(snapshot.usageURL?.absoluteString,
                       "https://opencode.ai/console/wrk_01/activity/overview")
        XCTAssertEqual(snapshot.meters.count, 3)

        let rolling = try XCTUnwrap(snapshot.meters.first { $0.kind == .rolling })
        XCTAssertEqual(rolling.usedPercent, 14)
        XCTAssertFalse(rolling.isLimited)
        XCTAssertEqual(rolling.resetsAt?.timeIntervalSince1970 ?? 0, 1_793_700_456, accuracy: 0.5)

        let monthly = try XCTUnwrap(snapshot.meters.first { $0.kind == .monthly })
        XCTAssertTrue(monthly.isLimited)
    }

    func testCommandPayloadTreatsNullDataAsNotSubscribed() {
        let data = Data(#"{"location": {}, "data": null}"#.utf8)
        XCTAssertThrowsError(try OpenCodeGoUsageParser.parseCommandPayload(data)) { error in
            XCTAssertEqual(error as? OpenCodeGoUsageError, .notSubscribed)
        }
    }

    func testCommandPayloadWithoutGoMetersIsNotSubscribed() {
        let data = Data(#"{"data": {"workspace": {"id": "wrk"}, "budgets": []}}"#.utf8)
        XCTAssertThrowsError(try OpenCodeGoUsageParser.parseCommandPayload(data)) { error in
            XCTAssertEqual(error as? OpenCodeGoUsageError, .notSubscribed)
        }
    }

    // MARK: - Direct payload

    func testDirectPayloadParsesISO8601ResetDates() throws {
        let data = Data("""
        {
          "usage": {
            "rolling": {"status": "ok", "percent": 14, "resetsAt": "2026-11-03T10:07:36.000Z"},
            "weekly": {"status": "rate-limited", "percent": 100, "resetsAt": "2026-11-09T00:00:00.000Z"}
          }
        }
        """.utf8)

        let snapshot = try OpenCodeGoUsageParser.parseDirectPayload(data, fetchedAt: now)

        XCTAssertEqual(snapshot.meters.count, 2)
        let rolling = try XCTUnwrap(snapshot.meters.first { $0.kind == .rolling })
        XCTAssertEqual(rolling.usedPercent, 14)
        XCTAssertFalse(rolling.isLimited)

        let weekly = try XCTUnwrap(snapshot.meters.first { $0.kind == .weekly })
        XCTAssertTrue(weekly.isLimited)
        XCTAssertEqual(weekly.usedPercent, 100)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(rolling.resetsAt, formatter.date(from: "2026-11-03T10:07:36Z"))
    }

    func testDirectPayloadClampsOutOfRangePercentages() throws {
        let data = Data("""
        {"usage": {"rolling": {"status": "ok", "percent": 140, "resetsAt": null},
                   "weekly": {"status": "ok", "percent": -5}}}
        """.utf8)
        let snapshot = try OpenCodeGoUsageParser.parseDirectPayload(data, fetchedAt: now)

        XCTAssertEqual(snapshot.meters.first { $0.kind == .rolling }?.usedPercent, 100)
        XCTAssertEqual(snapshot.meters.first { $0.kind == .rolling }?.resetsAt, nil)
        XCTAssertEqual(snapshot.meters.first { $0.kind == .weekly }?.usedPercent, 0)
    }

    func testMalformedPayloadIsRejected() {
        XCTAssertThrowsError(try OpenCodeGoUsageParser.parseDirectPayload(Data("not json".utf8)))
        XCTAssertThrowsError(try OpenCodeGoUsageParser.parseDirectPayload(Data(#"{"usage": {}}"#.utf8)))
    }

    // MARK: - Window mapping

    func testWindowMappingUsesStableIDsAndProviderNames() throws {
        let data = Data("""
        {"data": {"workspace": {"id": "wrk_01"},
                  "go": {"rolling": {"percent": 14, "limited": false, "resetsAt": 1793700456000},
                         "weekly": {"percent": 9, "limited": false, "resetsAt": 1794182400000}}}}
        """.utf8)
        let snapshot = try OpenCodeGoUsageParser.parseCommandPayload(data, fetchedAt: now)
        let windows = OpenCodeGoWindowMapper.windows(
            from: snapshot,
            names: [.rolling: "5-hour", .weekly: "Weekly"]
        )

        XCTAssertEqual(windows.map(\.id), ["opencode-go-rolling", "opencode-go-weekly"])
        XCTAssertEqual(windows.map(\.name), ["5-hour", "Weekly"])
        XCTAssertEqual(windows.first?.windowDurationMins, 300)
        XCTAssertEqual(windows.last?.windowDurationMins, 10_080)
        XCTAssertEqual(windows.first?.remainingPercent, 86)
    }

    func testWindowsWithoutLocalizedNameAreSkipped() throws {
        let data = Data("""
        {"data": {"workspace": {"id": "wrk_01"},
                  "go": {"rolling": {"percent": 14, "limited": false}}}}
        """.utf8)
        let snapshot = try OpenCodeGoUsageParser.parseCommandPayload(data, fetchedAt: now)
        XCTAssertTrue(OpenCodeGoWindowMapper.windows(from: snapshot, names: [:]).isEmpty)
    }

    // MARK: - Credential parsing

    func testCredentialParsesOAuthMetadata() throws {
        let data = Data("""
        {"type": "oauth",
         "access": "token-abc",
         "refresh": "refresh-abc",
         "expires": 1796283256453,
         "metadata": {"server": "https://opencode.ai/console",
                      "accountID": "acc_1",
                      "email": "user@example.com",
                      "orgID": "wrk_1",
                      "orgName": "Default"}}
        """.utf8)
        let credential = try XCTUnwrap(OpenCodeGoCredentialStore.parseCredentialJSON(data))

        XCTAssertEqual(credential.accessToken, "token-abc")
        XCTAssertEqual(credential.refreshToken, "refresh-abc")
        XCTAssertEqual(credential.organizationID, "wrk_1")
        XCTAssertEqual(credential.accountID, "acc_1")
        XCTAssertEqual(credential.server.absoluteString, "https://opencode.ai/console")
        XCTAssertEqual(credential.expiresAt?.timeIntervalSince1970 ?? 0, 1_796_283_256.453,
                       accuracy: 0.01)
        XCTAssertFalse(credential.isExpired)
    }

    func testCredentialParsesAPIKeyStyleEntry() throws {
        let data = Data(#"{"type": "apiKey", "key": "sk-live"}"#.utf8)
        let credential = try XCTUnwrap(OpenCodeGoCredentialStore.parseCredentialJSON(data))

        XCTAssertEqual(credential.accessToken, "sk-live")
        XCTAssertNil(credential.organizationID)
        XCTAssertEqual(credential.server.absoluteString, "https://opencode.ai/console")
    }

    func testCredentialRejectsEntriesWithoutToken() {
        XCTAssertNil(OpenCodeGoCredentialStore.parseCredentialJSON(Data(#"{"type": "oauth"}"#.utf8)))
        XCTAssertNil(OpenCodeGoCredentialStore.parseCredentialJSON(Data("".utf8)))
    }

    func testExpiredCredentialIsReported() throws {
        let data = Data(#"{"access": "old", "metadata": {"expires": 1000000000000}}"#.utf8)
        let credential = try XCTUnwrap(OpenCodeGoCredentialStore.parseCredentialJSON(data))
        XCTAssertTrue(credential.isExpired)
    }

    // MARK: - Provider namespacing

    func testHistoryKeysStaySeparatedPerProvider() {
        XCTAssertEqual(UsageProvider.codex.historyAccountKey(for: "abc"), "codex:abc")
        XCTAssertEqual(UsageProvider.openCodeGo.historyAccountKey(for: "wrk_01"), "opencode-go:wrk_01")
        XCTAssertEqual(UsageProvider.openCodeGo.historyAccountKey(for: nil), "opencode-go")
        XCTAssertEqual(UsageProvider.openCodeGo.historyAccountKey(for: ""), "opencode-go")
        XCTAssertNotEqual(
            UsageProvider.codex.historyAccountKey(for: "shared"),
            UsageProvider.openCodeGo.historyAccountKey(for: "shared")
        )
    }

    func testWindowKindNominalDurations() {
        XCTAssertEqual(UsageWindowKind.rolling.nominalDurationMins, 300)
        XCTAssertEqual(UsageWindowKind.weekly.nominalDurationMins, 10_080)
        XCTAssertNil(UsageWindowKind.monthly.nominalDurationMins)
    }

    /// The monthly Go meter ships only a reset instant, so the remaining-time bar
    /// has to measure the month that ends at that instant.
    func testMonthlyWindowDurationIsDerivedFromResetDate() throws {
        let data = Data("""
        {"data": {"workspace": {"id": "wrk_01"},
                  "go": {"monthly": {"percent": 11, "limited": false, "resetsAt": 1795413157000}}}}
        """.utf8)
        let snapshot = try OpenCodeGoUsageParser.parseCommandPayload(data, fetchedAt: now)
        let windows = OpenCodeGoWindowMapper.windows(
            from: snapshot,
            names: [.monthly: "Monthly"],
            calendar: Self.utcCalendar
        )

        // Compare against a moment still inside that month of service.
        let reference = Date(timeIntervalSince1970: 1_794_000_000)
        let window = try XCTUnwrap(windows.first)
        XCTAssertEqual(window.windowDurationMins, 31 * 24 * 60)
        XCTAssertNotNil(window.remainingTimePercent(at: reference))
        // The length comes from the calendar, so it must not become the bucket.
        XCTAssertTrue(window.isDurationDerived)
        XCTAssertEqual(window.historyID, "opencode-go-monthly")
    }

    /// A calendar month can be 28 to 31 days, so a derived length must never
    /// move the monthly history into a differently named bucket.
    func testMonthlyHistoryBucketIsStableAcrossMonthLengths() throws {
        func window(resetsAt: Double) throws -> UsageWindow {
            let data = Data("""
            {"data": {"workspace": {"id": "wrk_01"},
                      "go": {"monthly": {"percent": 11, "limited": false, "resetsAt": \(Int(resetsAt))}}}}
            """.utf8)
            let snapshot = try OpenCodeGoUsageParser.parseCommandPayload(data, fetchedAt: now)
            return try XCTUnwrap(
                OpenCodeGoWindowMapper.windows(
                    from: snapshot,
                    names: [.monthly: "Monthly"],
                    calendar: Self.utcCalendar
                ).first
            )
        }

        let novemberReset = try window(resetsAt: 1_795_413_157_000)
        let septemberReset = try window(resetsAt: 1_792_734_757_000)
        XCTAssertEqual(novemberReset.historyID, septemberReset.historyID)
        XCTAssertNotEqual(novemberReset.windowDurationMins, septemberReset.windowDurationMins)
    }

    func testWeeklyWindowKeepsDurationScopedHistoryBucket() throws {
        let data = Data("""
        {"data": {"workspace": {"id": "wrk_01"},
                  "go": {"weekly": {"percent": 9, "limited": false, "resetsAt": 1794182400000}}}}
        """.utf8)
        let snapshot = try OpenCodeGoUsageParser.parseCommandPayload(data, fetchedAt: now)
        let window = try XCTUnwrap(
            OpenCodeGoWindowMapper.windows(from: snapshot, names: [.weekly: "Weekly"]).first
        )
        XCTAssertFalse(window.isDurationDerived)
        XCTAssertEqual(window.historyID, "duration:10080:opencode-go-weekly")
    }

    func testMonthlyWindowWithoutResetDateHasNoTimeBar() throws {
        let data = Data("""
        {"data": {"workspace": {"id": "wrk_01"},
                  "go": {"monthly": {"percent": 11, "limited": false}}}}
        """.utf8)
        let snapshot = try OpenCodeGoUsageParser.parseCommandPayload(data, fetchedAt: now)
        let windows = OpenCodeGoWindowMapper.windows(
            from: snapshot,
            names: [.monthly: "Monthly"],
            calendar: Self.utcCalendar
        )

        let window = try XCTUnwrap(windows.first)
        XCTAssertNil(window.windowDurationMins)
        XCTAssertNil(window.remainingTimePercent(at: now))
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()
}
