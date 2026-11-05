import Foundation

/// How the app decides between saving quota for the official reset and spending
/// it as fully as possible before that reset arrives.
nonisolated enum ResetStrategy: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Keep the quota until the official reset refills it, and spend a banked
    /// reset only when the current window cannot survive that long.
    case bridge

    /// Burn quota as fully as possible: spend a banked reset as soon as a window
    /// runs dry so work continues, and never let one expire unused.
    case maximize

    var id: String { rawValue }
}
