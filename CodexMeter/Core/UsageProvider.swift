import Foundation

/// A quota source the app can read and visualize.
///
/// Every provider exposes the same window shape so the rings, pace hints and
/// history charts stay provider agnostic. Anything Codex specific (banked
/// resets, token activity) is reported as `nil` by the other providers.
nonisolated enum UsageProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case openCodeGo
    /// Prepaid platform credit, read from a balance endpoint.
    case deepSeek
    case openRouter
    case moonshot
    case siliconFlow

    var id: String { rawValue }

    /// Accepts the spellings that can appear in saved preferences: the canonical
    /// raw value, the history namespace with a dash, and older lowercase JSON.
    /// Preferences outlive source edits, so decoding must not throw on them.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let normalized = raw
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        switch normalized {
        case "codex":
            self = .codex
        case "opencodego":
            self = .openCodeGo
        case "deepseek":
            self = .deepSeek
        case "openrouter":
            self = .openRouter
        case "moonshot":
            self = .moonshot
        case "siliconflow":
            self = .siliconFlow
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown quota provider \(raw)"
            )
        }
    }

    /// Sources a user can add or remove from the account list. The default
    /// Codex login is always present, so it is not part of this list.
    static var optionalProviders: [UsageProvider] {
        BalanceSource.allCases.map(balanceProvider(for:)) + [.openCodeGo]
    }

    /// The balance descriptor behind a money-only provider, if any.
    var balanceSource: BalanceSource? {
        switch self {
        case .deepSeek: return .deepSeek
        case .openRouter: return .openRouter
        case .moonshot: return .moonshot
        case .siliconFlow: return .siliconFlow
        case .codex, .openCodeGo: return nil
        }
    }

    static func balanceProvider(for source: BalanceSource) -> UsageProvider {
        switch source {
        case .deepSeek: return .deepSeek
        case .openRouter: return .openRouter
        case .moonshot: return .moonshot
        case .siliconFlow: return .siliconFlow
        }
    }

    /// Stable namespace that keeps local history separate per provider.
    var historyNamespace: String {
        switch self {
        case .codex: "codex"
        case .openCodeGo: "opencode-go"
        case .deepSeek: "deepseek"
        case .openRouter: "openrouter"
        case .moonshot: "moonshot"
        case .siliconFlow: "siliconflow"
        }
    }

    /// Prefixed account key handed to the history store.
    func historyAccountKey(for identifier: String?) -> String {
        guard let identifier, !identifier.isEmpty else { return historyNamespace }
        return "\(historyNamespace):\(identifier)"
    }
}

/// The window kinds a provider can report.
nonisolated enum UsageWindowKind: String, CaseIterable, Sendable {
    case rolling
    case weekly
    case monthly

    /// Nominal window length, used for the "remaining time" ring and pace hints.
    ///
    /// The monthly Go meter has no fixed length, so its duration is derived from
    /// the reported reset date in `OpenCodeGoWindowMapper` instead.
    var nominalDurationMins: Int? {
        switch self {
        case .rolling: 300
        case .weekly: 7 * 24 * 60
        case .monthly: nil
        }
    }
}
