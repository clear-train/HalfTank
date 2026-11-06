import Foundation

/// A provider whose dashboard is just money: prepaid credit that runs down.
///
/// These sources share one shape - a single authenticated `GET` that returns the
/// remaining amount - so they share one client, one credential store, and one
/// popover section. Quota providers with rolling windows stay on their own types.
nonisolated enum BalanceSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case deepSeek
    case openRouter
    case moonshot
    case siliconFlow

    var id: String { rawValue }

    /// Brand name; never translated.
    var displayName: String {
        switch self {
        case .deepSeek: return "DeepSeek"
        case .openRouter: return "OpenRouter"
        case .moonshot: return "Moonshot"
        case .siliconFlow: return "SiliconFlow"
        }
    }

    /// Environment variable checked before the keychain, mirroring how the rest
    /// of the app prefers an ambient credential over a stored one.
    var environmentVariable: String {
        switch self {
        case .deepSeek: return "DEEPSEEK_API_KEY"
        case .openRouter: return "OPENROUTER_API_KEY"
        case .moonshot: return "MOONSHOT_API_KEY"
        case .siliconFlow: return "SILICONFLOW_API_KEY"
        }
    }

    /// Suffix of the keychain service so two providers never share an item.
    var keychainServiceSuffix: String {
        switch self {
        case .deepSeek: return ".deepseek"
        case .openRouter: return ".openrouter"
        case .moonshot: return ".moonshot"
        case .siliconFlow: return ".siliconflow"
        }
    }

    var endpoint: URL {
        switch self {
        case .deepSeek:
            return URL(string: "https://api.deepseek.com/user/balance")!
        case .openRouter:
            return URL(string: "https://openrouter.ai/api/v1/credits")!
        case .moonshot:
            return URL(string: "https://api.moonshot.cn/v1/users/me/balance")!
        case .siliconFlow:
            return URL(string: "https://api.siliconflow.cn/v1/user/info")!
        }
    }

    /// Currency used when the payload reports a bare number.
    var fallbackCurrency: String {
        switch self {
        case .deepSeek, .moonshot, .siliconFlow: return "CNY"
        case .openRouter: return "USD"
        }
    }

    var helpURL: URL? {
        switch self {
        case .deepSeek:
            return URL(string: "https://platform.deepseek.com/api_keys")
        case .openRouter:
            return URL(string: "https://openrouter.ai/keys")
        case .moonshot:
            return URL(string: "https://platform.moonshot.cn/console/api-keys")
        case .siliconFlow:
            return URL(string: "https://cloud.siliconflow.cn/account/ak")
        }
    }

    /// Budget key inside `AppSettings.balanceBudgets`; one namespace per source so
    /// renaming a provider never collides with another.
    var budgetKey: String { rawValue }
}
