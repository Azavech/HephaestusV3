import Foundation

/// Prefilled bodies and type summaries (docs/data.md › Contracts › Prefilled bodies).
enum ContractSamples {
    /// A media type's body: its `example`, the first of its `examples`, a sample of its schema, or nothing;
    /// written as the media type is.
    static func body(for mediaType: ContractValue, mediaType name: String, resolver: ContractResolver, file: URL) -> String {
        let value: ContractValue?
        if let example = mediaType["example"] {
            value = example
        } else if let first = mediaType["examples"]?.members?.first {
            value = resolver.resolve(first.value, in: file).0["value"]
        } else if let schema = mediaType["schema"] {
            value = sample(schema, resolver: resolver, file: file, seen: []) ?? .null
        } else {
            value = nil
        }
        guard let value else { return "" }
        return text(value, mediaType: name)
    }

    /// The value as a media type writes it: JSON with two-space indentation; a form's `name=value&…`; else a
    /// string as is, any other value as JSON.
    static func text(_ value: ContractValue, mediaType: String) -> String {
        let type = mediaType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if type == "application/json" || type.hasSuffix("+json") { return value.json() }
        if type == "application/x-www-form-urlencoded", let members = value.members {
            return members.map { member in
                let text: String = switch member.value {
                case .string(let string): string
                case .number(_, let written): written
                case .bool(let flag): flag ? "true" : "false"
                default: member.value.json(pretty: false)
                }
                return RequestBuilder.encode(member.key) + "=" + RequestBuilder.encode(text)
            }.joined(separator: "&")
        }
        if case .string(let string) = value { return string }
        return value.json()
    }

    /// A sample of a schema; nil for an unresolved or circular ref (a property is then left out).
    static func sample(_ raw: ContractValue, resolver: ContractResolver, file: URL, seen: Set<String>) -> ContractValue? {
        var seen = seen
        if let ref = raw["$ref"]?.string {
            guard !seen.contains(ref) else { return nil }
            seen.insert(ref)
        }
        let (schema, schemaFile) = resolver.resolve(raw, in: file)
        if raw["$ref"] != nil, schema == .null { return nil }
        if let example = schema["example"] { return example }
        if let first = schema["examples"]?.array?.first { return first }
        if let value = schema["default"] { return value }
        if let value = schema["const"] { return value }
        if let first = schema["enum"]?.array?.first { return first }
        if let all = schema["allOf"]?.array {
            let samples = all.compactMap { sample($0, resolver: resolver, file: schemaFile, seen: seen) }
            let objects = samples.compactMap(\.members)
            if !objects.isEmpty { return .object(objects.flatMap { $0 }) }
            return samples.first
        }
        if let first = (schema["oneOf"] ?? schema["anyOf"])?.array?.first {
            return sample(first, resolver: resolver, file: schemaFile, seen: seen)
        }
        let type = type(of: schema)
        if type == "object" || (type == nil && schema["properties"] != nil) {
            return .object((schema["properties"]?.members ?? []).compactMap { property in
                let (resolved, _) = resolver.resolve(property.value, in: schemaFile)
                guard resolved["readOnly"]?.bool != true,
                      let value = sample(property.value, resolver: resolver, file: schemaFile, seen: seen) else { return nil }
                return ContractValue.Member(property.key, value)
            })
        }
        switch type {
        case "array":
            guard let items = schema["items"] else { return .array([]) }
            return .array(sample(items, resolver: resolver, file: schemaFile, seen: seen).map { [$0] } ?? [])
        case "string":
            return .string(formats[schema["format"]?.string ?? ""] ?? "string")
        case "integer", "number":
            if let minimum = schema["minimum"], case .number = minimum { return minimum }
            return .number(0, text: "0")
        case "boolean":
            return .bool(true)
        default:
            return .null
        }
    }

    /// `type`, or the first type other than `null` of a 3.1 array.
    static func type(of schema: ContractValue) -> String? {
        if let type = schema["type"]?.string { return type }
        return schema["type"]?.array?.compactMap(\.string).first { $0 != "null" }
    }

    static let formats: [String: String] = [
        "date": "2024-01-01", "date-time": "2024-01-01T00:00:00Z", "time": "00:00:00", "email": "user@example.com",
        "uuid": "3fa85f64-5717-4562-b3fc-2c963f66afa6", "uri": "https://example.com", "url": "https://example.com",
        "hostname": "example.com", "ipv4": "192.0.2.1", "ipv6": "2001:db8::1",
    ]

    /// A schema's type summary: `Pet · object` through a ref; the types joined with ` | ` (` | null` when
    /// `nullable`); `object` with properties; the composition keyword; `any`.
    static func typeSummary(_ raw: ContractValue, resolver: ContractResolver, file: URL) -> String {
        let (schema, _) = resolver.resolve(raw, in: file)
        let summary: String
        if let type = schema["type"]?.string {
            summary = type + (schema["nullable"]?.bool == true ? " | null" : "")
        } else if let types = schema["type"]?.array?.compactMap(\.string), !types.isEmpty {
            summary = types.joined(separator: " | ")
        } else if schema["properties"] != nil {
            summary = "object"
        } else if let keyword = ["allOf", "oneOf", "anyOf"].first(where: { schema[$0] != nil }) {
            summary = keyword
        } else {
            summary = "any"
        }
        if let name = ContractResolver.name(of: raw) {
            return schema == .null ? "Unresolved \(raw["$ref"]?.string ?? "")" : "\(name) · \(summary)"
        }
        return summary
    }
}
