import Foundation

/// One currency line of the DeepSeek platform balance.
///
/// The endpoint reports money as decimal strings so the server keeps the scale;
/// parsing keeps `Decimal` for the same reason instead of flattening to `Double`.
nonisolated struct DeepSeekBalanceLine: Equatable, Sendable {
    let currency: String
    let total: Decimal
    let granted: Decimal
    let toppedUp: Decimal
}

/// A parsed `GET /user/balance` response.
nonisolated struct DeepSeekBalanceSnapshot: Equatable, Sendable {
    let isAvailable: Bool
    let lines: [DeepSeekBalanceLine]
    let fetchedAt: Date

    /// Yuan first because that is how most accounts are topped up; otherwise the
    /// first line the endpoint returned. A second currency is shown by the
    /// popover only as a breakdown, never merged into this total.
    var preferred: DeepSeekBalanceLine? {
        lines.first { $0.currency.uppercased() == "CNY" } ?? lines.first
    }
}

nonisolated enum DeepSeekBalanceError: Equatable, Error {
    case invalidPayload
}

/// Formats money the same way in the popover, the tabs and the menu bar.
nonisolated enum DeepSeekBalanceFormat {
    static func amount(_ value: Decimal, currency: String, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = true
        let number = NSDecimalNumber(decimal: value)
        let text = formatter.string(from: number) ?? number.stringValue
        return "\(symbol(for: currency))\(text)"
    }

    static func symbol(for currency: String) -> String {
        switch currency.uppercased() {
        case "CNY": return "¥"
        case "USD": return "$"
        default: return "\(currency) "
        }
    }
}

nonisolated enum DeepSeekBalanceParser {
    /// Parses the documented payload. A body without a usable balance line is
    /// malformed rather than "zero": reporting zero would claim an account is
    /// empty when the server simply changed shape.
    static func parse(_ data: Data, fetchedAt: Date) throws -> DeepSeekBalanceSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeepSeekBalanceError.invalidPayload
        }
        guard let rawLines = root["balance_infos"] as? [[String: Any]] else {
            throw DeepSeekBalanceError.invalidPayload
        }
        let lines: [DeepSeekBalanceLine] = rawLines.compactMap { raw in
            guard let currency = raw["currency"] as? String,
                  let total = decimal(raw["total_balance"]) else { return nil }
            return DeepSeekBalanceLine(
                currency: currency,
                total: total,
                granted: decimal(raw["granted_balance"]) ?? 0,
                toppedUp: decimal(raw["topped_up_balance"]) ?? 0
            )
        }
        guard !lines.isEmpty else { throw DeepSeekBalanceError.invalidPayload }
        return DeepSeekBalanceSnapshot(
            isAvailable: (root["is_available"] as? Bool) ?? false,
            lines: lines,
            fetchedAt: fetchedAt
        )
    }

    static func decimal(_ value: Any?) -> Decimal? {
        // `en_US_POSIX` keeps a dot as the decimal separator regardless of the
        // user's locale; the endpoint always sends that form.
        let posix = Locale(identifier: "en_US_POSIX")
        switch value {
        case let text as String:
            return Decimal(string: text, locale: posix)
        case let number as NSNumber:
            return Decimal(string: number.stringValue, locale: posix)
        default:
            return nil
        }
    }
}

/// Turns a balance into one quota window when the user configured a budget.
///
/// The balance endpoint has no reset cycle and no percentage of its own, so the
/// ring is only honest when the user says how much money the balance represents
/// as 100%. Without a budget the provider stays money-only.
nonisolated enum DeepSeekBalanceWindow {
    static let windowID = "deepseek-balance"

    static func window(
        for snapshot: DeepSeekBalanceSnapshot,
        budget: Decimal,
        name: String
    ) -> UsageWindow? {
        guard budget > 0, let line = snapshot.preferred else { return nil }
        let ratio = (line.total as NSDecimalNumber).doubleValue / (budget as NSDecimalNumber).doubleValue
        let remaining = Int((ratio * 100).rounded())
        let used = 100 - min(max(remaining, 0), 100)
        return UsageWindow(
            id: windowID,
            name: name,
            usedPercent: used,
            windowDurationMins: nil,
            resetsAt: nil,
            isDurationDerived: false
        )
    }
}
