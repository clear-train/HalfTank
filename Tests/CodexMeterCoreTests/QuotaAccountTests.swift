import XCTest
@testable import CodexMeterCore

final class QuotaAccountTests: XCTestCase {
    func testSeededAccountsStartWithTheDefaultCodexLoginAndOpenCodeGo() {
        let seeded = StoredQuotaAccount.seededAccounts()

        XCTAssertEqual(seeded.map(\.id), [StoredQuotaAccount.defaultCodexID, StoredQuotaAccount.openCodeGoID])
        XCTAssertEqual(seeded.first?.provider, .codex)
        XCTAssertEqual(seeded.first?.codexHomeDirectory?.path, StoredQuotaAccount.defaultCodexHomeDirectory().path)
        XCTAssertFalse(seeded[0].isRemovable)
        XCTAssertFalse(seeded[1].isRemovable)
    }

    func testNormalizingEmptyAccountsRestoresBothDefaults() {
        let normalized = StoredQuotaAccount.normalized([])

        XCTAssertEqual(normalized.map(\.id), [StoredQuotaAccount.defaultCodexID, StoredQuotaAccount.openCodeGoID])
    }

    func testNormalizingKeepsExtraCodexLoginsBetweenTheDefaults() {
        let work = StoredQuotaAccount(
            id: "codex-work",
            provider: .codex,
            displayName: "Work",
            codexHomeDirectoryPath: "/tmp/codex-work"
        )

        let normalized = StoredQuotaAccount.normalized([.openCodeGoAccount(), work])

        XCTAssertEqual(
            normalized.map(\.id),
            [StoredQuotaAccount.defaultCodexID, "codex-work", StoredQuotaAccount.openCodeGoID]
        )
        XCTAssertTrue(normalized[1].isRemovable)
    }

    func testNormalizingDropsDuplicateAccountIdentifiers() {
        let first = StoredQuotaAccount(
            id: "codex-work",
            provider: .codex,
            displayName: "Work",
            codexHomeDirectoryPath: "/tmp/codex-work"
        )
        // A duplicate identifier must not be renumbered; it survives once or the
        // coordinator would hold two services for the same history partition.
        let second = StoredQuotaAccount(
            id: "codex-work",
            provider: .codex,
            displayName: "Work copy",
            codexHomeDirectoryPath: "/tmp/codex-work-copy"
        )

        let normalized = StoredQuotaAccount.normalized([first, second])

        XCTAssertEqual(normalized.filter { $0.id == "codex-work" }.count, 1)
        XCTAssertEqual(normalized.last?.id, StoredQuotaAccount.openCodeGoID)
    }

    func testStoredAccountsDecodeFromTheSettingsJSONWrittenByTheApp() throws {
        let payload = Data(
            #"[{"id":"codex-default","provider":"codex","displayName":"Codex","codexHomeDirectoryPath":"/Users/me/.codex"},{"id":"codex-work","provider":"codex","displayName":"Work","codexHomeDirectoryPath":"/tmp/work"},{"id":"opencode-go","provider":"openCodeGo","displayName":"OpenCode Go"}]"#.utf8
        )

        let accounts = try JSONDecoder().decode([StoredQuotaAccount].self, from: payload)

        XCTAssertEqual(accounts.count, 3)
        XCTAssertEqual(accounts[0].provider, .codex)
        XCTAssertEqual(accounts[1].codexHomeDirectory?.path, "/tmp/work")
        XCTAssertNil(accounts[2].codexHomeDirectoryPath)
        XCTAssertEqual(accounts[2].provider, .openCodeGo)
    }

    func testCodexAccountWithoutAuthFileReportsMissingCredentials() {
        let account = StoredQuotaAccount(
            id: "codex-empty",
            provider: .codex,
            displayName: "Empty",
            codexHomeDirectoryPath: "/tmp/codexmeter-missing-home-\(UUID().uuidString)"
        )

        XCTAssertFalse(account.hasCodexCredentials)
    }

    func testProviderDecodingAcceptsSavedPreferenceSpellings() throws {
        for raw in ["openCodeGo", "opencodeGo", "opencode-go", "OPENCODE_GO"] {
            let payload = Data(("\"" + raw + "\"").utf8)
            let provider = try JSONDecoder().decode(UsageProvider.self, from: payload)
            XCTAssertEqual(provider, .openCodeGo, "failed for \(raw)")
        }
        let codex = try JSONDecoder().decode(UsageProvider.self, from: Data(#""Codex""#.utf8))
        XCTAssertEqual(codex, .codex)
    }

    func testProviderDecodingRejectsUnknownSources() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(UsageProvider.self, from: Data(#""gemini""#.utf8))
        )
    }
}
