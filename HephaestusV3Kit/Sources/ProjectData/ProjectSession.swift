import ExternalTools
import FileStorage
import Foundation
import Observation

/// The projects as the windows see them: the latest snapshot, the state of the start, the login shell and
/// the tools, and the changes the windows ask for. One session serves the whole app (`ProjectSession`'s
/// owner creates it once); everything it does goes through its `ProjectLibrary`.
@MainActor @Observable
public final class ProjectSession {
    /// Where the session is in its start.
    public enum Phase: Equatable, Sendable {
        /// Taking the lock, loading.
        case starting
        /// The projects are loaded.
        case ready
        /// The data folder can't be used: there is none, the folder can't be created, or another copy of the
        /// app holds it.
        case failed(ProjectError)
    }

    public private(set) var phase: Phase = .starting
    public private(set) var snapshot = ProjectSnapshot.empty
    /// The login shell's environment, once captured; nil while capturing.
    public private(set) var shell: ShellEnvironment.Capture?
    /// The tools found in that environment.
    public private(set) var tools = Tools.notLookedUp
    /// True while the shell and the tools are looked up again.
    public private(set) var isLookingUpTools = false

    public let dataFolder: DataFolder?
    @ObservationIgnored private let runner: any ProcessRunning
    @ObservationIgnored private let processEnvironment: [String: String]
    @ObservationIgnored private let hub: FileEventHub
    @ObservationIgnored private var library: ProjectLibrary?
    /// The library, once started: other features' libraries ask it for ticket and bundle numbers.
    public var projectLibrary: ProjectLibrary? { library }
    /// Called with every batch of file events, after the projects reloaded: other features reload their
    /// own files.
    @ObservationIgnored private var batchObservers: [@MainActor ([FileEvent]) async -> Void] = []

    /// Adds a function called with every batch of file events of the watched folders.
    public func observeFileEvents(_ observer: @escaping @MainActor ([FileEvent]) async -> Void) {
        batchObservers.append(observer)
    }
    @ObservationIgnored private var lock: FolderLock?
    @ObservationIgnored private var watching: Task<Void, Never>?

    /// - Parameters:
    ///   - dataFolder: the app's data folder (`DataFolder.resolve()`); tests pass a temporary one.
    ///   - runner: starts the shell and the tools; tests pass a fake.
    ///   - processEnvironment: the app's own environment, the start of the shell's.
    public init(dataFolder: DataFolder?, runner: any ProcessRunning = SystemProcessRunner.shared,
                processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                hub: FileEventHub = FileEventHub()) {
        self.dataFolder = dataFolder
        self.runner = runner
        self.processEnvironment = processEnvironment
        self.hub = hub
    }

    /// Starts in this order (docs/architecture.md › ProjectData): create the data folder and take its
    /// lock, load, watch the files; then, without holding the windows, capture the
    /// login shell's environment, look the tools up, and read the projects' origins.
    public func start() async {
        guard phase == .starting, library == nil else { return }
        guard let dataFolder else {
            phase = .failed(.noDataFolder)
            return
        }
        do {
            try dataFolder.createIfNeeded()
            lock = try dataFolder.lock()
        } catch let error as StorageError {
            phase = .failed(.storage(error))
            return
        } catch {
            phase = .failed(.noDataFolder)
            return
        }
        let library = ProjectLibrary(dataFolder: dataFolder, runner: runner)
        self.library = library
        apply(await library.load())
        phase = .ready
        await watch()
        await lookUpTools()
    }

    /// Captures the login shell's environment again, looks the tools up, and reads the origins: Settings ▸
    /// Projects' Look Again.
    public func lookUpTools() async {
        guard let library, !isLookingUpTools else { return }
        isLookingUpTools = true
        defer { isLookingUpTools = false }
        let capture = await ShellEnvironment.capture(processEnvironment: processEnvironment, runner: runner)
        shell = capture
        tools = await ToolLocator.lookUp(environment: capture.environment, runner: runner)
        await library.setTools(tools)
        apply(await library.refreshOrigins())
    }

    /// Stops watching and ends the running tools, as the app quits. The lock goes with the process.
    public func stop() async {
        watching?.cancel()
        await hub.stop()
        if let runner = runner as? SystemProcessRunner {
            runner.terminateAll()
        }
        lock?.release()
    }

    // MARK: Changes

    /// Creates a project; returns its identifier.
    @discardableResult
    public func create(_ request: NewProject) async throws(ProjectError) -> String {
        let library = try readyLibrary()
        let result = try await library.create(request)
        apply(result.snapshot)
        await updateWatchedFolders()
        apply(await library.refreshOrigins())
        return result.id
    }

    /// Adds an existing project's folder; returns its identifier.
    @discardableResult
    public func open(folder: String) async throws(ProjectError) -> String {
        let library = try readyLibrary()
        let result = try await library.open(folder: folder)
        apply(result.snapshot)
        await updateWatchedFolders()
        apply(await library.refreshOrigins())
        return result.id
    }

    public func update(_ id: String, _ change: ProjectChange) async throws(ProjectError) {
        let library = try readyLibrary()
        apply(try await library.update(id, change))
    }

    /// Removes a project and its sub projects from the app; their folders stay as they are.
    public func remove(_ id: String) async throws(ProjectError) {
        let library = try readyLibrary()
        apply(try await library.remove(id))
        await updateWatchedFolders()
    }

    public func setCurrentEnvironment(_ id: String, to name: String) async throws(ProjectError) {
        let library = try readyLibrary()
        apply(try await library.setCurrentEnvironment(id, to: name))
    }

    // MARK: Kubernetes

    /// kubectl with the tools found, or nil without it.
    public var kubectl: Kubectl? {
        Kubectl(tools, runner: runner)
    }

    // MARK: Private

    private func readyLibrary() throws(ProjectError) -> ProjectLibrary {
        guard let library else {
            if case .failed(let error) = phase { throw error }
            throw .noDataFolder
        }
        return library
    }

    /// Keeps a snapshot newer than the one shown.
    private func apply(_ snapshot: ProjectSnapshot?) {
        guard let snapshot, snapshot.revision > self.snapshot.revision || self.snapshot.revision == 0 else { return }
        self.snapshot = snapshot
    }

    private func watch() async {
        await updateWatchedFolders()
        let batches = hub.batches
        watching = Task { [weak self] in
            for await batch in batches {
                guard let library = self?.library else { return }
                let snapshot = await library.handle(batch)
                await self?.applyAndRewatch(snapshot)
                for observer in self?.batchObservers ?? [] {
                    await observer(batch)
                }
            }
        }
    }

    private func applyAndRewatch(_ snapshot: ProjectSnapshot?) async {
        apply(snapshot)
        if snapshot != nil {
            await updateWatchedFolders()
        }
    }

    private func updateWatchedFolders() async {
        guard let library else { return }
        let wanted = await library.watchedFolders
        let current = Set(await hub.watchedFolders)
        for folder in current.subtracting(wanted) { await hub.unwatch(folder) }
        for folder in wanted.subtracting(current) { await hub.watch(folder) }
    }
}
