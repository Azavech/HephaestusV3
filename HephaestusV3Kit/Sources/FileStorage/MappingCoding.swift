import Foundation
import Yams

/// Reads the keys of one mapping with the rules of docs/data.md › Keys and values: a key that is
/// absent or `null` takes its default, a required key that is absent or `null` makes the file invalid,
/// and the keys a type doesn't know are kept, in their order.
public struct MappingReader {
    private let container: KeyedDecodingContainer<AnyKey>
    private let resolver: NodeResolver?

    public init(_ decoder: any Decoder) throws {
        container = try decoder.container(keyedBy: AnyKey.self)
        resolver = decoder.userInfo[YAMLCoding.nodeResolverKey] as? NodeResolver
    }

    public var codingPath: [any CodingKey] { container.codingPath }

    public func contains(_ key: String) -> Bool {
        container.contains(AnyKey(key))
    }

    public func isAbsentOrNull(_ key: String) throws -> Bool {
        guard contains(key) else { return true }
        return try container.decodeNil(forKey: AnyKey(key))
    }

    public func required<T: Decodable>(_ key: String, _ type: T.Type = T.self) throws -> T {
        if try isAbsentOrNull(key) {
            throw DecodingError.keyNotFound(
                AnyKey(key), DecodingError.Context(codingPath: codingPath, debugDescription: "The required key \"\(key)\" is missing or null.")
            )
        }
        return try container.decode(T.self, forKey: AnyKey(key))
    }

    public func optional<T: Decodable>(_ key: String, _ type: T.Type = T.self) throws -> T? {
        if try isAbsentOrNull(key) { return nil }
        return try container.decode(T.self, forKey: AnyKey(key))
    }

    public func value<T: Decodable>(_ key: String, default defaultValue: @autoclosure () -> T) throws -> T {
        try optional(key, T.self) ?? defaultValue()
    }

    /// A required date (docs/data.md › Dates), its fraction of a second dropped.
    public func requiredDate(_ key: String) throws -> Date {
        try date(from: required(key, String.self), key: key)
    }

    public func optionalDate(_ key: String) throws -> Date? {
        guard let text = try optional(key, String.self) else { return nil }
        return try date(from: text, key: key)
    }

    /// `schema`: absent is 1; any other value than 1 makes the file invalid.
    public func schema() throws -> Int {
        let schema = try value("schema", default: 1)
        guard schema == 1 else {
            throw invalid("schema", schema > 1 ? "schema \(schema) was written by a newer version" : "schema must be 1, not \(schema)")
        }
        return schema
    }

    /// The value of a key as it was read, `null` included, or nil when the mapping doesn't have it.
    public func raw(_ key: String) throws -> RawYAML? {
        guard contains(key) else { return nil }
        return try container.decode(RawYAML.self, forKey: AnyKey(key))
    }

    /// Every key of the mapping that isn't in `known`, with its value as read, in the file's order.
    public func unknownKeys(known: Set<String>) throws -> YAMLMapping {
        if let resolver, case .mapping(let mapping)? = resolver.node(at: codingPath) {
            return YAMLMapping(mapping.compactMap { key, value in
                guard let name = key.string, !known.contains(name) else { return nil }
                return YAMLMapping.Entry(key: name, value: RawYAML(value))
            })
        }
        let keys = container.allKeys.filter { !known.contains($0.stringValue) }.sorted { $0.stringValue < $1.stringValue }
        return YAMLMapping(try keys.map { YAMLMapping.Entry(key: $0.stringValue, value: try container.decode(RawYAML.self, forKey: $0)) })
    }

    /// The error of a value that breaks a read rule, naming the key.
    public func invalid(_ key: String, _ message: String) -> DecodingError {
        DecodingError.dataCorrupted(DecodingError.Context(codingPath: codingPath + [AnyKey(key)], debugDescription: message))
    }

    /// Checks a value with a rule; `what` names the value's kind in the error.
    public func check(_ key: String, _ value: String, _ isValid: (String) -> Bool, _ what: String) throws {
        guard isValid(value) else { throw invalid(key, "\"\(value)\" is not a valid \(what)") }
    }

    private func date(from text: String, key: String) throws -> Date {
        guard let date = ISODate.date(from: text) else {
            throw invalid(key, "\"\(text)\" is not a date of the form 2026-10-31T14:03:00Z")
        }
        return date
    }
}

/// Writes the keys of one mapping with the rules of docs/data.md › Keys and values: the known keys in
/// the order of the type's table, then the unknown keys in the order they were read.
public struct MappingWriter {
    private var container: KeyedEncodingContainer<AnyKey>

    public init(_ encoder: any Encoder) {
        container = encoder.container(keyedBy: AnyKey.self)
    }

    public mutating func encode<T: Encodable>(_ value: T, _ key: String) throws {
        try container.encode(value, forKey: AnyKey(key))
    }

    /// Writes `null` for an absent value.
    public mutating func encodeOptional<T: Encodable>(_ value: T?, _ key: String) throws {
        if let value {
            try container.encode(value, forKey: AnyKey(key))
        } else {
            try container.encodeNil(forKey: AnyKey(key))
        }
    }

    /// Leaves the key out for an absent value.
    public mutating func encodeIfPresent<T: Encodable>(_ value: T?, _ key: String) throws {
        if let value {
            try container.encode(value, forKey: AnyKey(key))
        }
    }

    /// An unquoted timestamp in UTC with whole seconds, such as `2026-10-31T14:03:00Z`.
    public mutating func encodeDate(_ date: Date, _ key: String) throws {
        try container.encode(ISODate.scalar(date), forKey: AnyKey(key))
    }

    public mutating func encodeOptionalDate(_ date: Date?, _ key: String) throws {
        if let date {
            try encodeDate(date, key)
        } else {
            try container.encodeNil(forKey: AnyKey(key))
        }
    }

    /// The unknown keys, in their order, after the known keys; a key that `known` holds is skipped.
    public mutating func encodeUnknownKeys(_ keys: YAMLMapping, known: Set<String>) throws {
        for entry in keys where !known.contains(entry.key) {
            try container.encode(entry.value, forKey: AnyKey(entry.key))
        }
    }
}
