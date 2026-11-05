@testable import CodexMeterCore
import XCTest

final class DeepSeekTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_820_000_000)

    // MARK: - Parsing

    func testParsesDocumentedPayloadAndPrefersYuan() throws {
        let snapshot = try parse("""
        {
          "is_available": true,
          "balance_infos": [
            {"currency": "USD", "total_balance": "12.50", "granted_balance": "0.00", "topped_up_balance": "12.50"},
            {"currency": "CNY", "total_balance": "110.00", "granted_balance": "10.00", "topped_up_balance": "100.00"}
          ]
        }
        """)

        XCTAssertTrue(snapshot.isAvailable)
        XCTAssertEqual(snapshot.lines.count, 2)
        let preferred = try XCTUnwrap(snapshot.preferred)
        XCTAssertEqual(preferred.currency, "CNY")
        XCTAssertEqual(preferred.total, Decimal(string: "110.00"))
        XCTAssertEqual(preferred.granted, Decimal(string: "10.00"))
        XCTAssertEqual(preferred.toppedUp, Decimal(string: "100.00"))
    }

    func testMissingBalanceLinesIsMalformedInsteadOfZero() {
        XCTAssertThrowsError(try parse("""
        {"is_available": true}
        """))
    }

    func testMalformedDocumentThrows() {
        XCTAssertThrowsError(try DeepSeekBalanceParser.parse(Data("nope".utf8), fetchedAt: fetchedAt))
    }

    func testMissingAvailabilityFlagReadsAsUnavailable() throws {
        let snapshot = try parse("""
        {"balance_infos": [{"currency": "CNY", "total_balance": "1.00", "granted_balance": "0.00", "topped_up_balance": "1.00"}]}
        """)
        XCTAssertFalse(snapshot.isAvailable)
    }

    func testAmountUsesTheCurrencySymbol() {
        XCTAssertEqual(
            DeepSeekBalanceFormat.amount(Decimal(string: "110")!, currency: "CNY", locale: Locale(identifier: "en_US")),
            "¥110.00"
        )
        XCTAssertEqual(
            DeepSeekBalanceFormat.amount(Decimal(string: "9.5")!, currency: "USD", locale: Locale(identifier: "en_US")),
            "$9.50"
        )
    }

    // MARK: - Budget window

    func testBudgetTurnsTheBalanceIntoARemainingPercentage() throws {
        let snapshot = try parse("""
        {"is_available": true, "balance_infos": [{"currency": "CNY", "total_balance": "80.00", "granted_balance": "0.00", "topped_up_balance": "80.00"}]}
        """)
        let window = try XCTUnwrap(DeepSeekBalanceWindow.window(
            for: snapshot,
            budget: Decimal(string: "100")!,
            name: "Balance"
        ))
        XCTAssertEqual(window.id, DeepSeekBalanceWindow.windowID)
        XCTAssertEqual(window.remainingPercent, 80)
        XCTAssertEqual(window.usedPercent, 20)
        XCTAssertNil(window.windowDurationMins)
        XCTAssertNil(window.resetsAt)
        XCTAssertFalse(window.isDurationDerived)
    }

    func testBalanceAboveBudgetClampsToFull() throws {
        let snapshot = try parse("""
        {"is_available": true, "balance_infos": [{"currency": "CNY", "total_balance": "250.00", "granted_balance": "0.00", "topped_up_balance": "250.00"}]}
        """)
        let window = try XCTUnwrap(DeepSeekBalanceWindow.window(for: snapshot, budget: 100, name: "Balance"))
        XCTAssertEqual(window.remainingPercent, 100)
        XCTAssertEqual(window.usedPercent, 0)
    }

    func testNoBudgetMeansNoWindow() throws {
        let snapshot = try parse("""
        {"is_available": true, "balance_infos": [{"currency": "CNY", "total_balance": "80.00", "granted_balance": "0.00", "topped_up_balance": "80.00"}]}
        """)
        XCTAssertNil(DeepSeekBalanceWindow.window(for: snapshot, budget: 0, name: "Balance"))
    }

    // MARK: - Credentials

    func testEnvironmentKeyWinsOverTheKeychain() {
        let store = DeepSeekCredentialStore(
            environment: ["DEEPSEEK_API_KEY": "env-key"],
            readStored: { "keychain-key" }
        )
        XCTAssertEqual(store.resolve(), DeepSeekApiKey(value: "env-key", source: .environment))
    }

    func testBlankEnvironmentValueFallsBackToTheKeychain() {
        let store = DeepSeekCredentialStore(
            environment: ["DEEPSEEK_API_KEY": "   "],
            readStored: { "keychain-key" }
        )
        XCTAssertEqual(store.resolve(), DeepSeekApiKey(value: "keychain-key", source: .keychain))
        XCTAssertFalse(store.hasEnvironmentKey)
        XCTAssertTrue(store.hasStoredKey)
    }

    func testNoKeyAnywhereResolvesToNothing() {
        let store = DeepSeekCredentialStore(environment: [:], readStored: { nil })
        XCTAssertNil(store.resolve())
        XCTAssertFalse(store.hasEnvironmentKey)
        XCTAssertFalse(store.hasStoredKey)
    }

    func testSavingABlankValueDeletesTheStoredKey() throws {
        var saved: [String] = []
        let store = DeepSeekCredentialStore(
            environment: [:],
            readStored: { nil },
            saveStored: { saved.append($0) },
            deleteStored: { saved.append("<deleted>") }
        )
        try store.save("  ")
        XCTAssertEqual(saved, ["<deleted>"])
    }

    // MARK: - Provider

    func testProviderDecodesEverySpellingAlreadyStoredInPreferences() throws {
        for raw in ["deepseek", "deep-seek", "DeepSeek", "DEEP_SEEK"] {
            let provider = try JSONDecoder().decode(UsageProvider.self, from: Data("\"\(raw)\"".utf8))
            XCTAssertEqual(provider, .deepSeek, raw)
        }
        XCTAssertEqual(UsageProvider.deepSeek.historyNamespace, "deepseek")
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

    private func parse(_ json: String) throws -> DeepSeekBalanceSnapshot {
        try DeepSeekBalanceParser.parse(Data(json.utf8), fetchedAt: fetchedAt)
    }
}
