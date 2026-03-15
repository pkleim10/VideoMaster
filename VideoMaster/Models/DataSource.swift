import Foundation
import GRDB

struct DataSource: Codable, Identifiable, Equatable, Hashable {
    var id: Int64?
    var folderPath: String
    var name: String
    var dateAdded: Date

    var url: URL { URL(fileURLWithPath: folderPath) }
}

extension DataSource: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "data_source"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
