import Foundation

/// One quota meter reported by OpenCode Go.
///
/// The service reports *used* percentage for every meter, matching the Codex
/// `usedPercent` convention so the shared ring, pace, and history calculations
/// work unchanged.
nonisolated struct OpenCodeGoMeter: Equatable, Sendable {
    let kind: UsageWindowKind
    let usedPercent: Int
    let isLimited: Bool
    let resetsAt: Date?
}

/// A complete OpenCode Go usage reading from either data path.
nonisolated struct OpenCodeGoUsageSnapshot: Equatable, Sendable {
    let workspaceID: String?
    let workspaceName: String?
    let usageURL: URL?
    let meters: [OpenCodeGoMeter]
    let fetchedAt: Date
}

nonisolated enum OpenCodeGoUsageError: Error, Equatable {
    case invalidPayload
    case notSubscribed
    case unauthorized
}

/// Decodes the two payload shapes OpenCode exposes for the same data.
///
/// The CLI wraps the API body in `{"location": ..., "data": ...}` and reports
/// `resetsAt` as epoch milliseconds, while the direct endpoint returns
/// `{"usage": ...}` with ISO 8601 reset strings. Both are accepted here so a
/// single tolerant parser feeds the UI.
nonisolated enum OpenCodeGoUsageParser {
    static func parseCommandPayload(_ data: Data, fetchedAt: Date = Date()) throws -> OpenCodeGoUsageSnapshot {
        let root = try jsonObject(from: data)
        if root["data"] is NSNull {
            throw OpenCodeGoUsageError.notSubscribed
        }
        guard let body = root["data"] as? [String: Any] else {
            throw OpenCodeGoUsageError.invalidPayload
        }
        return try parseInfo(body, fetchedAt: fetchedAt)
    }

    static func parseDirectPayload(_ data: Data, fetchedAt: Date = Date()) throws -> OpenCodeGoUsageSnapshot {
        let root = try jsonObject(from: data)
        guard let usage = root["usage"] as? [String: Any] else {
            throw OpenCodeGoUsageError.invalidPayload
        }

        var meters: [OpenCodeGoMeter] = []
        for kind in UsageWindowKind.allCases {
            guard let raw = usage[kind.rawValue] as? [String: Any] else { continue }
            let status = raw["status"] as? String
            meters.append(OpenCodeGoMeter(
                kind: kind,
                usedPercent: percent(from: raw["percent"]),
                isLimited: status == "rate-limited",
                resetsAt: resetDate(from: raw["resetsAt"])
            ))
        }

        guard !meters.isEmpty else { throw OpenCodeGoUsageError.invalidPayload }
        return OpenCodeGoUsageSnapshot(
            workspaceID: nil,
            workspaceName: nil,
            usageURL: nil,
            meters: meters,
            fetchedAt: fetchedAt
        )
    }

    private static func parseInfo(_ body: [String: Any], fetchedAt: Date) throws -> OpenCodeGoUsageSnapshot {
        let workspace = body["workspace"] as? [String: Any]
        let usageURL = (workspace?["usageURL"] as? String).flatMap(URL.init(string:))

        guard let go = body["go"] as? [String: Any] else {
            throw OpenCodeGoUsageError.notSubscribed
        }

        var meters: [OpenCodeGoMeter] = []
        for kind in UsageWindowKind.allCases {
            guard let raw = go[kind.rawValue] as? [String: Any] else { continue }
            meters.append(OpenCodeGoMeter(
                kind: kind,
                usedPercent: percent(from: raw["percent"]),
                isLimited: raw["limited"] as? Bool ?? false,
                resetsAt: resetDate(from: raw["resetsAt"])
            ))
        }

        guard !meters.isEmpty else { throw OpenCodeGoUsageError.invalidPayload }
        return OpenCodeGoUsageSnapshot(
            workspaceID: workspace?["id"] as? String,
            workspaceName: workspace?["name"] as? String,
            usageURL: usageURL,
            meters: meters,
            fetchedAt: fetchedAt
        )
    }

    private static func jsonObject(from data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenCodeGoUsageError.invalidPayload
        }
        return object
    }

    private static func percent(from value: Any?) -> Int {
        let number: Double
        switch value {
        case let double as Double: number = double
        case let int as Int: number = Double(int)
        case let string as String: number = Double(string) ?? 0
        default: number = 0
        }
        return max(0, min(100, Int(number.rounded())))
    }

    private static func resetDate(from value: Any?) -> Date? {
        switch value {
        case let number as Double:
            return epochDate(number)
        case let number as Int:
            return epochDate(Double(number))
        case let string as String:
            if let date = isoDate(string) { return date }
            guard let seconds = Double(string) else { return nil }
            return epochDate(seconds)
        default:
            return nil
        }
    }

    private static func epochDate(_ raw: Double) -> Date? {
        guard raw > 0 else { return nil }
        // Accept seconds, milliseconds, and microseconds to stay tolerant of
        // future payload changes.
        if raw > 1_000_000_000_000_000 { return Date(timeIntervalSince1970: raw / 1_000_000) }
        if raw > 100_000_000_000 { return Date(timeIntervalSince1970: raw / 1_000) }
        return Date(timeIntervalSince1970: raw)
    }

    private static func isoDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

/// Builds the shared `UsageWindow` values the rest of the app renders.
nonisolated enum OpenCodeGoWindowMapper {
    static func windows(
        from snapshot: OpenCodeGoUsageSnapshot,
        names: [UsageWindowKind: String],
        calendar: Calendar = .current
    ) -> [UsageWindow] {
        snapshot.meters.compactMap { meter in
            guard let name = names[meter.kind] else { return nil }
            return UsageWindow(
                id: "opencode-go-\(meter.kind.rawValue)",
                name: name,
                usedPercent: meter.usedPercent,
                windowDurationMins: durationMins(for: meter, calendar: calendar),
                resetsAt: meter.resetsAt,
                isDurationDerived: meter.kind == .monthly
            )
        }
    }

    /// The gateway reports only a percentage and the next reset instant for the
    /// monthly meter, so its length has to come from the reset date itself. The
    /// billing anchor is a calendar day, therefore subtract one month in the
    /// user's calendar instead of assuming 30 days.
    static func durationMins(for meter: OpenCodeGoMeter, calendar: Calendar = .current) -> Int? {
        switch meter.kind {
        case .rolling, .weekly:
            return meter.kind.nominalDurationMins
        case .monthly:
            guard let resetsAt = meter.resetsAt,
                  let start = calendar.date(byAdding: .month, value: -1, to: resetsAt)
            else { return nil }
            let minutes = resetsAt.timeIntervalSince(start) / 60
            guard minutes > 0 else { return nil }
            return Int(minutes.rounded())
        }
    }
}
