import Combine
import Foundation

/// Presents the quota accounts the app is watching.
///
/// Every account keeps polling in the background so the switcher is instant and
/// history stays continuous. Only the account on screen owns the visible history
/// partition; the rest keep recording under their own account key.
@MainActor
final class UsageCoordinator: ObservableObject {
    let openCodeGo: OpenCodeGoUsageService
    /// Opt-in community reset estimate; it refreshes only when the popover opens
    /// or the user asks for a refresh, never on an idle timer.
    let resetForecast = ResetForecastService()

    @Published private(set) var accounts: [StoredQuotaAccount]
    @Published private(set) var accountID: String

    private let settings: AppSettings
    private let history: UsageHistoryModel
    private var codexServices: [String: CodexUsageService]
    private var forwarders: [String: AnyCancellable] = [:]
    private var observations: Set<AnyCancellable> = []
    private var isForecastForwarded = false
    private var hasActivated = false

    init(settings: AppSettings, history: UsageHistoryModel) {
        self.settings = settings
        self.history = history
        let stored = settings.accounts
        self.accounts = stored
        self.accountID = stored.contains(where: { $0.id == settings.usageAccountID })
            ? settings.usageAccountID
            : (stored.first?.id ?? StoredQuotaAccount.defaultCodexID)
        self.openCodeGo = OpenCodeGoUsageService(settings: settings, history: history)

        var services: [String: CodexUsageService] = [:]
        for account in stored where account.provider == .codex {
            services[account.id] = CodexUsageService(
                settings: settings,
                history: history,
                codexHomeDirectory: account.codexHomeDirectory
            )
        }
        self.codexServices = services
        self.resetForecast.setEnabled(settings.resetForecastEnabled)
        settings.$resetForecastEnabled
            .sink { [weak self] enabled in self?.resetForecast.setEnabled(enabled) }
            .store(in: &observations)

        // Activate after StateObject construction completes on the main run loop.
        Task { @MainActor [weak self] in
            self?.activateSources()
        }
    }

    // MARK: - Accounts

    var activeAccount: StoredQuotaAccount {
        accounts.first { $0.id == accountID } ?? StoredQuotaAccount.defaultAccount()
    }

    func account(withID id: String) -> StoredQuotaAccount? {
        accounts.first { $0.id == id }
    }

    func source(for accountID: String) -> (any UsageSource)? {
        guard let account = account(withID: accountID) else { return nil }
        switch account.provider {
        case .codex: return codexServices[accountID]
        case .openCodeGo: return openCodeGo
        }
    }

    var activeSource: any UsageSource {
        source(for: accountID) ?? openCodeGo
    }

    func remainingPercent(for accountID: String) -> Int? {
        source(for: accountID)?.mostConstrainedRemainingPercent
    }

    func attentionLevel(for accountID: String) -> QuotaAttentionLevel? {
        source(for: accountID)?.mostConstrainedWindow?.attentionLevel(at: Date())
    }

    func windows(for accountID: String) -> [UsageWindow] {
        source(for: accountID)?.windows ?? []
    }

    func select(_ newAccountID: String) {
        guard newAccountID != accountID, account(withID: newAccountID) != nil else { return }
        accountID = newAccountID
        settings.usageAccountID = newAccountID
        applyHistoryViewOwnership()
        // The other account may not have polled since the popover opened.
        activeSource.refreshIfNeeded(maxAge: 10)
        // Hold both rules in one place: switching away from Codex hides the
        // estimate, and switching back may fetch it again once the hour is up.
        if showsResetForecast {
            resetForecast.noteActivity()
        }
    }

    /// Adds another Codex login by pointing at its own `CODEX_HOME` directory.
    @discardableResult
    func addCodexAccount(homeDirectory: URL, displayName: String) -> StoredQuotaAccount? {
        let normalizedHome = homeDirectory.standardizedFileURL
        if let existing = accounts.first(where: {
            $0.provider == .codex && $0.codexHomeDirectory?.path == normalizedHome.path
        }) {
            return existing
        }
        guard normalizedHome.path != StoredQuotaAccount.defaultCodexHomeDirectory().path else {
            return accounts.first { $0.id == StoredQuotaAccount.defaultCodexID }
        }

        let account = StoredQuotaAccount(
            id: "codex-" + UUID().uuidString,
            provider: .codex,
            displayName: displayName,
            codexHomeDirectoryPath: normalizedHome.path
        )
        var updated = accounts
        updated.insert(account, at: max(accounts.count - 1, 0))
        accounts = AppSettings.normalizedAccounts(updated)
        settings.accounts = accounts
        codexServices[account.id] = CodexUsageService(
            settings: settings,
            history: history,
            codexHomeDirectory: normalizedHome
        )
        bindForwarding()
        applyHistoryViewOwnership()
        return account
    }

    func removeAccount(id: String) {
        guard let account = account(withID: id), account.isRemovable else { return }
        if account.provider == .codex {
            codexServices[id]?.deactivate()
            codexServices.removeValue(forKey: id)
        }
        forwarders[id] = nil
        accounts.removeAll { $0.id == id }
        settings.accounts = accounts
        if accountID == id {
            accountID = accounts.first?.id ?? StoredQuotaAccount.defaultCodexID
            settings.usageAccountID = accountID
        }
        applyHistoryViewOwnership()
    }

    func renameAccount(id: String, displayName: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        accounts[index].displayName = trimmed
        settings.accounts = accounts
    }

    // MARK: - Lifecycle

    private func activateSources() {
        guard !hasActivated else { return }
        hasActivated = true
        openCodeGo.updateChannel(settings.openCodeGoChannel)
        // Every service autostarts; the coordinator only decides who owns the
        // visible history partition.
        applyHistoryViewOwnership()
        bindForwarding()
    }

    /// Exactly one source may own the visible history partition; deactivating
    /// the outgoing one first keeps the store from briefly mixing partitions.
    private func applyHistoryViewOwnership() {
        for account in accounts {
            source(for: account.id)?.setHistoryViewActive(account.id == accountID)
        }
    }

    /// SwiftUI observes the coordinator only, so relay changes from every
    /// account: background accounts still update their switcher percentage.
    private func bindForwarding() {
        for account in accounts {
            guard forwarders[account.id] == nil, let source = source(for: account.id) else { continue }
            forwarders[account.id] = source.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
        if !isForecastForwarded {
            isForecastForwarded = true
            resetForecast.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }.store(in: &observations)
        }
    }

    // MARK: - Forwarded surface

    /// Token Activity reads Codex App Server usage buckets, which no other
    /// provider can supply.
    var supportsTokenActivity: Bool { activeAccount.provider == .codex }

    var windows: [UsageWindow] { activeSource.windows }
    var planType: String? { activeSource.planType }
    var isLoading: Bool { activeSource.isLoading }
    var isRefreshInFlight: Bool { activeSource.isRefreshInFlight }
    var isStale: Bool { activeSource.isStale }
    var errorMessage: String? { activeSource.errorMessage }
    var lastUpdated: Date? { activeSource.lastUpdated }
    var tokenUsage: TokenUsageSnapshot? { activeSource.tokenUsage }
    var isTokenUsageUnavailable: Bool { activeSource.isTokenUsageUnavailable }
    var tokenUsageErrorMessage: String? { activeSource.tokenUsageErrorMessage }
    var rateLimitResetCredits: CodexRateLimitResetCreditsSummary? { activeSource.rateLimitResetCredits }
    var historyAccountKey: String? { activeSource.historyAccountKey }
    var mostConstrainedRemainingPercent: Int? { activeSource.mostConstrainedRemainingPercent }
    var mostConstrainedWindow: UsageWindow? { activeSource.mostConstrainedWindow }
    var menuBarTitle: String { activeSource.menuBarTitle }
    var accountDescription: String { activeSource.accountDescription }
    var pushNotificationService: PushNotificationService { activeSource.pushNotificationService }

    /// The ring window the menu bar should draw for the account it shows.
    func menuBarWindow(for accountID: String) -> UsageWindow? {
        settings.popoverContent.selectedMenuBarWindow(
            from: windows(for: accountID),
            account: accountID
        )
    }

    /// Caption drawn under the menu bar percentage. The shipped caption is the
    /// Codex brand, so the default follows the account; a caption the user typed
    /// in Developer Options always wins.
    var menuBarCaption: String {
        let configured = settings.developerAppearance.captionText
        guard configured == MenuBarAppearance.defaultCaptionText else { return configured }
        return activeAccount.displayName
    }

    /// The community tracker estimates Codex quota resets, so the section and its
    /// requests belong to Codex accounts only.
    var showsResetForecast: Bool {
        activeAccount.provider == .codex
    }

    func refresh() {
        activeSource.refresh()
        if showsResetForecast {
            resetForecast.noteActivity()
        }
    }

    func refreshIfNeeded(maxAge: TimeInterval = 10) {
        activeSource.refreshIfNeeded(maxAge: maxAge)
    }

    func setPopoverVisible(_ visible: Bool) {
        for account in accounts {
            source(for: account.id)?.setPopoverVisible(visible)
        }
        if visible, showsResetForecast {
            resetForecast.noteActivity()
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        for account in accounts {
            source(for: account.id)?.setNotificationsEnabled(enabled)
        }
    }
}
