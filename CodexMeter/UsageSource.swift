import Combine
import Foundation

/// The UI-facing surface every quota source exposes.
///
/// Views read the coordinator, which forwards to whichever source is selected,
/// so adding a provider does not require changing any view.
protocol UsageSource: ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    var windows: [UsageWindow] { get }
    var planType: String? { get }
    var isLoading: Bool { get }
    var isRefreshInFlight: Bool { get }
    var isStale: Bool { get }
    var errorMessage: String? { get }
    var lastUpdated: Date? { get }
    var tokenUsage: TokenUsageSnapshot? { get }
    var isTokenUsageUnavailable: Bool { get }
    var tokenUsageErrorMessage: String? { get }
    var rateLimitResetCredits: CodexRateLimitResetCreditsSummary? { get }
    var historyAccountKey: String? { get }
    var mostConstrainedRemainingPercent: Int? { get }
    var mostConstrainedWindow: UsageWindow? { get }
    var menuBarTitle: String { get }
    var accountDescription: String { get }
    var pushNotificationService: PushNotificationService { get }

    func activate()
    func deactivate()
    func refresh()
    func refreshIfNeeded(maxAge: TimeInterval)
    func setPopoverVisible(_ visible: Bool)
    func setNotificationsEnabled(_ enabled: Bool)

    /// Marks this source as the one whose history partition the popover shows.
    func setHistoryViewActive(_ active: Bool)
}
