import Foundation
import GRDB

struct Tag: Codable, Identifiable, Equatable, Hashable {
    var id: Int64?
    var name: String

    var listId: String { "tag-\(id ?? 0)" }
}

extension Tag: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "tag"

    static let videoTags = hasMany(VideoTag.self, using: ForeignKey(["tagId"]))
    static let videos = hasMany(Video.self, through: videoTags, using: VideoTag.video)

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
