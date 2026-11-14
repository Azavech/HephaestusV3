import FileStorage
import Foundation

/// `<data folder>/current-environments.yml`: the environment the user works in, chosen for each service,
/// kept out of `project.yml` so that choosing one changes no committed file (docs/data.md › Current
/// environments file).
public struct CurrentEnvironmentsFile: Codable, Sendable, Hashable {
    public var schema: Int
    /// The name of the chosen environment, by project identifier. A project without an entry, or whose
    /// entry names none of its environments, works in its first environment.
    public var projects: [String: String]
    public var unknownKeys: YAMLMapping

    public init(schema: Int = 1, projects: [String: String] = [:], unknownKeys: YAMLMapping = [:]) {
        self.schema = schema
        self.projects = projects
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["schema", "projects"]

    public init(from decoder: any Decoder) throws {
        let c = try MappingReader(decoder)
        schema = try c.schema()
        projects = try c.value("projects", default: [:])
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = MappingWriter(encoder)
        try c.encode(schema, "schema")
        try c.encode(SortedNames(projects), "projects")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The identifiers in Unicode code point order, so that a file written twice is the same.
    private struct SortedNames: Encodable {
        let names: [String: String]

        init(_ names: [String: String]) {
            self.names = names
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: AnyKey.self)
            for key in names.keys.sorted(by: { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }) {
                try container.encode(names[key]!, forKey: AnyKey(key))
            }
        }
    }
}
