import Foundation

/// A tool's input schema, with only the keywords the server checks (docs/mcp.md › Argument validation):
/// `type`, `properties`, `required`, `additionalProperties`, `items`, `enum`, `minimum`, `maximum` and
/// `description`.
public struct ToolSchema: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case object, array, string, boolean, integer
    }

    public var kind: Kind
    public var description: String?
    /// The properties of an object, in the order they are checked.
    public var properties: [(name: String, schema: ToolSchema)]
    public var required: [String]
    /// False refuses properties that `properties` doesn't name.
    public var allowsOtherProperties: Bool
    public var items: [ToolSchema]
    public var allowed: [String]?
    public var minimum: Int?
    public var maximum: Int?

    public static func == (lhs: ToolSchema, rhs: ToolSchema) -> Bool { lhs.json == rhs.json }
    public func hash(into hasher: inout Hasher) { hasher.combine(json) }

    private init(kind: Kind, description: String?) {
        self.kind = kind
        self.description = description
        properties = []
        required = []
        allowsOtherProperties = false
        items = []
    }

    public static func object(_ description: String? = nil, properties: [(String, ToolSchema)] = [], required: [String] = []) -> ToolSchema {
        var schema = ToolSchema(kind: .object, description: description)
        schema.properties = properties.map { (name: $0.0, schema: $0.1) }
        schema.required = required
        return schema
    }

    public static func string(_ description: String? = nil, oneOf values: [String]? = nil) -> ToolSchema {
        var schema = ToolSchema(kind: .string, description: description)
        schema.allowed = values
        return schema
    }

    public static func integer(_ description: String? = nil, minimum: Int? = nil, maximum: Int? = nil) -> ToolSchema {
        var schema = ToolSchema(kind: .integer, description: description)
        schema.minimum = minimum
        schema.maximum = maximum
        return schema
    }

    public static func boolean(_ description: String? = nil) -> ToolSchema {
        ToolSchema(kind: .boolean, description: description)
    }

    public static func array(_ description: String? = nil, of items: ToolSchema) -> ToolSchema {
        var schema = ToolSchema(kind: .array, description: description)
        schema.items = [items]
        return schema
    }

    /// The schema as `tools/list` gives it.
    public var json: JSONValue {
        var object: [String: JSONValue] = ["type": .string(kind.rawValue)]
        if let description { object["description"] = .string(description) }
        switch kind {
        case .object:
            object["properties"] = .object(Dictionary(uniqueKeysWithValues: properties.map { ($0.name, $0.schema.json) }))
            if !required.isEmpty { object["required"] = .array(required.map(JSONValue.string)) }
            object["additionalProperties"] = .bool(allowsOtherProperties)
        case .array:
            if let item = items.first { object["items"] = item.json }
        case .string:
            if let allowed { object["enum"] = .array(allowed.map(JSONValue.string)) }
        case .integer:
            if let minimum { object["minimum"] = .int(minimum) }
            if let maximum { object["maximum"] = .int(maximum) }
        case .boolean:
            break
        }
        return .object(object)
    }

    // MARK: Validation

    /// Checks a value: the first violation, as the text of a tool error (`<path>: <reason>.`), or nil.
    /// `null` members are removed first, as absent.
    public func violation(of value: JSONValue) -> String? {
        check(value.removingNullMembers, path: "")
    }

    private func check(_ value: JSONValue, path: String) -> String? {
        func at(_ name: String) -> String { path.isEmpty ? name : "\(path).\(name)" }
        func fail(_ reason: String) -> String { "\(path.isEmpty ? "arguments" : path): \(reason)." }
        switch (kind, value) {
        case (.object, .object(let members)):
            let names = Set(properties.map(\.name))
            if !allowsOtherProperties, let unknown = members.keys.filter({ !names.contains($0) }).sorted().first {
                return "\(at(unknown)): unknown argument."
            }
            if let missing = required.first(where: { members[$0] == nil }) {
                return "\(at(missing)): required."
            }
            for (name, schema) in properties {
                if let member = members[name], let violation = schema.check(member, path: at(name)) { return violation }
            }
            return nil
        case (.array, .array(let elements)):
            guard let item = items.first else { return nil }
            for (index, element) in elements.enumerated() {
                if let violation = item.check(element, path: "\(path)[\(index)]") { return violation }
            }
            return nil
        case (.string, .string(let text)):
            if let allowed, !allowed.contains(text) { return fail("must be one of \(allowed.joined(separator: ", "))") }
            return nil
        case (.integer, .int(let number)):
            if let minimum, number < minimum { return fail("must be at least \(minimum)") }
            if let maximum, number > maximum { return fail("must be at most \(maximum)") }
            return nil
        case (.boolean, .bool):
            return nil
        default:
            let name = switch kind {
            case .object: "an object"
            case .array: "an array"
            case .string: "a string"
            case .boolean: "a boolean"
            case .integer: "an integer"
            }
            return fail("must be \(name)")
        }
    }
}
