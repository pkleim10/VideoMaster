import CoreGraphics
import Foundation

/// User preference for the size the single resizable player opens at when playback starts.
/// Part of the single-player redesign (see `Playback_Redesign_Plan_2026-06-30.md`): the player is
/// one resizable surface anchored top-right, from a compact (inspector-hero) footprint up to true
/// full-screen — not three discrete modes.
enum PlayerStartPreference: Codable, Equatable {
    /// Open at the minimum (inspector-hero) footprint.
    case compact
    /// Open directly in true (borderless, edge-to-edge) full-screen.
    case fullScreen
    /// Open at a specific in-window size.
    case specific(width: Double, height: Double)
}
