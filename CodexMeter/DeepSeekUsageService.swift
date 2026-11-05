import Combine
import Foundation

/// Exposes the DeepSeek platform balance as quota state.
///
/// DeepSeek has no rolling quota windows: the only number the platform reports is
/// the remaining prepaid money. The popover therefore shows money by default, and
/// only draws a ring when the user says how much money a full ring represents.
@MainActor
final class DeepSeekUsageService: ObservableObject, UsageSource {
    @Published private(set) var windows: [UsageWindow] = []
    @Published private(set) var balance: DeepSeekBalanceSnapshot?
    @Published private(set) var planType: String? = "DeepSeek"
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshInFlight = false
    @Published private(set) var isStale = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var credentialSource: DeepSeekCredentialSource?

    /// The balance endpoint reports money only; there is no token breakdown.
    let tokenUsage: TokenUsageSnapshot? = nil
    let isTokenUsageUnavailable = true
    let tokenUsageErrorMessage: String? = nil
    /// DeepSeek prepaid credit has no banked reset credits.
    let rateLimitResetCredits: CodexRateLimitResetCreditsSummary? = nil
    let pushNotificationService: PushNotificationService

    /// A balance has no time series in this version, so the history section stays
    /// hidden instead of showing an axis with one point.
    let supportsQuotaHistory = false
    private(set) var historyAccountKey: String?

    private let settings: AppSettings
    private let notificationManager: NotificationManager
    private let credentialStore: DeepSeekCredentialStore
    private let client = DeepSeekClient()
    private var budget: Decimal = 0
    private var refreshTimer: Timer?
    private var isPopoverVisible = false
    private var refreshSchedule = CodexRefreshSchedule()
    private var isFetching = false

    /// Balances move slowly, so the idle poll is much cheaper than the quota
    /// sources; a visible popover only tightens it a little.
    private static let foregroundInterval: TimeInterval = 120
    private static let backgroundInterval: TimeInterval = 300

    init(
        settings: AppSettings,
        credentialStore: DeepSeekCredentialStore = DeepSeekCredentialStore(),
        notificationManager: NotificationManager? = nil,
        pushNotificationService: PushNotificationService? = nil,
        budget: Decimal = 0,
        autostart: Bool = true
    ) {
        self.settings = settings
        self.credentialStore = credentialStore
        self.notificationManager = notificationManager ?? NotificationManager()
        self.pushNotificationService = pushNotificationService ?? PushNotificationService(settings: settings)
        self.budget = budget
        self.historyAccountKey = UsageProvider.deepSeek.historyAccountKey(for: nil)

        Task { @MainActor [weak self] in
            guard let self, autostart else { return }
            self.installRefreshTimer()
            self.start()
        }
    }

    /// Protocol-facing view of `balance`; the concrete property stays internal so
    /// the settings pane can read the fetched-at date.
    var balanceSnapshot: DeepSeekBalanceSnapshot? { balance }

    var hasCredentials: Bool { credentialStore.resolve() != nil }
    var hasEnvironmentKey: Bool { credentialStore.hasEnvironmentKey }
    var hasStoredKey: Bool { credentialStore.hasStoredKey }

    var mostConstrainedRemainingPercent: Int? {
        mostConstrainedWindow?.remainingPercent
    }

    var mostConstrainedWindow: UsageWindow? {
        windows.min { $0.remainingPercent < $1.remainingPercent }
    }

    var menuBarTitle: String {
        guard let remaining = mostConstrainedRemainingPercent else {
            return menuBarFallbackTitle ?? (isLoading ? "…" : "--")
        }
        return "\(remaining)%"
    }

    /// Without a budget there is no percentage to draw, so the menu bar shows the
    /// amount itself instead of an empty ring.
    var menuBarFallbackTitle: String? {
        balanceText
    }

    var accountDescription: String {
        guard hasCredentials else { return L10n.string("account.deepseek_needs_key") }
        if let balanceText {
            return "DeepSeek · \(balanceText)"
        }
        return "DeepSeek"
    }

    // MARK: - Provider activation

    func activate() {
        installRefreshTimer()
        start()
    }

    func deactivate() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        isPopoverVisible = false
    }

    /// The balance has no history partition; recording would create a one-point
    /// series, so ownership changes are intentionally ignored.
    func setHistoryViewActive(_ active: Bool) {}

    func start() {
        if balance == nil {
            isLoading = true
        } else {
            isStale = true
        }
        refresh()
    }

    /// Applies a budget change without waiting for the next poll.
    func setBudget(_ newBudget: Decimal) {
        guard newBudget != budget else { return }
        budget = newBudget
        applyWindows()
        if windows.isEmpty == false || newBudget > 0 {
            refresh()
        }
    }

    func refresh() {
        guard !isFetching else { return }
        guard let key = credentialStore.resolve() else {
            credentialSource = nil
            windows = []
            balance = nil
            errorMessage = nil
            isLoading = false
            isRefreshInFlight = false
            isStale = false
            return
        }

        isFetching = true
        isRefreshInFlight = true
        if balance == nil { isLoading = true }

        Task { [weak self] in
            do {
                let snapshot = try await self?.client.fetch(apiKey: key.value)
                guard let snapshot else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.isFetching = false
                    self.apply(snapshot, source: key.source)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isFetching = false
                    self.markFailure(error)
                }
            }
        }
    }

    func refreshIfNeeded(maxAge: TimeInterval = 30) {
        guard !isFetching else { return }
        guard let lastUpdated else {
            refresh()
            return
        }
        if Date().timeIntervalSince(lastUpdated) >= maxAge {
            refresh()
        }
    }

    func setPopoverVisible(_ visible: Bool) {
        guard isPopoverVisible != visible else { return }
        isPopoverVisible = visible
        installRefreshTimer()
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        guard enabled else {
            settings.notificationsEnabled = false
            if settings.settingsDestination == .notifications {
                settings.clearSettingsError()
            }
            return
        }

        notificationManager.requestAuthorization { [weak self] granted, error in
            guard let self else { return }
            self.settings.notificationsEnabled = granted
            if granted {
                self.settings.clearSettingsError()
                self.notificationManager.evaluate(
                    windows: self.windows,
                    threshold: self.settings.notificationThreshold
                )
            } else {
                let message = error ?? L10n.string("settings.notification_denied")
                self.settings.showSettingsError(message, destination: .notifications)
            }
        }
    }

    /// Replaces the stored key and refreshes immediately so the settings pane can
    /// show the result of a save without another visit.
    func saveKey(_ value: String) throws {
        try credentialStore.save(value)
        refresh()
    }

    func removeKey() throws {
        try credentialStore.remove()
        balance = nil
        windows = []
        credentialSource = nil
        errorMessage = nil
        lastUpdated = nil
        isStale = false
    }

    // MARK: - State

    private func apply(_ snapshot: DeepSeekBalanceSnapshot, source: DeepSeekCredentialSource) {
        balance = snapshot
        credentialSource = source
        applyWindows()
        isLoading = false
        isRefreshInFlight = false
        isStale = false
        lastUpdated = snapshot.fetchedAt
        errorMessage = nil
        refreshSchedule.succeeded()

        if settings.notificationsEnabled {
            notificationManager.evaluate(windows: windows, threshold: settings.notificationThreshold)
        }
        pushNotificationService.evaluate(windows: windows)
    }

    private func applyWindows() {
        guard let balance else {
            windows = []
            return
        }
        let window = DeepSeekBalanceWindow.window(
            for: balance,
            budget: budget,
            name: L10n.string("balance.window.name")
        )
        windows = window.map { [$0] } ?? []
    }

    private var balanceText: String? {
        guard let line = balance?.preferred else { return nil }
        return DeepSeekBalanceFormat.amount(line.total, currency: line.currency)
    }

    private func markFailure(_ error: Error) {
        refreshSchedule.failed(at: Date())
        isLoading = false
        isRefreshInFlight = false
        isStale = balance != nil
        switch error {
        case DeepSeekClient.ClientError.unauthorized:
            errorMessage = L10n.string("error.deepseek.unauthorized")
        case DeepSeekClient.ClientError.invalidPayload:
            errorMessage = L10n.string("error.deepseek.unavailable")
        case DeepSeekClient.ClientError.requestFailed:
            errorMessage = L10n.string("error.deepseek.unavailable")
        default:
            errorMessage = L10n.string("error.deepseek.unavailable")
        }
    }

    private func installRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = isPopoverVisible ? Self.foregroundInterval : Self.backgroundInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.refreshSchedule.mayPoll(at: Date()) else { return }
                self.refresh()
            }
        }
        timer.tolerance = isPopoverVisible ? 2 : 10
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    deinit {
        refreshTimer?.invalidate()
    }
}
