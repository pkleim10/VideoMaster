import Foundation
import GRDB

struct VideoTag: Codable, Equatable {
    var videoId: Int64
    var tagId: Int64
}

extension VideoTag: FetchableRecord, PersistableRecord {
    static let databaseTableName = "video_tag"

    static let video = belongsTo(Video.self, using: ForeignKey(["videoId"]))
    static let tag = belongsTo(Tag.self, using: ForeignKey(["tagId"]))
}
