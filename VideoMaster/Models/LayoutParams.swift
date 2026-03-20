import Foundation
import SwiftUI

/// Layout parameters for one mode (browsing or playback). Persisted per mode.
/// Grid and list view each persist their own **content** and **detail** column widths (middle vs right split).
struct LayoutParams: Equatable {
    var sidebarWidth: Double
    var contentWidthGrid: Double
    var detailWidthGrid: Double
    var contentWidthList: Double
    var detailWidthList: Double
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

    func contentColumnWidth(for mode: ViewMode) -> Double {
        switch mode {
        case .grid: return contentWidthGrid
        case .list: return contentWidthList
        }
    }

    func detailColumnWidth(for mode: ViewMode) -> Double {
        switch mode {
        case .grid: return detailWidthGrid
        case .list: return detailWidthList
        }
    }

    static func browsingDefaults() -> LayoutParams {
        LayoutParams(
            sidebarWidth: defaultSidebarWidth,
            contentWidthGrid: defaultContentWidth,
            detailWidthGrid: defaultDetailWidth,
            contentWidthList: defaultContentWidth,
            detailWidthList: defaultDetailWidth,
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
            contentWidthGrid: playback.contentWidthGrid,
            detailWidthGrid: playback.detailWidthGrid,
            contentWidthList: playback.contentWidthList,
            detailWidthList: playback.detailWidthList,
            detailVideoHeight: playback.detailVideoHeight,
            sidebarExpanded: playback.sidebarExpanded,
            columnCustomizationData: playback.columnCustomizationData,
            viewMode: playback.viewMode,
            gridSize: playback.gridSize
        )
    }
}

extension LayoutParams: Codable {
    private enum CodingKeys: String, CodingKey {
        case sidebarWidth
        case contentWidthGrid = "contentWidth"
        case detailWidthGrid = "detailWidth"
        case contentWidthList
        case detailWidthList
        case detailVideoHeight
        case sidebarExpanded
        case columnCustomizationData
        case viewMode
        case gridSize
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sidebarWidth = try c.decode(Double.self, forKey: .sidebarWidth)
        contentWidthGrid = try c.decode(Double.self, forKey: .contentWidthGrid)
        detailWidthGrid = try c.decode(Double.self, forKey: .detailWidthGrid)
        let listC = try c.decodeIfPresent(Double.self, forKey: .contentWidthList)
        let listD = try c.decodeIfPresent(Double.self, forKey: .detailWidthList)
        contentWidthList = listC ?? contentWidthGrid
        detailWidthList = listD ?? detailWidthGrid
        detailVideoHeight = try c.decode(Double.self, forKey: .detailVideoHeight)
        sidebarExpanded = try c.decode([String: Bool].self, forKey: .sidebarExpanded)
        columnCustomizationData = try c.decodeIfPresent(Data.self, forKey: .columnCustomizationData)
        viewMode = try c.decode(String.self, forKey: .viewMode)
        gridSize = try c.decode(String.self, forKey: .gridSize)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sidebarWidth, forKey: .sidebarWidth)
        try c.encode(contentWidthGrid, forKey: .contentWidthGrid)
        try c.encode(detailWidthGrid, forKey: .detailWidthGrid)
        try c.encode(contentWidthList, forKey: .contentWidthList)
        try c.encode(detailWidthList, forKey: .detailWidthList)
        try c.encode(detailVideoHeight, forKey: .detailVideoHeight)
        try c.encode(sidebarExpanded, forKey: .sidebarExpanded)
        try c.encodeIfPresent(columnCustomizationData, forKey: .columnCustomizationData)
        try c.encode(viewMode, forKey: .viewMode)
        try c.encode(gridSize, forKey: .gridSize)
    }
}
