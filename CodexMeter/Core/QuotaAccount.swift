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
    static let deepSeekID = "deepseek"

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

    /// One implicit account: the balance belongs to the single API key the app
    /// holds, so there is never a second DeepSeek row to add or remove.
    static func deepSeekAccount() -> StoredQuotaAccount {
        StoredQuotaAccount(id: deepSeekID, provider: .deepSeek, displayName: "DeepSeek", codexHomeDirectoryPath: nil)
    }

    /// Accounts a fresh installation starts with. DeepSeek and OpenCode Go are
    /// optional sources: they appear here once, and the user can remove them
    /// again from Settings.
    static func seededAccounts() -> [StoredQuotaAccount] {
        [defaultAccount(), deepSeekAccount(), openCodeGoAccount()]
    }

    /// Keeps persisted accounts usable: the default Codex login always exists,
    /// and duplicate identifiers never survive because each identifier owns one
    /// live service and one history partition. Optional providers are not
    /// re-added here, so removing one stays removed across launches.
    nonisolated static func normalized(_ accounts: [StoredQuotaAccount]) -> [StoredQuotaAccount] {
        var result: [StoredQuotaAccount] = []
        var seen = Set<String>()
        for account in accounts where seen.insert(account.id).inserted {
            result.append(account)
        }
        if !result.contains(where: { $0.id == defaultCodexID }) {
            result.insert(.defaultAccount(), at: 0)
        }
        // Keep the display order stable: the default Codex login first, extra
        // Codex logins next, DeepSeek before OpenCode Go.
        var middle = result.filter { $0.id != defaultCodexID && $0.id != openCodeGoID }
        if let deepSeek = middle.firstIndex(where: { $0.id == deepSeekID }) {
            middle.append(middle.remove(at: deepSeek))
        }
        let tail = result.filter { $0.id == openCodeGoID }
        let head = result.filter { $0.id == defaultCodexID }
        return head + middle + tail
    }

    var codexHomeDirectory: URL? {
        guard let path = codexHomeDirectoryPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// Whether the account can be deleted. The default Codex login stays so the
    /// app always has one quota source, and because it is the only account that
    /// cannot be recreated from Settings. DeepSeek and OpenCode Go are optional
    /// and can be added back from the same list.
    var isRemovable: Bool {
        switch provider {
        case .codex:
            return id != Self.defaultCodexID
        case .openCodeGo, .deepSeek:
            return true
        }
    }

    /// The child process reads credentials from here, so a missing `auth.json`
    /// means "not signed in for this profile" rather than a transient error.
    var hasCodexCredentials: Bool {
        guard provider == .codex, let home = codexHomeDirectory else { return false }
        return FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path)
    }
}
