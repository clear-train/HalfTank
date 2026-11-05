import Foundation

/// Product identity in one place.
///
/// HalfTank grew out of CodexMeter (MIT), and the rename moved the bundle
/// identifier, the Application Support directory, and the Keychain service.
/// Keeping the old values here lets the migration code find data written by
/// earlier builds without scattering literals across the app.
nonisolated enum AppIdentity {
    static let displayName = "HalfTank"
    static let bundleIdentifier = "com.github.cleartrain.HalfTank"
    static let supportDirectoryName = "HalfTank"
    static let repositoryURL = URL(string: "https://github.com/clear-train/HalfTank")!

    static let legacyDisplayName = "CodexMeter"
    static let legacyBundleIdentifier = "com.raycal.CodexMeter"
    static let legacySupportDirectoryName = "CodexMeter"

    /// Keychain items are namespaced by the bundle identifier so two builds cannot collide.
    static var pushCredentialService: String { bundleIdentifier + ".pushCredentials" }
    static var legacyPushCredentialService: String { legacyBundleIdentifier + ".pushCredentials" }
}
