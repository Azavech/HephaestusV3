import FileStorage
import Foundation

/// Why a change to the projects was refused or failed. The windows say it in their own words, by case;
/// `description` is the English message of the logs and of Claude's tools.
public enum ProjectError: Error, Sendable, Hashable, CustomStringConvertible {
    /// A value breaks a write rule.
    case rule(ProjectRuleError)
    /// A file couldn't be read or written.
    case storage(StorageError)
    /// No data folder: the app has no App Group, or the folder can't be used.
    case noDataFolder
    /// The folder has no `.hephaestus/project.yml`.
    case noProject(path: String)
    /// The folder already holds a project: open it instead.
    case alreadyContainsProject(path: String)
    /// The folder doesn't exist.
    case folderMissing(path: String)
    /// The folder isn't strictly inside the parent's folder.
    case notInsideParent(parentName: String)
    /// No loaded project has this identifier.
    case projectNotLoaded(String)
    /// The project has no environment of this name.
    case unknownEnvironment(String)

    public var description: String {
        switch self {
        case let .rule(error): error.description
        case let .storage(error): error.description
        case .noDataFolder: "The app has no data folder."
        case let .noProject(path): "\(path) has no .hephaestus/project.yml."
        case let .alreadyContainsProject(path): "\(path) already contains a project; open it instead."
        case let .folderMissing(path): "\(path) doesn't exist."
        case let .notInsideParent(parentName): "Choose a folder inside “\(parentName)”."
        case let .projectNotLoaded(id): "No project \(id) is loaded."
        case let .unknownEnvironment(name): "The project has no environment named “\(name)”."
        }
    }
}
