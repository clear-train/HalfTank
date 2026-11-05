import Combine
import Foundation

/// Exposes OpenCode Go quota as the same UI state Codex quota uses.
///
/// OpenCode owns authentication. This service only reads the quota OpenCode
/// already reports, either through its CLI or through the console API.
@MainActor
final class OpenCodeGoUsageService: ObservableObject, UsageSource {
    @Published private(set) var windows: [UsageWindow] = []
    @Published private(set) var planType: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshInFlight = false
    @Published private(set) var isStale = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    /// OpenCode Go reports quota only; token activity stays unavailable.
    @Published private(set) var tokenUsage: TokenUsageSnapshot?
    @Published private(set) var isTokenUsageUnavailable = true
    @Published private(set) var tokenUsageErrorMessage: String?
    /// OpenCode Go has no banked reset credits.
    @Published private(set) var rateLimitResetCredits: CodexRateLimitResetCreditsSummary?

    private let settings: AppSettings
    private let history: UsageHistoryModel
    private let notificationManager: NotificationManager
    let pushNotificationService: PushNotificationService
    private var client: OpenCodeGoClient
    private var refreshTimer: Timer?
    /// True when the popover is showing this provider's history partition.
    private var isHistoryViewActive = false
    /// Latest partition that should be visible once this provider becomes the
    /// one the popover shows. Kept so switching providers needs no refetch.
    private var pendingHistoryActivation: (key: String, resetExisting: Bool, claimLegacyHistory: Bool)?
    private var isPopoverVisible = false
    private var refreshSchedule = CodexRefreshSchedule()
    private var isFetching = false
    private(set) var historyAccountKey: String?
    private var workspaceName: String?
    /// Console activity page for the signed-in workspace, when known.
    private(set) var consoleURL: URL? = URL(string: "https://opencode.ai/console")
    private var lastHistorySnapshot: [UsageWindow]?
    private var lastHistoryAccountKey: String?
    private var lastHistoryRecordAt: Date?

    init(
        settings: AppSettings,
        history: UsageHistoryModel,
        notificationManager: NotificationManager? = nil,
        pushNotificationService: PushNotificationService? = nil,
        autostart: Bool = true
    ) {
        self.settings = settings
        self.history = history
        self.notificationManager = notificationManager ?? NotificationManager()
        self.pushNotificationService = pushNotificationService ?? PushNotificationService(settings: settings)
        self.client = OpenCodeGoClient(channel: settings.openCodeGoChannel)

        Task { @MainActor [weak self] in
            guard let self, autostart else { return }
            self.installRefreshTimer()
            self.start()
        }
    }

    var mostConstrainedRemainingPercent: Int? {
        mostConstrainedWindow?.remainingPercent
    }

    var mostConstrainedWindow: UsageWindow? {
        windows.min { $0.remainingPercent < $1.remainingPercent }
    }

    var menuBarTitle: String {
        guard let remaining = mostConstrainedRemainingPercent else {
            return isLoading ? "…" : "--"
        }
        return "\(remaining)%"
    }

    var accountDescription: String {
        guard planType != nil else { return L10n.string("account.checking") }
        if let workspaceName, !workspaceName.isEmpty {
            return L10n.format("account.opencode_go_workspace_format", workspaceName)
        }
        return L10n.string("account.opencode_go")
    }

    // MARK: - Provider activation

    /// Starts polling. Several providers poll at the same time; the popover
    /// shows exactly one of them.
    func activate() {
        installRefreshTimer()
        start()
    }

    /// Stops polling without discarding the last snapshot.
    func deactivate() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        isPopoverVisible = false
    }

    /// Toggles ownership of the visible history partition. Recording keeps
    /// working for every source because `recordQuota` is keyed per account.
    func setHistoryViewActive(_ active: Bool) {
        guard isHistoryViewActive != active else { return }
        isHistoryViewActive = active
        if active {
            guard let pending = pendingHistoryActivation else { return }
            history.activateAccount(
                pending.key,
                resetExisting: pending.resetExisting,
                claimLegacyHistory: pending.claimLegacyHistory
            )
        } else {
            pendingHistoryActivation = pendingHistoryActivation
                ?? historyAccountKey.map { (key: $0, resetExisting: false, claimLegacyHistory: false) }
            history.deactivateAccount()
        }
    }

    func start() {
        if windows.isEmpty {
            isLoading = true
        } else {
            isStale = true
        }
        refresh()
    }

    /// Applies a changed transport preference without waiting for a relaunch.
    func updateChannel(_ channel: OpenCodeGoChannel) {
        client = OpenCodeGoClient(channel: channel)
        refresh()
    }

    func refresh() {
        guard !isFetching else { return }
        isFetching = true
        isRefreshInFlight = true
        if windows.isEmpty { isLoading = true }

        let client = self.client
        Task { [weak self] in
            do {
                let snapshot = try await client.fetchUsage()
                await MainActor.run {
                    guard let self else { return }
                    self.isFetching = false
                    self.apply(snapshot)
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

    func refreshIfNeeded(maxAge: TimeInterval = 10) {
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

    private func apply(_ snapshot: OpenCodeGoUsageSnapshot) {
        let names: [UsageWindowKind: String] = [
            .rolling: L10n.string("provider.opencode_go.window.rolling"),
            .weekly: L10n.string("provider.opencode_go.window.weekly"),
            .monthly: L10n.string("provider.opencode_go.window.monthly")
        ]
        var parsed = OpenCodeGoWindowMapper.windows(from: snapshot, names: names)
        parsed.sort {
            ($0.windowDurationMins ?? Int.max) < ($1.windowDurationMins ?? Int.max)
        }

        let updatedAt = Date()
        if windows != parsed { windows = parsed }
        planType = "Go"
        if let name = snapshot.workspaceName, !name.isEmpty { workspaceName = name }
        if let url = snapshot.usageURL { consoleURL = url }

        let accountKey = UsageProvider.openCodeGo.historyAccountKey(for: snapshot.workspaceID)
        if historyAccountKey != accountKey {
            historyAccountKey = accountKey
            pendingHistoryActivation = (accountKey, false, false)
            if isHistoryViewActive {
                history.activateAccount(accountKey, resetExisting: false, claimLegacyHistory: false)
            }
        }

        isLoading = false
        isRefreshInFlight = false
        isStale = false
        lastUpdated = updatedAt
        errorMessage = nil
        refreshSchedule.succeeded()

        if shouldRecordHistory(parsed, accountKey: accountKey, at: updatedAt) {
            lastHistoryAccountKey = accountKey
            lastHistorySnapshot = parsed
            lastHistoryRecordAt = updatedAt
            history.recordQuota(
                windows: parsed,
                at: updatedAt,
                isStale: false,
                source: .refresh,
                retention: settings.historyRetention,
                accountKey: accountKey
            )
        }

        if settings.notificationsEnabled {
            notificationManager.evaluate(
                windows: parsed,
                threshold: settings.notificationThreshold
            )
        }
        pushNotificationService.evaluate(windows: parsed)
    }

    /// Mirrors the Codex recorder: write changes immediately plus a 15-minute
    /// anchor so an idle quota window still produces a heartbeat sample.
    private func shouldRecordHistory(_ current: [UsageWindow], accountKey: String, at date: Date) -> Bool {
        guard lastHistoryAccountKey == accountKey,
              let previous = lastHistorySnapshot,
              let lastHistoryRecordAt else { return true }
        if date.timeIntervalSince(lastHistoryRecordAt) >= 15 * 60 { return true }
        guard previous.count == current.count else { return true }
        let previousByID = Dictionary(previous.map { ($0.historyID, $0) }, uniquingKeysWith: { first, _ in first })
        for window in current {
            guard let old = previousByID[window.historyID] else { return true }
            if old.usedPercent != window.usedPercent || old.resetsAt != window.resetsAt {
                return true
            }
        }
        return false
    }

    private func markFailure(_ error: Error) {
        refreshSchedule.failed(at: Date())
        isLoading = false
        isRefreshInFlight = false
        isStale = !windows.isEmpty
        if let clientError = error as? OpenCodeGoClientError {
            errorMessage = L10n.string(clientError.localizationKey)
        } else {
            errorMessage = L10n.string("error.opencode.usage_unavailable")
        }
    }

    private func installRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = isPopoverVisible
            ? CodexRefreshSchedule.foregroundQuotaInterval
            : CodexRefreshSchedule.backgroundQuotaInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.refreshSchedule.mayPoll(at: Date()) else { return }
                self.refresh()
            }
        }
        timer.tolerance = isPopoverVisible ? 1 : 5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    deinit {
        refreshTimer?.invalidate()
    }
}
