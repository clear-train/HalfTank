import Combine
import Foundation
import Sparkle

struct AvailableUpdate: Equatable, Identifiable {
    let version: String
    let title: String?
    let releaseNotes: String?
    let releasePageURL: URL
    let publishedAt: Date?

    var id: String { version }
}

@MainActor
final class UpdateChecker: NSObject, ObservableObject, SPUUpdaterDelegate {
    enum State: Equatable {
        case notConfigured
        case idle
        case checking
        case upToDate
        case updateAvailable(AvailableUpdate)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var automaticallyInstallsUpdates = false
    @Published private(set) var isDeveloperPreview = false

    private let releasesURL = AppIdentity.repositoryURL.appendingPathComponent("releases")
    /// A build shipped without an EdDSA key or feed has no download source yet.
    /// Starting Sparkle in that state only produces an error the user cannot act
    /// on, so the updater stays off and the About pane explains why.
    private let feedIsConfigured: Bool
    private var includesPrereleases: Bool
    private var stateBeforeDeveloperPreview: State?
    private var updaterController: SPUStandardUpdaterController!

    init(includePrereleases: Bool = false) {
        includesPrereleases = includePrereleases
        feedIsConfigured = Self.hasConfiguredFeed()
        super.init()

        updaterController = SPUStandardUpdaterController(
            startingUpdater: feedIsConfigured,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        refreshPreferences()
    }

    /// Sparkle needs both a feed URL and the EdDSA public key that verifies the
    /// archives. Either one missing means this build cannot update itself.
    private static func hasConfiguredFeed() -> Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let feed = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !key.isEmpty && !feed.isEmpty
    }

    var isUpdateFeedConfigured: Bool { feedIsConfigured }

    var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var installedBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    var allowsAutomaticUpdates: Bool {
        updaterController.updater.allowsAutomaticUpdates
    }

    var canCheckForUpdates: Bool {
        feedIsConfigured && updaterController.updater.canCheckForUpdates
    }

    func check(includePrereleases: Bool) {
        guard feedIsConfigured else {
            state = .notConfigured
            return
        }
        setIncludesPrereleases(includePrereleases)
        if isDeveloperPreview {
            clearDeveloperPreview()
        }
        state = .checking
        updaterController.checkForUpdates(nil)
    }

    func setIncludesPrereleases(_ includePrereleases: Bool) {
        guard feedIsConfigured, includesPrereleases != includePrereleases else { return }
        includesPrereleases = includePrereleases
        updaterController.updater.resetUpdateCycleAfterShortDelay()
    }

    func setAutomaticallyInstallsUpdates(_ enabled: Bool) {
        guard feedIsConfigured else { return }
        updaterController.updater.automaticallyDownloadsUpdates = enabled
        refreshPreferences()
    }

    func refreshPreferences() {
        automaticallyInstallsUpdates = feedIsConfigured
            && updaterController.updater.automaticallyDownloadsUpdates
    }

    func showDeveloperUpdatePreview() {
        if !isDeveloperPreview {
            stateBeforeDeveloperPreview = state
        }
        isDeveloperPreview = true
        state = .updateAvailable(AvailableUpdate(
            version: "9.9.9",
            title: "CodexMeter 9.9.9 Preview",
            releaseNotes: nil,
            releasePageURL: releasesURL.appending(path: "tag/v9.9.9"),
            publishedAt: nil
        ))
    }

    func clearDeveloperPreview() {
        guard isDeveloperPreview else { return }
        isDeveloperPreview = false
        state = stateBeforeDeveloperPreview ?? .idle
        stateBeforeDeveloperPreview = nil
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        includesPrereleases ? ["beta"] : []
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard !isDeveloperPreview else { return }
        state = .updateAvailable(AvailableUpdate(
            version: item.displayVersionString,
            title: item.title,
            releaseNotes: item.itemDescriptionFormat == "plain-text"
                ? item.itemDescription
                : nil,
            releasePageURL: item.infoURL ?? releasesURL,
            publishedAt: item.date
        ))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        guard !isDeveloperPreview else { return }
        state = .upToDate
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        guard !isDeveloperPreview else { return }
        if state == .upToDate {
            return
        }
        state = .failed(error.localizedDescription)
    }
}
