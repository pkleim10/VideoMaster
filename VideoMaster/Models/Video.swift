import Foundation
import GRDB

struct Video: Codable, Equatable, Hashable, Identifiable {
    var databaseId: Int64?
    var filePath: String
    var fileName: String
    var fileSize: Int64
    var duration: Double?
    var width: Int?
    var height: Int?
    var codec: String?
    var frameRate: Double?
    var creationDate: Date?
    var dateAdded: Date
    var rating: Int
    var thumbnailPath: String?
    var lastPlayed: Date?
    var playCount: Int

    var id: String { filePath }

    private enum CodingKeys: String, CodingKey {
        case databaseId = "id"
        case filePath, fileName, fileSize, duration, width, height
        case codec, frameRate, creationDate, dateAdded, rating
        case thumbnailPath, lastPlayed, playCount
    }
}

extension Video {
    var url: URL { URL(fileURLWithPath: filePath) }

    var sortableDuration: Double { duration ?? -1 }
    /// Total pixels; used as a secondary key when sorting by resolution (height is primary).
    var sortablePixelCount: Int { (width ?? 0) * (height ?? 0) }
    /// Vertical line count for resolution sort — matches how people describe “1080p”, etc.
    var sortableResolutionHeight: Int { height ?? 0 }

    var resolution: String? {
        guard let w = width, let h = height else { return nil }
        return "\(w) × \(h)"
    }

    var resolutionLabel: String? {
        guard let h = height else { return nil }
        switch h {
        case 0..<480: return "SD"
        case 480..<720: return "480p"
        case 720..<1080: return "720p"
        case 1080..<1440: return "1080p"
        case 1440..<2160: return "1440p"
        case 2160..<4320: return "4K"
        default: return "8K+"
        }
    }

    var formattedDuration: String? {
        guard let d = duration else { return nil }
        return d.formattedDuration
    }

    var formattedFileSize: String {
        fileSize.formattedFileSize
    }
}

extension Video: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "video"

    static let videoTags = hasMany(VideoTag.self, using: ForeignKey(["videoId"]))
    static let tags = hasMany(Tag.self, through: videoTags, using: VideoTag.tag)

    mutating func didInsert(_ inserted: InsertionSuccess) {
        databaseId = inserted.rowID
    }
}
