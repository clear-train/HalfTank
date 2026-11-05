import Foundation
import Security

nonisolated struct DeepSeekKeychainFailure: Error, Equatable {
    let status: OSStatus
}

/// Stores the DeepSeek API key in the login keychain.
///
/// The key is a bearer credential for the user's own DeepSeek account, so it
/// never goes to UserDefaults and never leaves the login keychain.
nonisolated enum DeepSeekKeychain {
    static let service = AppIdentity.bundleIdentifier + ".deepseek"
    static let account = "api-key"

    static func read() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                throw DeepSeekKeychainFailure(status: errSecDecode)
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw DeepSeekKeychainFailure(status: status)
        }
    }

    static func save(_ value: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery()
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
                throw DeepSeekKeychainFailure(status: addStatus)
            }
        default:
            throw DeepSeekKeychainFailure(status: status)
        }
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeepSeekKeychainFailure(status: status)
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

nonisolated enum DeepSeekCredentialSource: Equatable, Sendable {
    /// `DEEPSEEK_API_KEY` from the launching environment.
    case environment
    /// The key saved from Settings into the login keychain.
    case keychain
}

nonisolated struct DeepSeekApiKey: Equatable, Sendable {
    let value: String
    let source: DeepSeekCredentialSource
}

/// Resolves the DeepSeek API key on every refresh: the environment first so a
/// shell export always wins, then the keychain entry the settings pane writes.
///
/// Backends are closures rather than a protocol because the app target compiles
/// with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; a protocol would become
/// main-actor isolated and could not be satisfied from this nonisolated store.
nonisolated final class DeepSeekCredentialStore {
    static let environmentKey = "DEEPSEEK_API_KEY"

    private let environment: [String: String]
    private let readStored: () throws -> String?
    private let saveStored: (String) throws -> Void
    private let deleteStored: () throws -> Void

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        readStored: @escaping () throws -> String? = { try DeepSeekKeychain.read() },
        saveStored: @escaping (String) throws -> Void = { try DeepSeekKeychain.save($0) },
        deleteStored: @escaping () throws -> Void = { try DeepSeekKeychain.delete() }
    ) {
        self.environment = environment
        self.readStored = readStored
        self.saveStored = saveStored
        self.deleteStored = deleteStored
    }

    var environmentKey: String? {
        guard let value = environment[Self.environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    var hasEnvironmentKey: Bool { environmentKey != nil }

    var storedKey: String? {
        guard let value = try? readStored()?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    var hasStoredKey: Bool { storedKey != nil }

    func resolve() -> DeepSeekApiKey? {
        if let value = environmentKey {
            return DeepSeekApiKey(value: value, source: .environment)
        }
        if let value = storedKey {
            return DeepSeekApiKey(value: value, source: .keychain)
        }
        return nil
    }

    func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteStored()
            return
        }
        try saveStored(trimmed)
    }

    func remove() throws {
        try deleteStored()
    }
}
