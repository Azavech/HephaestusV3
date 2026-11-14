import FileStorage
import Foundation

/// The one-time import of HephaestusV2's project list (docs/data.md › Import from HephaestusV2).
///
/// V3 replaces V2 and reads the same project folders, so the import copies only what V2 kept on this
/// Mac: the list of top-level projects and the environment chosen for each service. It runs when the
/// data folder has no `registry.yml`, and writes one even when there is nothing to import, so it runs
/// once: an empty list later never brings V2's projects back.
public enum V2Import {
    /// V2's data folder: `~/Library/Application Support/HephaestusV2/`.
    public static func defaultV2Folder(homeDirectory: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Library/Application Support/HephaestusV2", isDirectory: true)
    }

    /// The identifier of V2's own project, which V3 doesn't bring over.
    public static let v2ProjectIdentifier = "HEPH"

    /// What an import did.
    public struct Result: Sendable, Hashable {
        /// The project folders brought over, in V2's order.
        public var imported: [String] = []
        /// V2's own project, left out.
        public var skippedV2Project: [String] = []
        /// Entries that aren't absolute paths, or listed twice, left out.
        public var skippedInvalid: [String] = []
        /// Whether V2's list could be read: false when V2 has no list or an invalid one.
        public var foundV2List = false
        /// The services whose chosen environment was brought over.
        public var currentEnvironments = 0

        public init() {}
    }

    /// Runs the import when the data folder has no `registry.yml`. Writes `current-environments.yml`
    /// first, then `registry.yml`, the sign that the import ran. Returns nil when it had already run.
    public static func runIfNeeded(into folder: DataFolder, from v2Folder: URL = defaultV2Folder(),
                                   ownWrites: OwnWrites? = nil) throws(StorageError) -> Result? {
        guard YAMLFile.isMissing(folder.registryFile) else { return nil }
        var result = Result()
        var registry = RegistryFile()
        if let v2Registry = try? YAMLFile.read(RegistryFile.self, at: v2Folder.appendingPathComponent("registry.yml")) {
            result.foundV2List = true
            for entry in v2Registry.projects {
                guard ProjectRules.isAbsolutePath(entry), !registry.projects.contains(entry) else {
                    result.skippedInvalid.append(entry)
                    continue
                }
                if identifier(ofProjectAt: entry) == v2ProjectIdentifier {
                    result.skippedV2Project.append(entry)
                    continue
                }
                registry.projects.append(entry)
            }
            result.imported = registry.projects
        }
        if let v2Choices = try? YAMLFile.read(CurrentEnvironmentsFile.self,
                                              at: v2Folder.appendingPathComponent("current-environments.yml")) {
            var choices = v2Choices.projects
            choices[v2ProjectIdentifier] = nil
            if !choices.isEmpty {
                try YAMLFile.write(CurrentEnvironmentsFile(projects: choices), to: folder.currentEnvironmentsFile, ownWrites: ownWrites)
                result.currentEnvironments = choices.count
            }
        }
        try YAMLFile.write(registry, to: folder.registryFile, ownWrites: ownWrites)
        return result
    }

    /// The `id` of the project file in a folder; nil when it has none or can't be read.
    static func identifier(ofProjectAt path: String) -> String? {
        let file = ProjectFolder(root: URL(fileURLWithPath: path, isDirectory: true)).projectFile
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? YAMLCoding.decode(IdentifierOnly.self, from: data))?.id
    }

    /// Only the `id` of a project file, whatever its other keys hold.
    private struct IdentifierOnly: Decodable {
        var id: String?
    }
}
