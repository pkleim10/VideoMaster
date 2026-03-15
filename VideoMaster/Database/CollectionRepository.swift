import Foundation
import GRDB

struct CollectionRepository {
    let dbPool: DatabasePool

    // MARK: - Collections CRUD

    func fetchAll() async throws -> [VideoCollection] {
        try await dbPool.read { db in
            try VideoCollection.order(Column("name").collating(.caseInsensitiveCompare).asc).fetchAll(db)
        }
    }

    @discardableResult
    func insert(_ collection: VideoCollection) async throws -> VideoCollection {
        try await dbPool.write { db in
            var c = collection
            try c.insert(db)
            return c
        }
    }

    func update(_ collection: VideoCollection) async throws {
        try await dbPool.write { db in
            try collection.update(db)
        }
    }

    func delete(_ collection: VideoCollection) async throws {
        _ = try await dbPool.write { db in
            try collection.delete(db)
        }
    }

    // MARK: - Rules CRUD

    func fetchRules(for collectionId: Int64) async throws -> [CollectionRule] {
        try await dbPool.read { db in
            try CollectionRule
                .filter(Column("collectionId") == collectionId)
                .fetchAll(db)
        }
    }

    func replaceRules(for collectionId: Int64, with rules: [CollectionRule]) async throws {
        try await dbPool.write { db in
            try CollectionRule
                .filter(Column("collectionId") == collectionId)
                .deleteAll(db)

            for rule in rules {
                var r = rule
                r.collectionId = collectionId
                try r.insert(db)
            }
        }
    }

    func fetchAllRulesGrouped() async throws -> [Int64: [CollectionRule]] {
        try await dbPool.read { db in
            let rules = try CollectionRule.fetchAll(db)
            return Dictionary(grouping: rules, by: \.collectionId)
        }
    }

    // MARK: - Matching

    func filterVideos(
        _ videos: [Video],
        for collection: VideoCollection,
        tagsByVideoId: [Int64: [Tag]]
    ) async throws -> [Video] {
        guard let collectionId = collection.id else { return [] }
        let rules = try await fetchRules(for: collectionId)
        if rules.isEmpty { return [] }
        return videos.filter { video in
            matchesAllRules(video: video, rules: rules, tags: tagsByVideoId[video.databaseId ?? -1] ?? [])
        }
    }
}

// MARK: - Rule Matching Engine

extension CollectionRepository {
    func matchesAllRules(video: Video, rules: [CollectionRule], tags: [Tag]) -> Bool {
        rules.allSatisfy { rule in matchesRule(video: video, rule: rule, tags: tags) }
    }

    private func matchesRule(video: Video, rule: CollectionRule, tags: [Tag]) -> Bool {
        let attribute = rule.attribute
        let comparison = rule.comparison
        let value = rule.value

        switch attribute {
        case .name:
            return compareString(video.fileName, comparison, value)
        case .fileExtension:
            let ext = video.url.pathExtension
            return compareString(ext, comparison, value)
        case .path:
            return compareString(video.filePath, comparison, value)
        case .parentFolder:
            let parent = video.url.deletingLastPathComponent().lastPathComponent
            return compareString(parent, comparison, value)
        case .volume:
            let components = video.url.pathComponents
            let vol = components.count >= 3 && components[0] == "/" && components[1] == "Volumes"
                ? components[2]
                : "/"
            return compareString(vol, comparison, value)
        case .fileSize:
            let mb = Double(value) ?? 0
            let bytes = Int64(mb * 1_000_000)
            return compareNumeric(video.fileSize, comparison, bytes)
        case .duration:
            guard let dur = video.duration else { return false }
            let seconds = Double(value) ?? 0
            return compareNumeric(dur, comparison, seconds)
        case .height:
            guard let h = video.height else { return false }
            let val = Int(value) ?? 0
            return compareNumeric(h, comparison, val)
        case .width:
            guard let w = video.width else { return false }
            let val = Int(value) ?? 0
            return compareNumeric(w, comparison, val)
        case .codec:
            return compareString(video.codec ?? "", comparison, value)
        case .dateImported:
            return compareDate(video.dateAdded, comparison, value)
        case .dateCreated:
            guard let date = video.creationDate else { return false }
            return compareDate(date, comparison, value)
        case .playCount:
            let val = Int(value) ?? 0
            return compareNumeric(video.playCount, comparison, val)
        case .rating:
            let val = Int(value) ?? 0
            return compareNumeric(video.rating, comparison, val)
        case .tag:
            let tagNames = tags.map { $0.name }
            return tagNames.contains { compareString($0, comparison, value) }
        }
    }

    private func compareString(_ lhs: String, _ op: RuleComparison, _ rhs: String) -> Bool {
        let l = lhs.lowercased()
        let r = rhs.lowercased()
        switch op {
        case .equals: return l == r
        case .notEquals: return l != r
        case .contains: return l.contains(r)
        case .startsWith: return l.hasPrefix(r)
        case .endsWith: return l.hasSuffix(r)
        case .matches:
            return (try? Regex(rhs, as: Substring.self)).map { l.contains($0) } ?? false
        default: return false
        }
    }

    private func compareNumeric<T: Comparable>(_ lhs: T, _ op: RuleComparison, _ rhs: T) -> Bool {
        switch op {
        case .equals: return lhs == rhs
        case .notEquals: return lhs != rhs
        case .lessThan: return lhs < rhs
        case .greaterThan: return lhs > rhs
        case .lessThanOrEqual: return lhs <= rhs
        case .greaterThanOrEqual: return lhs >= rhs
        default: return false
        }
    }

    private func compareDate(_ lhs: Date, _ op: RuleComparison, _ dateString: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        guard let rhs = formatter.date(from: dateString) else { return false }
        let lhsDay = Calendar.current.startOfDay(for: lhs)
        let rhsDay = Calendar.current.startOfDay(for: rhs)
        switch op {
        case .equals: return lhsDay == rhsDay
        case .lessThan: return lhsDay < rhsDay
        case .greaterThan: return lhsDay > rhsDay
        default: return false
        }
    }
}
