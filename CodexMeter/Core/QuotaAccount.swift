import Foundation

/// One quota-bearing account the app watches.
///
/// A provider can appear several times: Codex keeps credentials in
/// `$CODEX_HOME/auth.json`, so a second Codex login is a second home directory.
/// The stored account is a lightweight description; the live service is created
/// from it by `UsageCoordinator`.
nonisolated struct StoredQuotaAccount: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var provider: UsageProvider
    var displayName: String
    /// Codex only: the `CODEX_HOME` directory holding this account's `auth.json`.
    var codexHomeDirectoryPath: String?

    static let defaultCodexID = "codex-default"
    static let openCodeGoID = "opencode-go"

    static func defaultCodexHomeDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    static func defaultAccount() -> StoredQuotaAccount {
        StoredQuotaAccount(
            id: defaultCodexID,
            provider: .codex,
            displayName: "Codex",
            codexHomeDirectoryPath: defaultCodexHomeDirectory().path
        )
    }

    static func openCodeGoAccount() -> StoredQuotaAccount {
        StoredQuotaAccount(id: openCodeGoID, provider: .openCodeGo, displayName: "OpenCode Go", codexHomeDirectoryPath: nil)
    }

    /// Accounts that always exist so the app has something to show before the
    /// user adds anything.
    static func seededAccounts() -> [StoredQuotaAccount] {
        [defaultAccount(), openCodeGoAccount()]
    }

    /// Keeps persisted accounts usable: the two provider defaults always exist,
    /// and duplicate identifiers never survive because each identifier owns one
    /// live service and one history partition.
    nonisolated static func normalized(_ accounts: [StoredQuotaAccount]) -> [StoredQuotaAccount] {
        var result: [StoredQuotaAccount] = []
        var seen = Set<String>()
        for account in accounts where seen.insert(account.id).inserted {
            result.append(account)
        }
        if !result.contains(where: { $0.id == defaultCodexID }) {
            result.insert(.defaultAccount(), at: 0)
        }
        // The provider default stays the last tab so extra Codex logins, the
        // reason a user adds accounts at all, sit next to the default login.
        result.removeAll { $0.id == openCodeGoID }
        result.append(.openCodeGoAccount())
        return result
    }

    var codexHomeDirectory: URL? {
        guard let path = codexHomeDirectoryPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// Whether the account can be deleted. The provider defaults stay so a user
    /// cannot end up with no Codex account and no way back without editing
    /// preferences by hand.
    var isRemovable: Bool {
        switch provider {
        case .codex:
            return id != Self.defaultCodexID
        case .openCodeGo:
            return false
        }
    }

    /// The child process reads credentials from here, so a missing `auth.json`
    /// means "not signed in for this profile" rather than a transient error.
    var hasCodexCredentials: Bool {
        guard provider == .codex, let home = codexHomeDirectory else { return false }
        return FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path)
    }
}
