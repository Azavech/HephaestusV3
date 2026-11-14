import FileStorage
import Foundation

/// `<data folder>/registry.yml`: the top-level projects, in the order they were added. Sub projects are
/// listed by their parent's `subprojects` (docs/data.md › Registry file).
public struct RegistryFile: Codable, Sendable, Hashable {
    public var schema: Int
    /// Absolute paths of the projects' folders, without duplicates.
    public var projects: [String]
    public var unknownKeys: YAMLMapping

    public init(schema: Int = 1, projects: [String] = [], unknownKeys: YAMLMapping = [:]) {
        self.schema = schema
        self.projects = projects
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["schema", "projects"]

    public init(from decoder: any Decoder) throws {
        let c = try MappingReader(decoder)
        schema = try c.schema()
        projects = try c.value("projects", default: [])
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = MappingWriter(encoder)
        try c.encode(schema, "schema")
        try c.encode(projects, "projects")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The entries loaded, in order: the absolute paths. Another entry is skipped, and reported.
    public var loadableEntries: [String] {
        projects.filter(ProjectRules.isAbsolutePath)
    }
}
