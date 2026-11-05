import Foundation

/// One-time move of data written before the HalfTank rename.
///
/// The database is copied rather than moved: an older build may still be
/// installed and should keep working, and the copy keeps the user's quota
/// history when they launch the renamed app for the first time. Both steps are
/// idempotent — they return immediately once the new location or the settings
/// flag already exists.
nonisolated enum AppIdentityMigration {
    static let defaultsFlagKey = "identity.migratedFromCodexMeter"

    static func applicationSupportBase(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    static func supportDirectory(
        for name: String, fileManager: FileManager = .default, baseDirectory: URL? = nil
    ) -> URL {
        let base = baseDirectory ?? applicationSupportBase(fileManager: fileManager)
        return base.appendingPathComponent(name, isDirectory: true)
    }

    /// Copies the history database, its write-ahead log, and the shared-memory
    /// index into the renamed directory when nothing is there yet.
    ///
    /// - Returns: the destination database URL, or nil when there was nothing
    ///   to migrate (or the copy failed, in which case the app starts empty and
    ///   the legacy database stays untouched).
    @discardableResult
    static func migrateSupportDirectoryIfNeeded(
        fileManager: FileManager = .default, baseDirectory: URL? = nil
    ) -> URL? {
        let legacyDirectory = supportDirectory(
            for: AppIdentity.legacySupportDirectoryName, fileManager: fileManager, baseDirectory: baseDirectory
        )
        let destinationDirectory = supportDirectory(
            for: AppIdentity.supportDirectoryName, fileManager: fileManager, baseDirectory: baseDirectory
        )
        let legacyDatabase = legacyDirectory.appendingPathComponent("UsageHistory.sqlite")
        let destinationDatabase = destinationDirectory.appendingPathComponent("UsageHistory.sqlite")

        guard !fileManager.fileExists(atPath: destinationDatabase.path),
              fileManager.fileExists(atPath: legacyDatabase.path) else {
            return nil
        }

        do {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            // Copy the log files before the database so a crash cannot leave a
            // database that points at a partially copied log.
            for suffix in ["-wal", "-shm"] {
                let source = URL(fileURLWithPath: legacyDatabase.path + suffix)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let destination = URL(fileURLWithPath: destinationDatabase.path + suffix)
                try? fileManager.copyItem(at: source, to: destination)
            }
            try fileManager.copyItem(at: legacyDatabase, to: destinationDatabase)
            return destinationDatabase
        } catch {
            // A failed migration must not block launch; the user keeps the old data.
            try? fileManager.removeItem(at: destinationDirectory)
            return nil
        }
    }

    /// Copies settings keys that the renamed bundle identifier can no longer see.
    ///
    /// Only missing keys are copied so a second launch never resurrects a value
    /// the user changed in HalfTank.
    static func migrateDefaultsIfNeeded(
        defaults: UserDefaults = .standard,
        legacyDomain: String = AppIdentity.legacyBundleIdentifier,
        currentDomain: String = AppIdentity.bundleIdentifier
    ) {
        guard !defaults.bool(forKey: defaultsFlagKey) else { return }
        defer { defaults.set(true, forKey: defaultsFlagKey) }

        guard let legacy = defaults.persistentDomain(forName: legacyDomain) else {
            return
        }
        let current = defaults.persistentDomain(forName: currentDomain) ?? [:]

        for (key, value) in legacy where current[key] == nil {
            defaults.set(value, forKey: key)
        }
        defaults.synchronize()
    }
}
