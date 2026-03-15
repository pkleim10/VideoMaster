import Foundation
import GRDB

final class DatabaseManager {
    let dbPool: DatabasePool

    init() throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dbDir = appSupport.appendingPathComponent("VideoMaster", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let dbPath = dbDir.appendingPathComponent("library.sqlite").path

        var config = Configuration()
        config.foreignKeysEnabled = true

        dbPool = try DatabasePool(path: dbPath, configuration: config)
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_createTables") { db in
            try db.create(table: "video") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("filePath", .text).notNull().unique()
                t.column("fileName", .text).notNull()
                t.column("fileSize", .integer).notNull()
                t.column("duration", .double)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("codec", .text)
                t.column("frameRate", .double)
                t.column("creationDate", .datetime)
                t.column("dateAdded", .datetime).notNull()
                t.column("rating", .integer).notNull().defaults(to: 0)
                t.column("thumbnailPath", .text)
                t.column("lastPlayed", .datetime)
                t.column("playCount", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "tag") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique().collate(.nocase)
            }

            try db.create(table: "video_tag") { t in
                t.column("videoId", .integer).notNull().references("video", onDelete: .cascade)
                t.column("tagId", .integer).notNull().references("tag", onDelete: .cascade)
                t.primaryKey(["videoId", "tagId"])
            }

            try db.create(virtualTable: "video_fts", using: FTS5()) { t in
                t.synchronize(withTable: "video")
                t.column("fileName")
            }

            try db.create(index: "idx_video_rating", on: "video", columns: ["rating"])
            try db.create(index: "idx_video_duration", on: "video", columns: ["duration"])
            try db.create(index: "idx_video_fileSize", on: "video", columns: ["fileSize"])
            try db.create(index: "idx_video_dateAdded", on: "video", columns: ["dateAdded"])
        }

        migrator.registerMigration("v2_dataSources") { db in
            try db.create(table: "data_source") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("folderPath", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("dateAdded", .datetime).notNull()
            }
        }

        migrator.registerMigration("v3_collections") { db in
            try db.create(table: "collection") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("dateCreated", .datetime).notNull()
            }

            try db.create(table: "collection_rule") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("collectionId", .integer).notNull()
                    .references("collection", onDelete: .cascade)
                t.column("attribute", .text).notNull()
                t.column("comparison", .text).notNull()
                t.column("value", .text).notNull()
            }

            try db.create(
                index: "idx_collection_rule_collectionId",
                on: "collection_rule",
                columns: ["collectionId"]
            )
        }

        try migrator.migrate(dbPool)
    }
}
