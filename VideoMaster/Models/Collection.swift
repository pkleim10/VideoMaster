import Foundation
import GRDB

struct VideoCollection: Codable, Identifiable, Equatable, Hashable {
    var id: Int64?
    var name: String
    var dateCreated: Date

    private enum CodingKeys: String, CodingKey {
        case id, name, dateCreated
    }
}

extension VideoCollection: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "collection"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Collection Rule

struct CollectionRule: Codable, Identifiable, Equatable, Hashable {
    var id: Int64?
    var collectionId: Int64
    var attribute: RuleAttribute
    var comparison: RuleComparison
    var value: String

    private enum CodingKeys: String, CodingKey {
        case id, collectionId, attribute, comparison, value
    }
}

extension CollectionRule: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "collection_rule"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Rule Attribute

enum RuleAttribute: String, Codable, CaseIterable, Identifiable {
    case name
    case fileExtension
    case path
    case parentFolder
    case volume
    case fileSize
    case duration
    case height
    case width
    case codec
    case dateImported
    case dateCreated
    case playCount
    case rating
    case tag

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "Name"
        case .fileExtension: "Extension"
        case .path: "Path"
        case .parentFolder: "Parent Folder"
        case .volume: "Volume"
        case .fileSize: "File Size"
        case .duration: "Duration"
        case .height: "Height"
        case .width: "Width"
        case .codec: "Video Codec"
        case .dateImported: "Date Imported"
        case .dateCreated: "Date Created"
        case .playCount: "Play Count"
        case .rating: "Rating"
        case .tag: "Tag"
        }
    }

    var supportedComparisons: [RuleComparison] {
        switch self {
        case .name, .fileExtension, .path, .parentFolder, .volume, .codec, .tag:
            return [.equals, .notEquals, .contains, .startsWith, .endsWith, .matches]
        case .fileSize, .duration, .height, .width, .playCount, .rating:
            return [.equals, .notEquals, .lessThan, .greaterThan, .lessThanOrEqual, .greaterThanOrEqual]
        case .dateImported, .dateCreated:
            return [.equals, .lessThan, .greaterThan]
        }
    }

    var isNumeric: Bool {
        switch self {
        case .fileSize, .duration, .height, .width, .playCount, .rating:
            return true
        default:
            return false
        }
    }

    var valuePlaceholder: String {
        switch self {
        case .name: "File name"
        case .fileExtension: "mp4, mkv, etc."
        case .path: "/path/to/folder"
        case .parentFolder: "Folder name"
        case .volume: "Volume name"
        case .fileSize: "Size in MB"
        case .duration: "Duration in seconds"
        case .height: "Pixels"
        case .width: "Pixels"
        case .codec: "h264, hevc, etc."
        case .dateImported: "YYYY-MM-DD"
        case .dateCreated: "YYYY-MM-DD"
        case .playCount: "Count"
        case .rating: "1-5"
        case .tag: "Tag name"
        }
    }
}

// MARK: - Rule Comparison

enum RuleComparison: String, Codable, CaseIterable, Identifiable {
    case equals
    case notEquals
    case contains
    case startsWith
    case endsWith
    case matches
    case lessThan
    case greaterThan
    case lessThanOrEqual
    case greaterThanOrEqual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .equals: "equals"
        case .notEquals: "does not equal"
        case .contains: "contains"
        case .startsWith: "starts with"
        case .endsWith: "ends with"
        case .matches: "matches"
        case .lessThan: "is less than"
        case .greaterThan: "is greater than"
        case .lessThanOrEqual: "is at most"
        case .greaterThanOrEqual: "is at least"
        }
    }
}
