import Foundation
import GRDB

struct DataSourceRepository {
    let dbPool: DatabasePool

    func fetchAll() async throws -> [DataSource] {
        try await dbPool.read { db in
            try DataSource.order(Column("name").asc).fetchAll(db)
        }
    }

    @discardableResult
    func insert(_ dataSource: DataSource) async throws -> DataSource {
        try await dbPool.write { db in
            var ds = dataSource
            try ds.insert(db)
            return ds
        }
    }

    func delete(_ dataSource: DataSource) async throws {
        _ = try await dbPool.write { db in
            try dataSource.delete(db)
        }
    }

    func exists(folderPath: String) async throws -> Bool {
        try await dbPool.read { db in
            try DataSource.filter(Column("folderPath") == folderPath).fetchCount(db) > 0
        }
    }
}
