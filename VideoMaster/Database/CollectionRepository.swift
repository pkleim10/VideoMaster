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
    /// A rule set compiled once into per-rule predicates. Rule values are parsed, comparison strings
    /// lowercased, and regexes compiled a single time here — the old per-video path re-did all of that on
    /// every one of ~12k calls (~90ms/rule). Build once per rule set, then evaluate per video.
    struct CompiledMatcher {
        fileprivate let mode: MatchMode
        fileprivate let predicates: [(Video, [Tag]) -> Bool]

        func matches(_ video: Video, tags: [Tag]) -> Bool {
            switch mode {
            case .all: return predicates.allSatisfy { $0(video, tags) }
            case .any: return predicates.contains { $0(video, tags) }
            }
        }
    }

    func compile(rules: [CollectionRule], mode: MatchMode) -> CompiledMatcher {
        CompiledMatcher(mode: mode, predicates: rules.map { Self.compileRule($0) })
    }

    // Back-compat single-video entry points (used outside the hot filter loops). They delegate to a one-off
    // compiled matcher so all rule evaluation shares one implementation.
    func matchesRules(video: Video, rules: [CollectionRule], tags: [Tag], mode: MatchMode) -> Bool {
        compile(rules: rules, mode: mode).matches(video, tags: tags)
    }

    func matchesAllRules(video: Video, rules: [CollectionRule], tags: [Tag]) -> Bool {
        compile(rules: rules, mode: .all).matches(video, tags: tags)
    }

    // MARK: - Rule compilation

    /// Precomputes everything that doesn't depend on the video (parsed numbers, lowercased strings, compiled
    /// regex / date) once, returning a closure evaluated per video.
    private static func compileRule(_ rule: CollectionRule) -> (Video, [Tag]) -> Bool {
        let cmp = rule.comparison
        let raw = rule.value

        switch rule.attribute {
        case .name:
            let m = StringMatcher(cmp, raw); return { v, _ in m.matches(v.fileName) }
        case .path:
            let m = StringMatcher(cmp, raw); return { v, _ in m.matches(v.filePath) }
        case .fileExtension:
            let m = StringMatcher(cmp, raw); return { v, _ in m.matches((v.filePath as NSString).pathExtension) }
        case .parentFolder:
            let m = StringMatcher(cmp, raw)
            return { v, _ in
                let parent = ((v.filePath as NSString).deletingLastPathComponent as NSString).lastPathComponent
                return m.matches(parent)
            }
        case .volume:
            let m = StringMatcher(cmp, raw)
            return { v, _ in
                let comps = (v.filePath as NSString).pathComponents
                let vol = comps.count >= 3 && comps[0] == "/" && comps[1] == "Volumes" ? comps[2] : "/"
                return m.matches(vol)
            }
        case .codec:
            let m = StringMatcher(cmp, raw); return { v, _ in m.matches(v.codec ?? "") }
        case .tag:
            let m = StringMatcher(cmp, raw); return { _, tags in tags.contains { m.matches($0.name) } }
        case .fileSize:
            let bytes = Int64((Double(raw) ?? 0) * 1_000_000)
            return { v, _ in compareNumeric(v.fileSize, cmp, bytes) }
        case .duration:
            let seconds = (Double(raw) ?? 0) * 60
            return { v, _ in
                guard let dur = v.duration else { return false }
                return compareNumeric(dur, cmp, seconds)
            }
        case .height:
            let val = Int(raw) ?? 0
            return { v, _ in
                guard let h = v.height else { return false }
                return compareNumeric(h, cmp, val)
            }
        case .width:
            let val = Int(raw) ?? 0
            return { v, _ in
                guard let w = v.width else { return false }
                return compareNumeric(w, cmp, val)
            }
        case .playCount:
            let val = Int(raw) ?? 0
            return { v, _ in compareNumeric(v.playCount, cmp, val) }
        case .rating:
            let val = Int(raw) ?? 0
            return { v, _ in compareNumeric(v.rating, cmp, val) }
        case .dateImported:
            let bound = parseRuleDay(raw)
            return { v, _ in compareDay(v.dateAdded, cmp, bound) }
        case .dateCreated:
            let bound = parseRuleDay(raw)
            return { v, _ in
                guard let date = v.creationDate else { return false }
                return compareDay(date, cmp, bound)
            }
        }
    }

    /// String comparison with the rule value lowercased / regex compiled up front (once per rule).
    private struct StringMatcher {
        let op: RuleComparison
        let rhsLower: String
        let regex: Regex<Substring>?

        init(_ op: RuleComparison, _ rhs: String) {
            self.op = op
            self.rhsLower = rhs.lowercased()
            self.regex = op == .matches ? (try? Regex(rhs, as: Substring.self)) : nil
        }

        func matches(_ lhs: String) -> Bool {
            let l = lhs.lowercased()
            switch op {
            case .equals: return l == rhsLower
            case .notEquals: return l != rhsLower
            case .contains: return l.contains(rhsLower)
            case .startsWith: return l.hasPrefix(rhsLower)
            case .endsWith: return l.hasSuffix(rhsLower)
            case .matches:
                guard let regex else { return false }
                return l.contains(regex)
            default: return false
            }
        }
    }

    private static func compareNumeric<T: Comparable>(_ lhs: T, _ op: RuleComparison, _ rhs: T) -> Bool {
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

    private static func parseRuleDay(_ dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        guard let date = formatter.date(from: dateString) else { return nil }
        return Calendar.current.startOfDay(for: date)
    }

    private static func compareDay(_ lhs: Date, _ op: RuleComparison, _ rhsDay: Date?) -> Bool {
        guard let rhsDay else { return false }
        let lhsDay = Calendar.current.startOfDay(for: lhs)
        switch op {
        case .equals: return lhsDay == rhsDay
        case .lessThan: return lhsDay < rhsDay
        case .greaterThan: return lhsDay > rhsDay
        default: return false
        }
    }
}
