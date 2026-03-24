import Foundation

/// Which optional list view columns are visible (Name is always shown).
struct ListColumnPreferences: Codable, Equatable, Sendable {
    /// Standard columns other than Name; matches `TableColumn.customizationID` in list view.
    static let optionalStandardColumnIDs: Set<String> = [
        "duration", "resolution", "size", "rating", "dateAdded",
        "playCount", "created", "lastPlayed",
    ]

    /// Subset of `optionalStandardColumnIDs`; empty on decode is treated as “all visible”.
    var visibleStandardColumnIDs: Set<String>
    /// Custom metadata field definition UUIDs to show as columns.
    var visibleCustomFieldIDs: Set<UUID>

    static let `default` = ListColumnPreferences(
        visibleStandardColumnIDs: optionalStandardColumnIDs,
        visibleCustomFieldIDs: []
    )

    init(visibleStandardColumnIDs: Set<String>, visibleCustomFieldIDs: Set<UUID>) {
        self.visibleStandardColumnIDs = visibleStandardColumnIDs
        self.visibleCustomFieldIDs = visibleCustomFieldIDs
    }

    private enum CodingKeys: String, CodingKey {
        case visibleStandardColumnIDs
        case visibleCustomFieldIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let standard = try c.decodeIfPresent(Set<String>.self, forKey: .visibleStandardColumnIDs) ?? []
        let custom = try c.decodeIfPresent(Set<UUID>.self, forKey: .visibleCustomFieldIDs) ?? []
        visibleStandardColumnIDs = standard.intersection(Self.optionalStandardColumnIDs)
        visibleCustomFieldIDs = custom
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(visibleStandardColumnIDs, forKey: .visibleStandardColumnIDs)
        try c.encode(visibleCustomFieldIDs, forKey: .visibleCustomFieldIDs)
    }

    func sanitized(knownCustomFieldIds: Set<UUID>) -> ListColumnPreferences {
        var copy = self
        copy.visibleStandardColumnIDs = visibleStandardColumnIDs.intersection(Self.optionalStandardColumnIDs)
        copy.visibleCustomFieldIDs = visibleCustomFieldIDs.intersection(knownCustomFieldIds)
        return copy
    }
}

/// Short display strings for custom metadata in the list table.
enum ListCustomMetadataCellFormatter {
    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private static let isoDateOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let isoDateTimeFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoDateTime: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func display(raw: String, valueType: CustomMetadataValueType) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "—" }
        switch valueType {
        case .string, .text, .number:
            return t.replacingOccurrences(of: "\n", with: " ")
        case .date:
            if let d = isoDateOnly.date(from: t) {
                return dateOnly.string(from: d)
            }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withFullDate]
            if let d = iso.date(from: t) {
                return dateOnly.string(from: d)
            }
            return t
        case .dateTime:
            if let d = isoDateTimeFrac.date(from: t) ?? isoDateTime.date(from: t) {
                return dateTime.string(from: d)
            }
            return t
        }
    }
}
