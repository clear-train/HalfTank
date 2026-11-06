import Foundation
import Security

nonisolated struct BalanceKeychainFailure: Error, Equatable {
    let status: OSStatus
}

/// Stores one provider's API key in the login keychain.
///
/// A key is a bearer credential for the user's own account, so it never goes to
/// UserDefaults and never leaves the login keychain.
nonisolated enum BalanceKeychain {
    static let account = "api-key"

    static func service(for source: BalanceSource) -> String {
        AppIdentity.bundleIdentifier + source.keychainServiceSuffix
    }

    static func read(source: BalanceSource) throws -> String? {
        var query = baseQuery(source: source)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                throw BalanceKeychainFailure(status: errSecDecode)
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw BalanceKeychainFailure(status: status)
        }
    }

    static func save(_ value: String, source: BalanceSource) throws {
        let data = Data(value.utf8)
        let query = baseQuery(source: source)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insertion = query
            insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw BalanceKeychainFailure(status: addStatus)
            }
        default:
            throw BalanceKeychainFailure(status: status)
        }
    }

    static func delete(source: BalanceSource) throws {
        let status = SecItemDelete(baseQuery(source: source) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BalanceKeychainFailure(status: status)
        }
    }

    private static func baseQuery(source: BalanceSource) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: source),
            kSecAttrAccount as String: account
        ]
    }
}

nonisolated enum BalanceCredentialSource: Equatable, Sendable {
    /// The provider's environment variable from the launching environment.
    case environment
    /// The key saved from Settings into the login keychain.
    case keychain
}

nonisolated struct BalanceApiKey: Equatable, Sendable {
    let value: String
    let source: BalanceCredentialSource
}

/// Resolves a provider's API key on every refresh: the environment first so a
/// shell export always wins, then the keychain entry the settings pane writes.
///
/// Backends are closures rather than a protocol because the app target compiles
/// with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; a protocol would become
/// main-actor isolated and could not be satisfied from this nonisolated store.
nonisolated final class BalanceKeyStore {
    let source: BalanceSource

    private let environment: [String: String]
    private let readStored: (BalanceSource) throws -> String?
    private let saveStored: (String, BalanceSource) throws -> Void
    private let deleteStored: (BalanceSource) throws -> Void

    init(
        source: BalanceSource,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        readStored: @escaping (BalanceSource) throws -> String? = { try BalanceKeychain.read(source: $0) },
        saveStored: @escaping (String, BalanceSource) throws -> Void = { try BalanceKeychain.save($0, source: $1) },
        deleteStored: @escaping (BalanceSource) throws -> Void = { try BalanceKeychain.delete(source: $0) }
    ) {
        self.source = source
        self.environment = environment
        self.readStored = readStored
        self.saveStored = saveStored
        self.deleteStored = deleteStored
    }

    var environmentKey: String? {
        guard let value = environment[source.environmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    var hasEnvironmentKey: Bool { environmentKey != nil }

    var storedKey: String? {
        guard let value = try? readStored(source)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    var hasStoredKey: Bool { storedKey != nil }

    func resolve() -> BalanceApiKey? {
        if let value = environmentKey {
            return BalanceApiKey(value: value, source: .environment)
        }
        if let value = storedKey {
            return BalanceApiKey(value: value, source: .keychain)
        }
        return nil
    }

    func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteStored(source)
            return
        }
        try saveStored(trimmed, source)
    }

    func remove() throws {
        try deleteStored(source)
    }
}
