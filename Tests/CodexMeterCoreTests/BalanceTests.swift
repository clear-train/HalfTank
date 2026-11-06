@testable import CodexMeterCore
import XCTest

/// Covers every money-only source: the four payload shapes, the shared ring
/// mapping, credential resolution, and the provider spellings that can already
/// be sitting in someone's preferences.
final class BalanceTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_820_000_000)

    // MARK: - DeepSeek

    func testDeepSeekParsesDocumentedPayloadAndPrefersYuan() throws {
        let snapshot = try parse("""
        {
          "is_available": true,
          "balance_infos": [
            {"currency": "USD", "total_balance": "12.50", "granted_balance": "0.00", "topped_up_balance": "12.50"},
            {"currency": "CNY", "total_balance": "110.00", "granted_balance": "10.00", "topped_up_balance": "100.00"}
          ]
        }
        """, source: .deepSeek)

        XCTAssertTrue(snapshot.isAvailable)
        XCTAssertEqual(snapshot.lines.count, 2)
        let preferred = try XCTUnwrap(snapshot.preferred)
        XCTAssertEqual(preferred.currency, "CNY")
        XCTAssertEqual(preferred.total, Decimal(string: "110.00"))
        XCTAssertEqual(preferred.granted, Decimal(string: "10.00"))
        XCTAssertEqual(preferred.toppedUp, Decimal(string: "100.00"))
    }

    func testDeepSeekMissingBalanceLinesIsMalformedInsteadOfZero() {
        XCTAssertThrowsError(try parse(#"{"is_available": true}"#, source: .deepSeek))
    }

    func testDeepSeekMissingAvailabilityFlagReadsAsUnavailable() throws {
        let snapshot = try parse("""
        {"balance_infos": [{"currency": "CNY", "total_balance": "1.00", "granted_balance": "0.00", "topped_up_balance": "1.00"}]}
        """, source: .deepSeek)
        XCTAssertFalse(snapshot.isAvailable)
    }

    // MARK: - OpenRouter

    func testOpenRouterSubtractsUsageFromPurchasedCredits() throws {
        let snapshot = try parse("""
        {"data": {"total_credits": 100.0, "total_usage": 12.25}}
        """, source: .openRouter)
        let line = try XCTUnwrap(snapshot.preferred)
        XCTAssertEqual(line.currency, "USD")
        XCTAssertEqual(line.total, Decimal(string: "87.75"))
        XCTAssertEqual(line.toppedUp, Decimal(string: "100"))
    }

    func testOpenRouterRefundPastUsageNeverShowsNegativeMoney() throws {
        let snapshot = try parse("""
        {"data": {"total_credits": 5.0, "total_usage": 9.0}}
        """, source: .openRouter)
        XCTAssertEqual(snapshot.preferred?.total, 0)
    }

    func testOpenRouterMissingUsageIsMalformed() {
        XCTAssertThrowsError(try parse(#"{"data": {"total_credits": 10.0}}"#, source: .openRouter))
    }

    // MARK: - Moonshot

    func testMoonshotSplitsVoucherAndCash() throws {
        let snapshot = try parse("""
        {"code": 0, "data": {"available_balance": 49.5, "voucher_balance": 10, "cash_balance": 39.5}}
        """, source: .moonshot)
        let line = try XCTUnwrap(snapshot.preferred)
        XCTAssertEqual(line.currency, "CNY")
        XCTAssertEqual(line.total, Decimal(string: "49.5"))
        XCTAssertEqual(line.granted, 10)
        XCTAssertEqual(line.toppedUp, Decimal(string: "39.5"))
    }

    func testMoonshotMissingBalanceIsMalformed() {
        XCTAssertThrowsError(try parse(#"{"code": 0, "data": {}}"#, source: .moonshot))
    }

    // MARK: - SiliconFlow

    func testSiliconFlowParsesStringAmounts() throws {
        let snapshot = try parse("""
        {"code": 20000, "data": {"balance": "10.00", "chargeBalance": "100.00", "totalBalance": "110.00"}}
        """, source: .siliconFlow)
        let line = try XCTUnwrap(snapshot.preferred)
        XCTAssertEqual(line.currency, "CNY")
        XCTAssertEqual(line.total, Decimal(string: "110.00"))
        XCTAssertEqual(line.granted, Decimal(string: "10.00"))
        XCTAssertEqual(line.toppedUp, Decimal(string: "100.00"))
    }

    func testSiliconFlowMissingTotalIsMalformed() {
        XCTAssertThrowsError(try parse(#"{"code": 20000, "data": {"balance": "1.00"}}"#, source: .siliconFlow))
    }

    // MARK: - Shared mapping

    func testAmountUsesTheCurrencySymbol() {
        XCTAssertEqual(
            BalanceFormat.amount(Decimal(string: "110")!, currency: "CNY", locale: Locale(identifier: "en_US")),
            "¥110.00"
        )
        XCTAssertEqual(
            BalanceFormat.amount(Decimal(string: "9.5")!, currency: "USD", locale: Locale(identifier: "en_US")),
            "$9.50"
        )
    }

    func testBudgetTurnsTheBalanceIntoARemainingPercentage() throws {
        let snapshot = try parse("""
        {"is_available": true, "balance_infos": [{"currency": "CNY", "total_balance": "80.00", "granted_balance": "0.00", "topped_up_balance": "80.00"}]}
        """, source: .deepSeek)
        let window = try XCTUnwrap(BalanceWindow.window(
            for: snapshot,
            budget: Decimal(string: "100")!,
            name: "Balance"
        ))
        XCTAssertEqual(window.id, BalanceWindow.windowID)
        XCTAssertEqual(window.remainingPercent, 80)
        XCTAssertEqual(window.usedPercent, 20)
        XCTAssertNil(window.windowDurationMins)
        XCTAssertNil(window.resetsAt)
        XCTAssertFalse(window.isDurationDerived)
    }

    func testBalanceAboveBudgetClampsToFull() throws {
        let snapshot = try parse("""
        {"is_available": true, "balance_infos": [{"currency": "CNY", "total_balance": "250.00", "granted_balance": "0.00", "topped_up_balance": "250.00"}]}
        """, source: .deepSeek)
        let window = try XCTUnwrap(BalanceWindow.window(for: snapshot, budget: 100, name: "Balance"))
        XCTAssertEqual(window.remainingPercent, 100)
        XCTAssertEqual(window.usedPercent, 0)
    }

    func testNoBudgetMeansNoWindow() throws {
        let snapshot = try parse("""
        {"is_available": true, "balance_infos": [{"currency": "CNY", "total_balance": "80.00", "granted_balance": "0.00", "topped_up_balance": "80.00"}]}
        """, source: .deepSeek)
        XCTAssertNil(BalanceWindow.window(for: snapshot, budget: 0, name: "Balance"))
    }

    func testMalformedDocumentThrows() {
        XCTAssertThrowsError(try parse("nope", source: .moonshot))
    }

    // MARK: - Credentials

    func testEnvironmentKeyWinsOverTheKeychain() {
        let store = BalanceKeyStore(
            source: .openRouter,
            environment: ["OPENROUTER_API_KEY": "env-key"],
            readStored: { _ in "keychain-key" }
        )
        XCTAssertEqual(store.resolve(), BalanceApiKey(value: "env-key", source: .environment))
    }

    func testBlankEnvironmentValueFallsBackToTheKeychain() {
        let store = BalanceKeyStore(
            source: .siliconFlow,
            environment: ["SILICONFLOW_API_KEY": "   "],
            readStored: { _ in "keychain-key" }
        )
        XCTAssertEqual(store.resolve(), BalanceApiKey(value: "keychain-key", source: .keychain))
        XCTAssertFalse(store.hasEnvironmentKey)
        XCTAssertTrue(store.hasStoredKey)
    }

    func testNoKeyAnywhereResolvesToNothing() {
        let store = BalanceKeyStore(source: .moonshot, environment: [:], readStored: { _ in nil })
        XCTAssertNil(store.resolve())
        XCTAssertFalse(store.hasEnvironmentKey)
        XCTAssertFalse(store.hasStoredKey)
    }

    func testSavingABlankValueDeletesTheStoredKey() throws {
        var events: [String] = []
        let store = BalanceKeyStore(
            source: .deepSeek,
            environment: [:],
            readStored: { _ in nil },
            saveStored: { value, _ in events.append(value) },
            deleteStored: { _ in events.append("<deleted>") }
        )
        try store.save("  ")
        XCTAssertEqual(events, ["<deleted>"])
    }

    func testKeychainServiceIsDistinctPerSource() {
        let services = BalanceSource.allCases.map(BalanceKeychain.service(for:))
        XCTAssertEqual(Set(services).count, BalanceSource.allCases.count)
    }

    // MARK: - Provider

    func testProviderDecodesEverySpellingAlreadyStoredInPreferences() throws {
        let spellings: [(String, UsageProvider)] = [
            ("deepseek", .deepSeek), ("deep-seek", .deepSeek),
            ("openrouter", .openRouter), ("open-router", .openRouter),
            ("moonshot", .moonshot),
            ("siliconflow", .siliconFlow), ("silicon-flow", .siliconFlow)
        ]
        for (raw, expected) in spellings {
            let provider = try JSONDecoder().decode(UsageProvider.self, from: Data("\"\(raw)\"".utf8))
            XCTAssertEqual(provider, expected, raw)
        }
        XCTAssertEqual(UsageProvider.openRouter.historyNamespace, "openrouter")
        XCTAssertEqual(UsageProvider.siliconFlow.balanceSource, .siliconFlow)
    }

    func testOptionalProvidersCoverEveryBalanceSource() {
        let optional = Set(UsageProvider.optionalProviders)
        for source in BalanceSource.allCases {
            XCTAssertTrue(optional.contains(UsageProvider.balanceProvider(for: source)), source.rawValue)
        }
        XCTAssertTrue(optional.contains(.openCodeGo))
    }

    func testSeededAccountsContainDeepSeekBeforeOpenCodeGo() {
        let accounts = StoredQuotaAccount.normalized(StoredQuotaAccount.seededAccounts())
        XCTAssertEqual(accounts.map(\.id), [
            StoredQuotaAccount.defaultCodexID,
            StoredQuotaAccount.deepSeekID,
            StoredQuotaAccount.openCodeGoID
        ])
        XCTAssertTrue(accounts.first { $0.id == StoredQuotaAccount.deepSeekID }?.isRemovable ?? false)
    }

    private func parse(_ json: String, source: BalanceSource) throws -> BalanceSnapshot {
        try BalanceParser.parse(Data(json.utf8), source: source, fetchedAt: fetchedAt)
    }
}
