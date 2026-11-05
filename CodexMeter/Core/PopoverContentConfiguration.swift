import Foundation

enum PopoverContentSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case quotaWindows
    case resetCredits
    case resetForecast
    case quotaHistory
    case tokenActivity

    var id: String { rawValue }
}

/// Stores presentation-only choices for the menu-bar popover.
/// Hidden content continues to refresh and record history in the background.
struct PopoverContentConfiguration: Codable, Equatable, Sendable {
    var sectionOrder: [PopoverContentSection]
    var hiddenSections: Set<PopoverContentSection>
    var hiddenQuotaWindowIDs: Set<String>
    /// Menu bar window choice per account, keyed by `StoredQuotaAccount.id`.
    /// A missing entry means automatic mode: follow the most constrained window.
    var menuBarQuotaWindowIDs: [String: String]

    static let defaultValue = PopoverContentConfiguration(
        sectionOrder: PopoverContentSection.allCases,
        hiddenSections: [],
        hiddenQuotaWindowIDs: [
            QuotaHistoryWindowIdentity.make(
                sourceID: "base_model_inference",
                durationMins: 7 * 24 * 60
            )
        ],
        menuBarQuotaWindowIDs: [:]
    )

    init(
        sectionOrder: [PopoverContentSection],
        hiddenSections: Set<PopoverContentSection>,
        hiddenQuotaWindowIDs: Set<String>,
        menuBarQuotaWindowIDs: [String: String]
    ) {
        self.sectionOrder = sectionOrder
        self.hiddenSections = hiddenSections
        self.hiddenQuotaWindowIDs = hiddenQuotaWindowIDs
        self.menuBarQuotaWindowIDs = menuBarQuotaWindowIDs
        normalize()
    }

    func isSectionVisible(_ section: PopoverContentSection) -> Bool {
        !hiddenSections.contains(section)
    }

    mutating func setSection(_ section: PopoverContentSection, visible: Bool) {
        if visible {
            hiddenSections.remove(section)
        } else {
            hiddenSections.insert(section)
        }
    }

    func isQuotaWindowVisible(_ window: UsageWindow) -> Bool {
        !hiddenQuotaWindowIDs.contains(window.historyID)
    }

    mutating func setQuotaWindow(_ window: UsageWindow, visible: Bool) {
        if visible {
            hiddenQuotaWindowIDs.remove(window.historyID)
        } else {
            hiddenQuotaWindowIDs.insert(window.historyID)
        }
    }

    func visibleQuotaWindows(from windows: [UsageWindow]) -> [UsageWindow] {
        guard isSectionVisible(.quotaWindows) else { return [] }
        return windows.filter(isQuotaWindowVisible)
    }

    mutating func moveSection(_ section: PopoverContentSection, by offset: Int) {
        guard let sourceIndex = sectionOrder.firstIndex(of: section) else { return }
        let destinationIndex = sourceIndex + offset
        guard sectionOrder.indices.contains(destinationIndex) else { return }
        sectionOrder.swapAt(sourceIndex, destinationIndex)
    }

    func menuBarWindowID(forAccount accountID: String) -> String? {
        menuBarQuotaWindowIDs[accountID]
    }

    mutating func setMenuBarWindowID(_ id: String?, account accountID: String) {
        if let id {
            menuBarQuotaWindowIDs[accountID] = id
        } else {
            menuBarQuotaWindowIDs.removeValue(forKey: accountID)
        }
    }

    func selectedMenuBarWindow(from windows: [UsageWindow], account accountID: String) -> UsageWindow? {
        if let id = menuBarQuotaWindowIDs[accountID],
           let selected = windows.first(where: { $0.historyID == id }) {
            return selected
        }
        return windows.min { $0.remainingPercent < $1.remainingPercent }
    }

    func normalized() -> PopoverContentConfiguration {
        var copy = self
        copy.normalize()
        return copy
    }

    private mutating func normalize() {
        var seen: Set<PopoverContentSection> = []
        sectionOrder = sectionOrder.filter { seen.insert($0).inserted }
        sectionOrder.append(contentsOf: PopoverContentSection.allCases.filter { !seen.contains($0) })
    }

    private enum CodingKeys: String, CodingKey {
        case sectionOrder
        case hiddenSections
        case hiddenQuotaWindowIDs
        case menuBarQuotaWindowIDs
    }

    /// Key used before the menu bar choice became per-provider. It is read for
    /// migration only and never written again.
    private enum LegacyCodingKeys: String, CodingKey {
        case menuBarQuotaWindowID
    }

    /// Choices were briefly keyed by provider rather than account.
    private static func migratingLegacyProviderKeys(_ stored: [String: String]) -> [String: String] {
        var migrated: [String: String] = [:]
        for (key, value) in stored {
            if let provider = UsageProvider(rawValue: key) {
                migrated[provider == .codex ? StoredQuotaAccount.defaultCodexID : StoredQuotaAccount.openCodeGoID] = value
            } else {
                migrated[key] = value
            }
        }
        return migrated
    }

    private static func legacyMenuBarWindowID(from decoder: Decoder) -> String? {
        guard let container = try? decoder.container(keyedBy: LegacyCodingKeys.self) else {
            return nil
        }
        do {
            return try container.decodeIfPresent(String.self, forKey: .menuBarQuotaWindowID)
        } catch {
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let defaults = Self.defaultValue
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sectionOrder = try container.decodeIfPresent(
            [PopoverContentSection].self,
            forKey: .sectionOrder
        ) ?? defaults.sectionOrder
        hiddenSections = try container.decodeIfPresent(
            Set<PopoverContentSection>.self,
            forKey: .hiddenSections
        ) ?? defaults.hiddenSections
        hiddenQuotaWindowIDs = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .hiddenQuotaWindowIDs
        ) ?? defaults.hiddenQuotaWindowIDs
        if let stored = try container.decodeIfPresent(
            [String: String].self,
            forKey: .menuBarQuotaWindowIDs
        ) {
            menuBarQuotaWindowIDs = Self.migratingLegacyProviderKeys(stored)
        } else if let legacyID = Self.legacyMenuBarWindowID(from: decoder) {
            // Pre-provider releases stored one global selection; it belonged to Codex.
            menuBarQuotaWindowIDs = [StoredQuotaAccount.defaultCodexID: legacyID]
        } else {
            menuBarQuotaWindowIDs = defaults.menuBarQuotaWindowIDs
        }
        normalize()
    }
}
