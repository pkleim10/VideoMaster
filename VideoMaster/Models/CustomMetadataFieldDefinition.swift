import Foundation

/// How a custom metadata field is edited and stored (schema only; values UI comes later).
enum CustomMetadataValueType: CaseIterable, Identifiable, Sendable {
    /// Single-line text.
    case string
    /// Multiline text (“text box”).
    case text
    /// Numeric values (integers and floating-point).
    case number
    /// Calendar date (no time-of-day).
    case date
    /// Date and time of day.
    case dateTime

    var id: String { rawValue }

    /// Persisted key in UserDefaults / future DB.
    var rawValue: String {
        switch self {
        case .string: return "string"
        case .text: return "text"
        case .number: return "number"
        case .date: return "date"
        case .dateTime: return "dateTime"
        }
    }

    var displayName: String {
        switch self {
        case .string: return "String"
        case .text: return "Text"
        case .number: return "Number"
        case .date: return "Date"
        case .dateTime: return "Date & Time"
        }
    }

    static var allCases: [CustomMetadataValueType] {
        [.string, .text, .number, .date, .dateTime]
    }
}

extension CustomMetadataValueType: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        switch s {
        case "string": self = .string
        case "text": self = .text
        case "number": self = .number
        case "integer", "fp": self = .number // legacy split types → unified Number
        case "date": self = .date
        case "dateTime": self = .dateTime
        default:
            throw DecodingError.dataCorruptedError(
                in: c,
                debugDescription: "Unknown CustomMetadataValueType: \(s)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// One row in Settings → Custom Metadata (field name + type). Stable `id` for future DB values.
struct CustomMetadataFieldDefinition: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var valueType: CustomMetadataValueType

    init(id: UUID = UUID(), name: String, valueType: CustomMetadataValueType) {
        self.id = id
        self.name = name
        self.valueType = valueType
    }
}
