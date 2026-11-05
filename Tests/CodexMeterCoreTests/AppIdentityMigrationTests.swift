import XCTest
@testable import CodexMeterCore

final class AppIdentityMigrationTests: XCTestCase {
    private let fileManager = FileManager.default
    private var base: URL!

    override func setUpWithError() throws {
        base = fileManager.temporaryDirectory
            .appendingPathComponent("halftank-identity-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: base)
    }

    private func writeLegacyDatabase() throws -> URL {
        let legacy = base.appendingPathComponent(AppIdentity.legacySupportDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
        let database = legacy.appendingPathComponent("UsageHistory.sqlite")
        try Data("legacy-database".utf8).write(to: database)
        try Data("legacy-wal".utf8).write(to: URL(fileURLWithPath: database.path + "-wal"))
        try Data("legacy-shm".utf8).write(to: URL(fileURLWithPath: database.path + "-shm"))
        return database
    }

    func testCopiesHistoryIntoTheRenamedDirectory() throws {
        _ = try writeLegacyDatabase()

        let destination = AppIdentityMigration.migrateSupportDirectoryIfNeeded(baseDirectory: base)

        let expected = base
            .appendingPathComponent(AppIdentity.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("UsageHistory.sqlite")
        XCTAssertEqual(destination?.path, expected.path)
        XCTAssertEqual(try Data(contentsOf: expected), Data("legacy-database".utf8))
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: expected.path + "-wal")),
            Data("legacy-wal".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: expected.path + "-shm")),
            Data("legacy-shm".utf8)
        )
    }

    func testDoesNotOverwriteExistingHistory() throws {
        _ = try writeLegacyDatabase()
        let destinationDirectory = base.appendingPathComponent(AppIdentity.supportDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destination = destinationDirectory.appendingPathComponent("UsageHistory.sqlite")
        try Data("new-database".utf8).write(to: destination)

        XCTAssertNil(AppIdentityMigration.migrateSupportDirectoryIfNeeded(baseDirectory: base))
        XCTAssertEqual(try Data(contentsOf: destination), Data("new-database".utf8))
    }

    func testSkipsWhenThereIsNothingToMigrate() throws {
        XCTAssertNil(AppIdentityMigration.migrateSupportDirectoryIfNeeded(baseDirectory: base))
        XCTAssertFalse(
            fileManager.fileExists(
                atPath: base.appendingPathComponent(AppIdentity.supportDirectoryName).path
            )
        )
    }

    func testCopiesMissingDefaultsAndKeepsNewerValues() throws {
        let suite = "halftank.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacyDomain = suite + ".legacy"
        let currentDomain = suite + ".current"
        defaults.setPersistentDomain(
            ["appearance": "dark", "menuBarStyle": "ring", "language": "english"],
            forName: legacyDomain
        )
        defaults.setPersistentDomain(["language": "simplifiedChinese"], forName: currentDomain)

        AppIdentityMigration.migrateDefaultsIfNeeded(
            defaults: defaults, legacyDomain: legacyDomain, currentDomain: currentDomain
        )

        XCTAssertEqual(defaults.string(forKey: "appearance"), "dark")
        XCTAssertEqual(defaults.string(forKey: "menuBarStyle"), "ring")
        // A value the renamed app already had wins over the legacy copy.
        let merged = defaults.persistentDomain(forName: currentDomain)
        XCTAssertEqual(merged?["language"] as? String, "simplifiedChinese")
        XCTAssertTrue(defaults.bool(forKey: AppIdentityMigration.defaultsFlagKey))
    }

    func testDefaultsMigrationRunsOnlyOnce() throws {
        let suite = "halftank.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacyDomain = suite + ".legacy"
        let currentDomain = suite + ".current"
        defaults.setPersistentDomain(["appearance": "dark"], forName: legacyDomain)

        AppIdentityMigration.migrateDefaultsIfNeeded(
            defaults: defaults, legacyDomain: legacyDomain, currentDomain: currentDomain
        )
        defaults.removeObject(forKey: "appearance")
        defaults.setPersistentDomain(["appearance": "light"], forName: legacyDomain)
        AppIdentityMigration.migrateDefaultsIfNeeded(
            defaults: defaults, legacyDomain: legacyDomain, currentDomain: currentDomain
        )

        XCTAssertNil(defaults.string(forKey: "appearance"))
    }

    func testIdentityMatchesTheRenamedBundle() {
        XCTAssertEqual(AppIdentity.displayName, "HalfTank")
        XCTAssertEqual(AppIdentity.supportDirectoryName, "HalfTank")
        XCTAssertEqual(AppIdentity.bundleIdentifier, "com.github.cleartrain.HalfTank")
        XCTAssertEqual(AppIdentity.pushCredentialService, "com.github.cleartrain.HalfTank.pushCredentials")
        XCTAssertEqual(AppIdentity.legacyPushCredentialService, "com.raycal.CodexMeter.pushCredentials")
    }
}
