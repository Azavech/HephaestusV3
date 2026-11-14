import Foundation

/// Any JSON value: the arguments of a tool call, its result, the messages of the MCP server. Integers and
/// decimals stay apart, as JSON-RPC ids and the schemas' integers need.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Reading and writing

    /// Parses UTF-8 JSON; fragments (a bare string or number) are accepted. Throws when the bytes aren't
    /// JSON.
    public static func parse(_ data: Data) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONValue(foundation: object)
    }

    /// The value from a Foundation JSON object, numbers told apart by their storage.
    public init(foundation object: Any) {
        switch object {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                let value = number.doubleValue
                if value.rounded() == value, abs(value) < 9.2e18 {
                    self = .int(Int(value))
                } else {
                    self = .double(value)
                }
            } else {
                self = .int(number.intValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(foundation:)))
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues(JSONValue.init(foundation:)))
        default:
            self = .null
        }
    }

    /// The Foundation object `JSONSerialization` writes.
    public var foundation: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): NSNumber(value: value)
        case .int(let value): NSNumber(value: value)
        case .double(let value): NSNumber(value: value)
        case .string(let value): value
        case .array(let values): values.map(\.foundation)
        case .object(let values): values.mapValues(\.foundation)
        }
    }

    /// UTF-8 JSON without insignificant white space, keys sorted, slashes not escaped.
    public var data: Data {
        (try? JSONSerialization.data(withJSONObject: foundation, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]))
            ?? Data("null".utf8)
    }

    public var text: String { String(decoding: data, as: UTF8.self) }

    /// The value of an `Encodable`, through `JSONEncoder` with sorted keys.
    public init<T: Encodable>(encoding value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self = try JSONValue.parse(encoder.encode(value))
    }

    // MARK: Access

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    /// A decimal, or an integer as a decimal.
    public var doubleValue: Double? {
        switch self {
        case .double(let value): value
        case .int(let value): Double(value)
        default: nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// The value without its `null` members, at every depth; `null` elements of arrays stay.
    public var removingNullMembers: JSONValue {
        switch self {
        case .object(let values): .object(values.filter { $0.value != .null }.mapValues(\.removingNullMembers))
        case .array(let values): .array(values.map(\.removingNullMembers))
        default: self
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
