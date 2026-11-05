import Combine
import Foundation

/// Owns the opt-in reset forecast. It never polls on its own: the coordinator
/// pokes it when the popover opens or a manual refresh runs, and the hourly
/// schedule keeps a burst of clicks from turning into a burst of requests.
@MainActor
final class ResetForecastService: ObservableObject {
    @Published private(set) var forecast: ResetForecast?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastAttemptAt: Date?

    private let client: ResetForecastClient
    private var isEnabled = false

    init(client: ResetForecastClient = ResetForecastClient()) {
        self.client = client
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if !enabled {
            errorMessage = nil
        }
    }

    /// Call when the popover becomes visible or the user asks for a refresh.
    func noteActivity(now: Date = Date(), force: Bool = false) {
        guard isEnabled, !isLoading else { return }
        guard force || ResetForecastSchedule.shouldRefresh(lastAttemptAt: lastAttemptAt, now: now) else { return }

        lastAttemptAt = now
        isLoading = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await self.client.fetch(now: now)
                self.apply(fetched)
            } catch {
                self.markFailure()
            }
        }
    }

    private func apply(_ value: ResetForecast) {
        forecast = value
        isLoading = false
        errorMessage = nil
    }

    private func markFailure() {
        isLoading = false
        // Keep whatever the last successful fetch produced; only surface an error
        // when there is nothing meaningful to show.
        if forecast == nil {
            errorMessage = L10n.string("reset.forecast.unavailable")
        }
    }
}
