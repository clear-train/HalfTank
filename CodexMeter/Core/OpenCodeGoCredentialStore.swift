import Foundation
import SQLite3

/// A locally discoverable OpenCode credential.
///
/// The app never writes this credential back. OpenCode owns refresh tokens, and
/// rotating one outside OpenCode would sign the user out of their own CLI.
nonisolated struct OpenCodeGoCredential: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let server: URL
    let organizationID: String?
    let accountID: String?
    let email: String?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
}

/// Reads the credential OpenCode already stored on this Mac.
///
/// OpenCode persists console sessions in `opencode.db` (v2) or `auth.json`
/// (v1). Both are opened read-only so a metadata refresh in CodexMeter can never
/// corrupt or rotate the CLI's session state.
nonisolated enum OpenCodeGoCredentialStore {
    static let databaseFileName = "opencode.db"

    static func defaultDataDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("opencode", isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".local/share/opencode", isDirectory: true)
    }

    /// The newest credential for the `opencode` integration, if any.
    static func load(
        dataDirectory: URL = defaultDataDirectory(),
        fileManager: FileManager = .default
    ) -> OpenCodeGoCredential? {
        let databaseURL = dataDirectory.appendingPathComponent(databaseFileName)
        if fileManager.fileExists(atPath: databaseURL.path),
           let credential = loadFromDatabase(databaseURL: databaseURL) {
            return credential
        }
        let authURL = dataDirectory.appendingPathComponent("auth.json")
        return loadFromAuthJSON(authURL: authURL)
    }

    private static func loadFromDatabase(databaseURL: URL) -> OpenCodeGoCredential? {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 500)

        let sql = "SELECT value FROM credential WHERE integration_id = 'opencode' ORDER BY id DESC"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var candidates: [OpenCodeGoCredential] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 0) else { continue }
            let value = String(cString: cString)
            guard let data = value.data(using: .utf8),
                  let credential = parseCredentialJSON(data) else { continue }
            candidates.append(credential)
        }
        return newest(candidates)
    }

    private static func loadFromAuthJSON(authURL: URL) -> OpenCodeGoCredential? {
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let entry = root["opencode"] as? [String: Any] ?? root
        guard let entryData = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
        return parseCredentialJSON(entryData)
    }

    static func parseCredentialJSON(_ data: Data) -> OpenCodeGoCredential? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let metadata = object["metadata"] as? [String: Any] ?? [:]

        let accessToken = (object["access"] as? String)
            ?? (object["access_token"] as? String)
            ?? (object["key"] as? String)
        guard let accessToken, !accessToken.isEmpty else { return nil }

        let serverString = (metadata["server"] as? String)
            ?? (object["server"] as? String)
            ?? "https://opencode.ai/console"
        let server = URL(string: serverString) ?? URL(string: "https://opencode.ai/console")!

        let expires: Date? = {
            if let millis = metadata["expires"] as? Double { return Date(timeIntervalSince1970: millis / 1000) }
            if let millis = object["expires"] as? Double { return Date(timeIntervalSince1970: millis / 1000) }
            if let seconds = object["expires_in"] as? Double { return Date().addingTimeInterval(seconds) }
            return nil
        }()

        return OpenCodeGoCredential(
            accessToken: accessToken,
            refreshToken: (object["refresh"] as? String) ?? (object["refresh_token"] as? String),
            expiresAt: expires,
            server: server,
            organizationID: (metadata["orgID"] as? String) ?? (object["orgID"] as? String),
            accountID: (metadata["accountID"] as? String) ?? (object["accountID"] as? String),
            email: metadata["email"] as? String
        )
    }

    /// Prefers the credential that stays valid longest so a stale duplicate row
    /// cannot mask a freshly refreshed session.
    private static func newest(_ credentials: [OpenCodeGoCredential]) -> OpenCodeGoCredential? {
        credentials.max { lhs, rhs in
            (lhs.expiresAt ?? .distantPast) < (rhs.expiresAt ?? .distantPast)
        }
    }
}
