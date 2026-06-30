import Foundation

/// User preference for the size the single resizable player opens at when playback starts.
/// Part of the single-player redesign (see `Playback_Redesign_Plan_2026-06-30.md`): the player is
/// one resizable surface anchored top-right, from a compact (inspector-hero) footprint up to true
/// full-screen — not three discrete modes.
enum PlayerStartPreference: String, Codable, CaseIterable, Identifiable {
    /// Open at the minimum (inspector-hero / still-filmstrip) footprint.
    case compact
    /// Open directly in true (borderless, edge-to-edge) full-screen.
    case fullScreen
    /// Open at the last size the player was left at (the persisted `playerFloatingSize`).
    case lastSize

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: return "Compact (fit to inspector)"
        case .fullScreen: return "Full screen"
        case .lastSize: return "Last used size"
        }
    }
}
