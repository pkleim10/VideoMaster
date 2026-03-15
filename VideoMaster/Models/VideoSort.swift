import Foundation

enum VideoSort: String, CaseIterable, Identifiable {
    case name
    case dateAdded
    case duration
    case fileSize
    case rating
    case resolution

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name: return "Name"
        case .dateAdded: return "Date Added"
        case .duration: return "Duration"
        case .fileSize: return "File Size"
        case .rating: return "Rating"
        case .resolution: return "Resolution"
        }
    }

    func comparators(ascending: Bool) -> [KeyPathComparator<Video>] {
        let order: SortOrder = ascending ? .forward : .reverse
        switch self {
        case .name: return [KeyPathComparator(\Video.fileName, order: order)]
        case .duration: return [KeyPathComparator(\Video.sortableDuration, order: order)]
        case .fileSize: return [KeyPathComparator(\Video.fileSize, order: order)]
        case .rating: return [KeyPathComparator(\Video.rating, order: order)]
        case .resolution: return [KeyPathComparator(\Video.sortablePixelCount, order: order)]
        case .dateAdded: return [KeyPathComparator(\Video.dateAdded, order: order)]
        }
    }

    static func from(keyPath: PartialKeyPath<Video>) -> VideoSort {
        if keyPath == \Video.fileName as PartialKeyPath<Video> { return .name }
        if keyPath == \Video.sortableDuration as PartialKeyPath<Video> { return .duration }
        if keyPath == \Video.fileSize as PartialKeyPath<Video> { return .fileSize }
        if keyPath == \Video.rating as PartialKeyPath<Video> { return .rating }
        if keyPath == \Video.sortablePixelCount as PartialKeyPath<Video> { return .resolution }
        if keyPath == \Video.dateAdded as PartialKeyPath<Video> { return .dateAdded }
        return .dateAdded
    }
}

enum ViewMode: String, CaseIterable {
    case grid, list
}

enum SidebarFilter: Hashable {
    case all
    case recentlyAdded
    case recentlyPlayed
    case topRated
    case rating(Int)
    case tag(Tag)
    case collection(VideoCollection)
}

struct LibraryCounts {
    var all: Int = 0
    var recentlyAdded: Int = 0
    var recentlyPlayed: Int = 0
    var topRated: Int = 0
    var byRating: [Int: Int] = [:]
}
