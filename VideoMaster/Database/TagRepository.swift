import Foundation
import GRDB

struct TagRepository {
    let dbPool: DatabasePool

    func fetchAll() async throws -> [Tag] {
        try await dbPool.read { db in
            try Tag.order(Column("name").asc).fetchAll(db)
        }
    }

    func fetchTags(for videoId: Int64) async throws -> [Tag] {
        try await dbPool.read { db in
            let sql = """
                SELECT tag.* FROM tag
                JOIN video_tag ON video_tag.tagId = tag.id
                WHERE video_tag.videoId = ?
                ORDER BY tag.name ASC
                """
            return try Tag.fetchAll(db, sql: sql, arguments: [videoId])
        }
    }

    func findOrCreate(name: String) async throws -> Tag {
        try await dbPool.write { db in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = try Tag.filter(Column("name").collating(.nocase) == trimmed).fetchOne(db) {
                return existing
            }
            var tag = Tag(name: trimmed)
            try tag.insert(db)
            return tag
        }
    }

    func addTag(_ tagId: Int64, to videoId: Int64) async throws {
        try await dbPool.write { db in
            let videoTag = VideoTag(videoId: videoId, tagId: tagId)
            try videoTag.insert(db, onConflict: .ignore)
        }
    }

    func removeTag(_ tagId: Int64, from videoId: Int64) async throws {
        _ = try await dbPool.write { db in
            try VideoTag
                .filter(Column("videoId") == videoId && Column("tagId") == tagId)
                .deleteAll(db)
        }
    }

    func rename(_ tagId: Int64, to newName: String) async throws {
        _ = try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE tag SET name = ? WHERE id = ?",
                arguments: [newName.trimmingCharacters(in: .whitespacesAndNewlines), tagId]
            )
        }
    }

    func delete(_ tagId: Int64) async throws {
        _ = try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM video_tag WHERE tagId = ?", arguments: [tagId])
            try db.execute(sql: "DELETE FROM tag WHERE id = ?", arguments: [tagId])
        }
    }

    func fetchAllVideoTags() async throws -> [Int64: [Tag]] {
        try await dbPool.read { db in
            let sql = """
                SELECT tag.*, video_tag.videoId
                FROM tag
                JOIN video_tag ON video_tag.tagId = tag.id
                ORDER BY tag.name ASC
                """
            var result: [Int64: [Tag]] = [:]
            let rows = try Row.fetchAll(db, sql: sql)
            for row in rows {
                let videoId: Int64 = row["videoId"]
                let tag = Tag(id: row["id"], name: row["name"])
                result[videoId, default: []].append(tag)
            }
            return result
        }
    }
}
