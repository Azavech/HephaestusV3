import FileStorage
import Foundation

/// The app's data folder: the files that belong to this Mac rather than to a project, such as the list
/// of projects (docs/data.md › Data folder).
///
/// It is `~/Library/Application Support/HephaestusV3/`, or the folder that `HEPHAESTUS_DATA_DIR` names
/// (development). Earlier builds kept it in the App Group container, copied once from there
/// (`migrateFromAppGroup`). Tests always pass a temporary folder.
public struct DataFolder: Sendable, Hashable {
    /// The App Group whose container held the data before 14 November 2026.
    public static let appGroup = "group.fr.azavech.hephaestusv3"
    /// The folder's name in Application Support.
    public static let folderName = "HephaestusV3"
    /// The environment variable that names another folder.
    public static let overrideVariable = "HEPHAESTUS_DATA_DIR"

    public let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    /// The app's folder: `HEPHAESTUS_DATA_DIR` when it is set to an absolute path, else
    /// `<Application Support>/HephaestusV3/`; nil without an Application Support folder.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupport: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ) -> DataFolder? {
        if let path = environment[overrideVariable], path.hasPrefix("/") {
            return DataFolder(url: URL(fileURLWithPath: path, isDirectory: true))
        }
        return applicationSupport.map { DataFolder(url: $0.appendingPathComponent(folderName, isDirectory: true)) }
    }

    /// The App Group container of earlier builds, when the system gives one.
    public static var appGroupContainer: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    /// Copies the data of earlier builds once: when this folder doesn't exist yet and `container` can be read and
    /// holds something besides the system's `Library`. Each item is copied (APFS clones it) into a sibling
    /// folder that then takes this folder's name, so an interrupted copy leaves nothing half done. The container
    /// is left as it is. Returns whether it copied. A copy whose signature has no profile granting the App Group
    /// can't read the container (macOS refuses), and copies nothing.
    @discardableResult
    public func migrateFromAppGroup(container: URL? = DataFolder.appGroupContainer) -> Bool {
        let manager = FileManager.default
        guard let container, !manager.fileExists(atPath: url.path),
              let items = try? manager.contentsOfDirectory(atPath: container.path) else { return false }
        let data = items.filter { $0 != "Library" && $0 != ".DS_Store" && !$0.hasPrefix(".com.apple") }
        guard !data.isEmpty else { return false }
        let staging = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).copying-\(UUID().uuidString)")
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for item in data {
                try manager.copyItem(at: container.appendingPathComponent(item), to: staging.appendingPathComponent(item))
            }
            try manager.moveItem(at: staging, to: url)
            return true
        } catch {
            try? manager.removeItem(at: staging)
            return false
        }
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
