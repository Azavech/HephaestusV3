import FileStorage
import Foundation

/// The app's data folder: the files that belong to this Mac rather than to a project, such as the list
/// of projects (docs/data.md › Data folder).
///
/// It is the App Group container, `~/Library/Group Containers/group.fr.azavech.hephaestusv3/`, or the
/// folder that `HEPHAESTUS_DATA_DIR` names (development). Tests always pass a temporary folder.
public struct DataFolder: Sendable, Hashable {
    /// The App Group whose container holds the data.
    public static let appGroup = "group.fr.azavech.hephaestusv3"
    /// The environment variable that names another folder.
    public static let overrideVariable = "HEPHAESTUS_DATA_DIR"

    public let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    /// The app's folder: `HEPHAESTUS_DATA_DIR` when it is set to an absolute path, else the App Group
    /// container; nil when the app has neither (a build without the App Group).
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        container: (String) -> URL? = { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    ) -> DataFolder? {
        if let path = environment[overrideVariable], path.hasPrefix("/") {
            return DataFolder(url: URL(fileURLWithPath: path, isDirectory: true))
        }
        return container(appGroup).map(DataFolder.init(url:))
    }

    /// `registry.yml`: the top-level projects.
    public var registryFile: URL { url.appendingPathComponent("registry.yml") }
    /// `current-environments.yml`: the environment chosen for each service.
    public var currentEnvironmentsFile: URL { url.appendingPathComponent("current-environments.yml") }

    /// `<file>.invalid`: a file of the folder that was invalid when the app started, set aside.
    public func invalidCopy(of file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".invalid")
    }

    /// Creates the folder, mode 0700, with its missing parents. Throws `StorageError.folderUnavailable`.
    public func createIfNeeded() throws(StorageError) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw .folderUnavailable(path: url.path, reason: (error as NSError).localizedDescription)
        }
    }

    /// Takes the folder's lock, which the app holds until it quits, so that a second copy of the app
    /// never writes the same files. Throws `StorageError.folderInUse` when another process holds it.
    public func lock() throws -> FolderLock {
        try FolderLock.acquire(url)
    }
}
