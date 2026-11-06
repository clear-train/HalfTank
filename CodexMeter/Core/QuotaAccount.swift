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
    static let openRouterID = "openrouter"
    static let moonshotID = "moonshot"
    static let siliconFlowID = "silicon-flow"

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

    /// One implicit account per balance provider: the balance belongs to the
    /// single API key the app holds, so there is never a second row to add.
    static func balanceAccount(for source: BalanceSource) -> StoredQuotaAccount {
        StoredQuotaAccount(
            id: identifier(for: source),
            provider: UsageProvider.balanceProvider(for: source),
            displayName: source.displayName,
            codexHomeDirectoryPath: nil
        )
    }

    static func identifier(for source: BalanceSource) -> String {
        switch source {
        case .deepSeek: return deepSeekID
        case .openRouter: return openRouterID
        case .moonshot: return moonshotID
        case .siliconFlow: return siliconFlowID
        }
    }

    static func deepSeekAccount() -> StoredQuotaAccount {
        balanceAccount(for: .deepSeek)
    }

    /// Accounts a fresh installation starts with. Every optional source is
    /// removable from Settings, and the ones omitted here stay reachable through
    /// *Add a source…*, so seeding DeepSeek never hides OpenRouter, Moonshot, or
    /// SiliconFlow from a new user.
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
        // Codex logins next, then the balance sources in a fixed order, and the
        // subscription source last.
        let head = result.filter { $0.id == defaultCodexID }
        let tail = result.filter { $0.id == openCodeGoID }
        let middle = result.filter { $0.id != defaultCodexID && $0.id != openCodeGoID }
        let balanceIDs = BalanceSource.allCases.map(StoredQuotaAccount.identifier(for:))
        let codexExtras = middle.filter { !balanceIDs.contains($0.id) }
        let balances = balanceIDs.compactMap { id in middle.first { $0.id == id } }
        return head + codexExtras + balances + tail
    }

    var codexHomeDirectory: URL? {
        guard let path = codexHomeDirectoryPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// Whether the account can be deleted. The default Codex login stays so the
    /// app always has one quota source, and because it is the only account that
    /// cannot be recreated from Settings. Balance sources and OpenCode Go are
    /// optional and can be added back from the same list.
    var isRemovable: Bool {
        switch provider {
        case .codex:
            return id != Self.defaultCodexID
        default:
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
