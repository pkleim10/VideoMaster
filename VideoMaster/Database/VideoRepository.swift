import Foundation
import GRDB

struct VideoRepository {
    let dbPool: DatabasePool

    func fetchAll() async throws -> [Video] {
        try await dbPool.read { db in
            try Video.order(Column("dateAdded").desc).fetchAll(db)
        }
    }

    func search(_ query: String) async throws -> [Video] {
        try await dbPool.read { db in
            if query.isEmpty { return try Video.fetchAll(db) }
            let terms = query
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !terms.isEmpty else { return try Video.fetchAll(db) }
            // Contains (*term*), AND logic, case-insensitive — "coop" matches "Cooper"/"acoop", "bear coop" matches "Dale Cooper fights a bear"
            let conditions = terms.map { _ in
                "LOWER(fileName) LIKE ? ESCAPE '\\'"
            }.joined(separator: " AND ")
            let args = terms.map { "%\(Self.escapeLike($0))%".lowercased() }
            let sql = """
                SELECT * FROM video
                WHERE \(conditions)
                ORDER BY dateAdded DESC
                """
            return try Video.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    /// Escapes % _ \ for use in SQLite LIKE patterns with ESCAPE '\\'
    private static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    func fetchByMinRating(_ rating: Int) async throws -> [Video] {
        try await dbPool.read { db in
            try Video
                .filter(Column("rating") >= rating)
                .order(Column("rating").desc)
                .fetchAll(db)
        }
    }

    @discardableResult
    func insert(_ video: Video) async throws -> Video {
        try await dbPool.write { db in
            var v = video
            try v.insert(db)
            return v
        }
    }

    func update(_ video: Video) async throws {
        try await dbPool.write { db in
            try video.update(db)
        }
    }

    func delete(_ video: Video) async throws {
        _ = try await dbPool.write { db in
            try video.delete(db)
        }
    }

    func updateRating(videoId: Int64, rating: Int) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE video SET rating = ? WHERE id = ?",
                arguments: [rating, videoId]
            )
        }
    }

    func updateRating(videoIds: [Int64], rating: Int) async throws {
        try await dbPool.write { db in
            for id in videoIds {
                try db.execute(
                    sql: "UPDATE video SET rating = ? WHERE id = ?",
                    arguments: [rating, id]
                )
            }
        }
    }

    func updateThumbnailPath(videoId: Int64, path: String) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE video SET thumbnailPath = ? WHERE id = ?",
                arguments: [path, videoId]
            )
        }
    }

    func recordPlay(videoId: Int64) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE video SET lastPlayed = ?, playCount = playCount + 1 WHERE id = ?",
                arguments: [Date(), videoId]
            )
        }
    }

    func videoExists(filePath: String) async throws -> Bool {
        try await dbPool.read { db in
            try Video.filter(Column("filePath") == filePath).fetchCount(db) > 0
        }
    }

    func renameVideo(videoId: Int64, newFilePath: String, newFileName: String) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE video SET filePath = ?, fileName = ? WHERE id = ?",
                arguments: [newFilePath, newFileName, videoId]
            )
        }
    }

    func fetchAllFilePaths() async throws -> Set<String> {
        try await dbPool.read { db in
            let paths = try String.fetchAll(db, sql: "SELECT filePath FROM video")
            return Set(paths)
        }
    }
}
