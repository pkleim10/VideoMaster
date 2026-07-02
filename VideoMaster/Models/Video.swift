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
    /// True when a sidecar `.srt` was detected at import or during the detail/playback flow.
    /// Surfaced as a subtle CC icon in list rows and a Subtitles attribute in the detail pane.
    var hasSubtitles: Bool = false

    var id: String { filePath }

    private enum CodingKeys: String, CodingKey {
        case databaseId = "id"
        case filePath, fileName, fileSize, duration, width, height
        case codec, frameRate, creationDate, dateAdded, rating
        case thumbnailPath, lastPlayed, playCount, hasSubtitles
    }
}

extension Video {
    var url: URL { URL(fileURLWithPath: filePath) }

    var sortableDuration: Double { duration ?? -1 }
    /// Total pixels; used as a secondary key when sorting by resolution (height is primary).
    var sortablePixelCount: Int { (width ?? 0) * (height ?? 0) }
    /// Vertical line count for resolution sort — matches how people describe “1080p”, etc.
    var sortableResolutionHeight: Int { height ?? 0 }
    /// For list sort when `creationDate` is missing (sort before any real date).
    var sortableCreationDate: TimeInterval { creationDate?.timeIntervalSinceReferenceDate ?? -1 }
    /// For list sort when `lastPlayed` is missing.
    var sortableLastPlayed: TimeInterval { lastPlayed?.timeIntervalSinceReferenceDate ?? -1 }
    /// For consistency with other sortable fields (0 is valid and should sort low).
    var sortablePlayCount: Int { playCount }

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

extension Video {
    // Sentinel keypaths used only to display sort-order carets on custom Table columns.
    // Actual sorting is done via customSortFieldId; these values are never compared.
    var customSortAnchor0:  Int { 0  }; var customSortAnchor1:  Int { 1  }
    var customSortAnchor2:  Int { 2  }; var customSortAnchor3:  Int { 3  }
    var customSortAnchor4:  Int { 4  }; var customSortAnchor5:  Int { 5  }
    var customSortAnchor6:  Int { 6  }; var customSortAnchor7:  Int { 7  }
    var customSortAnchor8:  Int { 8  }; var customSortAnchor9:  Int { 9  }
    var customSortAnchor10: Int { 10 }; var customSortAnchor11: Int { 11 }
    var customSortAnchor12: Int { 12 }; var customSortAnchor13: Int { 13 }
    var customSortAnchor14: Int { 14 }; var customSortAnchor15: Int { 15 }

    static func customSortKeyPath(slot: Int) -> KeyPath<Video, Int> {
        switch slot {
        case 0:  return \.customSortAnchor0;  case 1:  return \.customSortAnchor1
        case 2:  return \.customSortAnchor2;  case 3:  return \.customSortAnchor3
        case 4:  return \.customSortAnchor4;  case 5:  return \.customSortAnchor5
        case 6:  return \.customSortAnchor6;  case 7:  return \.customSortAnchor7
        case 8:  return \.customSortAnchor8;  case 9:  return \.customSortAnchor9
        case 10: return \.customSortAnchor10; case 11: return \.customSortAnchor11
        case 12: return \.customSortAnchor12; case 13: return \.customSortAnchor13
        case 14: return \.customSortAnchor14; default: return \.customSortAnchor15
        }
    }

    static func customSortSlot(from keyPath: PartialKeyPath<Video>?) -> Int? {
        switch keyPath {
        case \Video.customSortAnchor0:  return 0;  case \Video.customSortAnchor1:  return 1
        case \Video.customSortAnchor2:  return 2;  case \Video.customSortAnchor3:  return 3
        case \Video.customSortAnchor4:  return 4;  case \Video.customSortAnchor5:  return 5
        case \Video.customSortAnchor6:  return 6;  case \Video.customSortAnchor7:  return 7
        case \Video.customSortAnchor8:  return 8;  case \Video.customSortAnchor9:  return 9
        case \Video.customSortAnchor10: return 10; case \Video.customSortAnchor11: return 11
        case \Video.customSortAnchor12: return 12; case \Video.customSortAnchor13: return 13
        case \Video.customSortAnchor14: return 14; case \Video.customSortAnchor15: return 15
        default: return nil
        }
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
