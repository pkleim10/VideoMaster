import Foundation
import SwiftUI

/// Layout parameters for one mode (browsing or playback). Persisted per mode.
struct LayoutParams: Codable, Equatable {
    var sidebarWidth: Double
    var contentWidth: Double
    var detailWidth: Double
    var detailVideoHeight: Double
    var sidebarExpanded: [String: Bool]
    var columnCustomizationData: Data?
    var viewMode: String
    var gridSize: String

    static let defaultSidebarWidth: Double = 220
    static let defaultContentWidth: Double = 480
    static let defaultDetailWidth: Double = 480
    static let defaultDetailVideoHeight: Double = 336
    static let defaultSidebarExpanded: [String: Bool] = [
        "library": true,
        "collections": true,
        "rating": true,
        "tags": true,
    ]

    static func browsingDefaults() -> LayoutParams {
        LayoutParams(
            sidebarWidth: defaultSidebarWidth,
            contentWidth: defaultContentWidth,
            detailWidth: defaultDetailWidth,
            detailVideoHeight: defaultDetailVideoHeight,
            sidebarExpanded: defaultSidebarExpanded,
            columnCustomizationData: nil,
            viewMode: ViewMode.grid.rawValue,
            gridSize: GridSize.medium.rawValue
        )
    }

    static func from(playback: LayoutParams) -> LayoutParams {
        LayoutParams(
            sidebarWidth: playback.sidebarWidth,
            contentWidth: playback.contentWidth,
            detailWidth: playback.detailWidth,
            detailVideoHeight: playback.detailVideoHeight,
            sidebarExpanded: playback.sidebarExpanded,
            columnCustomizationData: playback.columnCustomizationData,
            viewMode: playback.viewMode,
            gridSize: playback.gridSize
        )
    }
}
