import FileStorage
import Foundation

/// A project loaded from its folder, with the settings it has once its parent's are applied.
public struct LoadedProject: Sendable, Hashable, Identifiable {
    /// The project's folder: an absolute, standardized path.
    public var root: String
    public var file: ProjectFile
    /// The loaded project whose `subprojects` lists this one; nil for a top-level project.
    public var parentID: String?
    /// 0 for a top-level project, 1 for its sub projects, and so on.
    public var depth: Int
    /// The loaded sub projects, in `subprojects` order.
    public var childIDs: [String]
    /// The settings as they apply ([Data › Resolution](docs/data.md)).
    public var resolved: ResolvedSettings
    /// Why the file on disk is invalid now, while the version loaded before stays; nil when it is fine.
    public var fileIssue: String?

    public var id: String { file.id }

    public init(root: String, file: ProjectFile, parentID: String?, depth: Int, childIDs: [String], resolved: ResolvedSettings,
                fileIssue: String?) {
        self.root = root
        self.file = file
        self.parentID = parentID
        self.depth = depth
        self.childIDs = childIDs
        self.resolved = resolved
        self.fileIssue = fileIssue
    }
}

/// What a project's settings are once inheritance applies (docs/data.md › Resolution).
public struct ResolvedSettings: Sendable, Hashable {
    /// The environments as they apply: the inherited ones with the project's changes, then its own whose
    /// names they don't have. Empty for a project that isn't a service.
    public var environments: [EnvironmentEntry] = []
    /// The environments inherited from the parent, as the parent resolves them, without the changes.
    public var inheritedEnvironments: [EnvironmentEntry] = []
    /// The environment the user works in: the chosen one while it applies, else the first.
    public var currentEnvironment: String?
    /// The GitHub page: the parent's while the project uses its parent's settings, else the typed page,
    /// else the origin's.
    public var githubPage: String?
    /// The page of the project's own `origin` remote, the GitHub page field's placeholder.
    public var originGithubPage: String?
    /// Whether the service's graph is enabled, the parent's while the project uses its parent's settings.
    public var graphEnabled = false

    public init() {}
}

/// An entry of the registry or of a parent's `subprojects` that didn't load, and why. The entry stays: the
/// project loads once its folder and file are fine.
public struct ProjectIssue: Sendable, Hashable, Identifiable {
    public enum Reason: Sendable, Hashable {
        /// The folder doesn't exist.
        case folderMissing
        /// The folder has no `.hephaestus/project.yml`.
        case fileMissing
        /// The file breaks a read rule.
        case invalidFile(reason: String)
        /// Another loaded project, loaded before it, has its identifier.
        case identifierInUse(identifier: String, by: String)
        /// The entry isn't a path V3 can use: not absolute in the registry, not relative in `subprojects`.
        case invalidEntry
    }

    public enum Source: Sendable, Hashable {
        case registry
        case subproject(parentID: String, entry: String)
    }

    /// The folder the entry names, absolute.
    public var path: String
    public var source: Source
    public var reason: Reason

    public var id: String { path }
}

/// Everything loaded, at one moment: the projects in the order the lists show them, and the entries that
/// didn't load. Each change gives a new snapshot with a higher revision.
public struct ProjectSnapshot: Sendable, Hashable {
    public var revision: Int
    /// The loaded projects, depth first: each top-level project in the registry's order, followed by its
    /// sub projects in `subprojects` order.
    public var projects: [LoadedProject]
    public var issues: [ProjectIssue]

    public init(revision: Int = 0, projects: [LoadedProject] = [], issues: [ProjectIssue] = []) {
        self.revision = revision
        self.projects = projects
        self.issues = issues
    }

    public static let empty = ProjectSnapshot()

    public func project(_ id: String) -> LoadedProject? {
        projects.first { $0.id == id }
    }

    /// The loaded project whose folder is `root`.
    public func project(atRoot root: String) -> LoadedProject? {
        projects.first { $0.root == root }
    }

    /// A project and all its loaded descendants, depth first.
    public func family(of id: String) -> [LoadedProject] {
        guard let project = project(id) else { return [] }
        return [project] + project.childIDs.flatMap { family(of: $0) }
    }
}
