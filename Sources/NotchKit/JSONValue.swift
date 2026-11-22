import Foundation

/// A JSON value, for building the state sent to Jev and walking it to redact strings.
public enum JSONValue: Equatable, Sendable, Codable, ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral,
    ExpressibleByArrayLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let bool = try? container.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? container.decode(Double.self) { self = .number(number) }
        else if let string = try? container.decode(String.self) { self = .string(string) }
        else if let array = try? container.decode([JSONValue].self) { self = .array(array) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Every string in it (keys excluded), transformed.
    public func mapStrings(_ transform: (String) -> String) -> JSONValue {
        switch self {
        case .string(let value): .string(transform(value))
        case .array(let values): .array(values.map { $0.mapStrings(transform) })
        case .object(let values): .object(values.mapValues { $0.mapStrings(transform) })
        default: self
        }
    }
}
