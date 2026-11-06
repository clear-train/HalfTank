import Foundation

/// One currency line of a prepaid balance.
///
/// Servers report money as decimal strings to keep the scale, so parsing keeps
/// `Decimal` instead of flattening to `Double`.
nonisolated struct BalanceLine: Equatable, Sendable {
    let currency: String
    let total: Decimal
    let granted: Decimal
    let toppedUp: Decimal
}

/// A parsed balance response, independent of which provider produced it.
nonisolated struct BalanceSnapshot: Equatable, Sendable {
    let source: BalanceSource
    let isAvailable: Bool
    let lines: [BalanceLine]
    let fetchedAt: Date

    /// Yuan first because that is how most accounts are topped up; otherwise the
    /// first line the endpoint returned. A second currency is only ever shown as
    /// a breakdown, never merged into this total.
    var preferred: BalanceLine? {
        lines.first { $0.currency.uppercased() == "CNY" } ?? lines.first
    }
}

nonisolated enum BalanceError: Equatable, Error {
    case invalidPayload
}

/// Formats money the same way in the popover, the tabs and the menu bar.
nonisolated enum BalanceFormat {
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

/// Turns a remaining balance into an ordinary quota window.
///
/// A balance has no length and no reset, so the ring only exists once the user
/// says what a full ring means. Without a budget there is nothing to draw and the
/// popover shows money instead.
nonisolated enum BalanceWindow {
    static let windowID = "balance"

    static func window(for snapshot: BalanceSnapshot, budget: Decimal, name: String) -> UsageWindow? {
        guard budget > 0, let line = snapshot.preferred else { return nil }
        let ratio = line.total / budget
        let percent = NSDecimalNumber(decimal: ratio * 100).rounding(
            accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain,
                scale: 0,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            )
        )
        let remaining = min(max(percent.intValue, 0), 100)
        return UsageWindow(
            id: windowID,
            name: name,
            usedPercent: 100 - remaining,
            windowDurationMins: nil,
            resetsAt: nil,
            isDurationDerived: false
        )
    }
}

/// Parses the handful of balance payloads this app understands.
nonisolated enum BalanceParser {
    static func parse(
        _ data: Data,
        source: BalanceSource,
        fetchedAt: Date
    ) throws -> BalanceSnapshot {
        switch source {
        case .deepSeek:
            let parsed = try DeepSeekBalanceParser.parse(data, fetchedAt: fetchedAt)
            return BalanceSnapshot(
                source: source,
                isAvailable: parsed.isAvailable,
                lines: parsed.lines.map {
                    BalanceLine(
                        currency: $0.currency,
                        total: $0.total,
                        granted: $0.granted,
                        toppedUp: $0.toppedUp
                    )
                },
                fetchedAt: parsed.fetchedAt
            )
        case .openRouter:
            return try parseOpenRouter(data, fetchedAt: fetchedAt)
        case .moonshot:
            return try parseMoonshot(data, fetchedAt: fetchedAt)
        case .siliconFlow:
            return try parseSiliconFlow(data, fetchedAt: fetchedAt)
        }
    }

    /// `{"data":{"total_credits":<purchased>,"total_usage":<spent>}}`
    ///
    /// The endpoint reports the lifetime totals, not the remainder, so the
    /// remaining credit is the difference. A negative remainder (a refund landed
    /// after usage) is clamped instead of rendering "-$3.00".
    private static func parseOpenRouter(_ data: Data, fetchedAt: Date) throws -> BalanceSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let credits = decimal(payload["total_credits"]),
              let usage = decimal(payload["total_usage"])
        else {
            throw BalanceError.invalidPayload
        }
        let remaining = max(credits - usage, 0)
        return BalanceSnapshot(
            source: .openRouter,
            isAvailable: true,
            lines: [
                BalanceLine(currency: "USD", total: remaining, granted: 0, toppedUp: credits)
            ],
            fetchedAt: fetchedAt
        )
    }

    /// `{"code":0,"data":{"available_balance":<n>,"voucher_balance":<n>,"cash_balance":<n>}}`
    private static func parseMoonshot(_ data: Data, fetchedAt: Date) throws -> BalanceSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let available = decimal(payload["available_balance"])
        else {
            throw BalanceError.invalidPayload
        }
        return BalanceSnapshot(
            source: .moonshot,
            isAvailable: true,
            lines: [
                BalanceLine(
                    currency: "CNY",
                    total: available,
                    granted: decimal(payload["voucher_balance"]) ?? 0,
                    toppedUp: decimal(payload["cash_balance"]) ?? 0
                )
            ],
            fetchedAt: fetchedAt
        )
    }

    /// `{"code":20000,"data":{"balance":"<granted>","chargeBalance":"<topped up>","totalBalance":"<total>"}}`
    private static func parseSiliconFlow(_ data: Data, fetchedAt: Date) throws -> BalanceSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let total = decimal(payload["totalBalance"])
        else {
            throw BalanceError.invalidPayload
        }
        return BalanceSnapshot(
            source: .siliconFlow,
            isAvailable: true,
            lines: [
                BalanceLine(
                    currency: "CNY",
                    total: total,
                    granted: decimal(payload["balance"]) ?? 0,
                    toppedUp: decimal(payload["chargeBalance"]) ?? 0
                )
            ],
            fetchedAt: fetchedAt
        )
    }

    /// Money arrives as a string on some providers and as a number on others.
    private static func decimal(_ value: Any?) -> Decimal? {
        switch value {
        case let text as String:
            return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
        case let number as NSNumber:
            return Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX"))
        case let number as Double:
            return Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX"))
        case let number as Int:
            return Decimal(number)
        default:
            return nil
        }
    }
}
