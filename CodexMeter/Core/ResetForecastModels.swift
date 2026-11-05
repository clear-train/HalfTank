import Foundation

/// A community estimate of whether Codex resets today, plus the signals behind it.
/// The values are advisory: nothing here is an official OpenAI commitment, so the
/// UI must always keep the "estimate, not a guarantee" wording next to them.
nonisolated struct ResetForecast: Equatable, Sendable {
    let didResetToday: Bool?
    let lastResetAt: Date?
    let probability: Double
    let signals: [ResetForecastSignal]
    let nextExpectedAt: Date?
    let fetchedAt: Date
    let sourceURL: URL?

    var probabilityPercent: Int {
        Int((probability * 100).rounded())
    }
}

nonisolated struct ResetForecastSignal: Equatable, Sendable, Identifiable {
    let key: String
    let value: String
    let impactPoints: Int

    var id: String { key }
}

nonisolated enum ResetForecastError: Error, Equatable {
    case invalidPayload
}

nonisolated enum ResetForecastParser {
    /// Decodes the tracker's `/api/status` document. Only the fields the popover
    /// shows are required; everything else is tolerated so an added field or a
    /// reordered key cannot break the section.
    static func parse(
        _ data: Data,
        fetchedAt: Date,
        sourceURL: URL? = nil
    ) throws -> ResetForecast {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prediction = root["prediction"] as? [String: Any],
              let probabilityValue = numeric(prediction["probability"]) else {
            throw ResetForecastError.invalidPayload
        }

        let status = root["status"] as? [String: Any]
        let didResetToday: Bool?
        switch (status?["status"] as? String)?.lowercased() {
        case "yes":
            didResetToday = true
        case "no":
            didResetToday = false
        default:
            didResetToday = nil
        }

        let signals = (prediction["signals"] as? [[String: Any]] ?? []).compactMap { raw -> ResetForecastSignal? in
            guard let key = raw["key"] as? String, !key.isEmpty else { return nil }
            return ResetForecastSignal(
                key: key,
                value: stringValue(raw["value"]),
                impactPoints: Int(numeric(raw["impactPts"]) ?? 0)
            )
        }

        return ResetForecast(
            didResetToday: didResetToday,
            lastResetAt: date(status?["lastResetAt"]),
            probability: min(max(probabilityValue, 0), 1),
            signals: signals,
            nextExpectedAt: date(prediction["nextExpectedAt"]),
            fetchedAt: fetchedAt,
            sourceURL: sourceURL
        )
    }

    private static func numeric(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private static func stringValue(_ value: Any?) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case nil:
            return ""
        default:
            return String(describing: value!)
        }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        if let parsed = fractionalFormatter.date(from: string) {
            return parsed
        }
        return plainFormatter.date(from: string)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter = ISO8601DateFormatter()
}

/// The tracker refreshes hourly, so the app never needs to poll faster than that.
nonisolated enum ResetForecastSchedule {
    static let minimumInterval: TimeInterval = 60 * 60

    static func shouldRefresh(
        lastAttemptAt: Date?,
        now: Date,
        minimumInterval: TimeInterval = minimumInterval
    ) -> Bool {
        guard let lastAttemptAt else { return true }
        return now.timeIntervalSince(lastAttemptAt) >= minimumInterval
    }
}
