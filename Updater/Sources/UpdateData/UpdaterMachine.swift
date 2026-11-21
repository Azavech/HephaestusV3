import Foundation

/// The Updater's state machine (docs/updater.md › Updater states) and its check schedule, with the clock, feed,
/// downloader, verifier and installer injected.
///
/// Every input returns at once; checks, downloads and the wait for the app to quit run in tasks that report back to
/// the actor. Every change of state, and every request that leaves it as it is, posts the current status.
public actor UpdaterMachine {
    public struct Dependencies: Sendable {
        /// The feed (`ReleaseFeed.latest()`).
        public var latest: @Sendable () async throws(UpdaterError) -> FeedResult
        /// Steps 1 to 4 (`UpdateDownloader.download`); gives the disk image.
        public var download: @Sendable (_ manifest: ReleaseManifest, _ manifestData: Data, _ diskImageURL: URL) async throws(UpdaterError) -> URL
        /// Steps 5 to 9 (`UpdateVerifier.verify`); gives the unpacked app.
        public var verify: @Sendable (_ diskImage: URL, _ manifest: ReleaseManifest) async throws(UpdaterError) -> URL
        /// The install (`UpdateInstaller.install`).
        public var install: @Sendable (_ update: URL, _ manifest: ReleaseManifest, _ restart: Bool, _ activate: Bool) async -> InstallOutcome
        /// Deletes a build's cache folder after a failure (`UpdateDownloader.deleteBuildFolder`).
        public var discard: @Sendable (_ build: Int) async -> Void
        /// Posts a message to the app.
        public var post: @Sendable (UpdaterMessage) -> Void
        /// Waits, throwing when the task is cancelled.
        public var sleep: @Sendable (Duration) async throws -> Void
        /// Ends the process.
        public var exit: @Sendable (Int32) -> Void
        public var log: @Sendable (String) -> Void

        public init(latest: @escaping @Sendable () async throws(UpdaterError) -> FeedResult,
                    download: @escaping @Sendable (ReleaseManifest, Data, URL) async throws(UpdaterError) -> URL,
                    verify: @escaping @Sendable (URL, ReleaseManifest) async throws(UpdaterError) -> URL,
                    install: @escaping @Sendable (URL, ReleaseManifest, Bool, Bool) async -> InstallOutcome,
                    discard: @escaping @Sendable (Int) async -> Void,
                    post: @escaping @Sendable (UpdaterMessage) -> Void,
                    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                    exit: @escaping @Sendable (Int32) -> Void,
                    log: @escaping @Sendable (String) -> Void = { _ in }) {
            self.latest = latest
            self.download = download
            self.verify = verify
            self.install = install
            self.discard = discard
            self.post = post
            self.sleep = sleep
            self.exit = exit
            self.log = log
        }
    }

    /// The first check runs 10 seconds after the start.
    public static let firstCheckDelay: Duration = .seconds(10)
    /// How long the app may take to quit after `app.quitting` in state `ready`.
    public static let quitTimeout: Duration = .seconds(60)

    public private(set) var status: UpdaterStatus = .initial
    public private(set) var intervalMinutes: Int
    public private(set) var autoUpdate: Bool
    /// The status the process ended with; nil while it runs.
    public private(set) var exitStatus: Int32?

    let runningBuild: Int
    let systemVersion: OperatingSystemVersion
    let cacheRoot: URL
    let dependencies: Dependencies

    /// The newer build of the last check: kept in `available`, `downloading`, `ready`, `installing`, and `error`
    /// with a build.
    private var known: Known?
    /// The verified app of state `ready`.
    private var readyApp: URL?
    private var installRestart = false
    private var installActivate = false
    private var isInstalling = false
    private var scheduleTask: Task<Void, Never>?
    private var quitTimeoutTask: Task<Void, Never>?
    /// Raised at each check and download, so that a stale result is dropped.
    private var generation = 0

    struct Known: Sendable {
        var manifest: ReleaseManifest
        var manifestData: Data
        var diskImageURL: URL
    }

    public init(arguments: UpdaterArguments, runningBuild: Int, systemVersion: OperatingSystemVersion, cacheRoot: URL,
                dependencies: Dependencies) {
        intervalMinutes = UpdaterArguments.clampInterval(arguments.intervalMinutes)
        autoUpdate = arguments.autoUpdate
        self.runningBuild = runningBuild
        self.systemVersion = systemVersion
        self.cacheRoot = cacheRoot
        self.dependencies = dependencies
    }

    // MARK: Inputs

    /// Once the observers are registered: posts `idle` and schedules the first check.
    public func start() {
        guard exitStatus == nil else { return }
        setStatus(.initial)
        schedule(after: Self.firstCheckDelay)
    }

    /// A request of the app whose `pid` matched.
    public func handle(_ request: UpdaterRequest) {
        guard exitStatus == nil else { return }
        switch request {
        case .check(let interval, let auto):
            if let interval { intervalMinutes = UpdaterArguments.clampInterval(interval) }
            if let auto { autoUpdate = auto }
            checkRequested()
        case .install:
            installRequested()
        case .appQuitting(let restart, let activate):
            appQuitting(restart: restart, activate: activate)
        }
    }

    /// The app's process ended: the install runs in state `installing`; in any other state the Updater ends with
    /// status 0 at once.
    public func appExited() async {
        guard exitStatus == nil, !isInstalling else { return }
        guard status.state == .installing, let app = readyApp, let known else {
            dependencies.log("The app quit; the Updater ends.")
            terminate(0)
            return
        }
        isInstalling = true
        quitTimeoutTask?.cancel()
        scheduleTask?.cancel()
        let version = known.manifest.appVersion.display
        dependencies.log("Installing \(version).")
        switch await dependencies.install(app, known.manifest, installRestart, installActivate) {
        case .installed:
            dependencies.log("Installed \(version).")
            terminate(0)
        case .failed(let text):
            dependencies.log("Installing \(version) failed: \(text)")
            terminate(1)
        }
    }

    /// A scheduled check is due.
    func checkDue() {
        guard exitStatus == nil else { return }
        switch status.state {
        case .idle, .upToDate, .available, .error:
            startCheck()
        case .checking:
            // The running check schedules the next one when it ends.
            postStatus()
        case .downloading, .ready, .installing:
            // A due check skipped counts as a check.
            postStatus()
            schedule(after: interval)
        }
    }

    // MARK: Checks

    private var interval: Duration { .seconds(Int64(intervalMinutes) * 60) }

    /// A `check` received. When it turned `autoUpdate` on while an update was `available`, the check finds it
    /// again and its download starts.
    private func checkRequested() {
        switch status.state {
        case .idle, .upToDate, .available, .error:
            startCheck()
        case .checking, .downloading, .ready, .installing:
            postStatus()
        }
    }

    private func schedule(after delay: Duration) {
        scheduleTask?.cancel()
        let sleep = dependencies.sleep
        scheduleTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.checkDue()
        }
    }

    private func startCheck() {
        scheduleTask?.cancel()
        scheduleTask = nil
        generation += 1
        let current = generation
        setStatus(UpdaterStatus(state: .checking))
        let latest = dependencies.latest
        Task { [weak self] in
            let result: Result<FeedResult, UpdaterError>
            do throws(UpdaterError) {
                result = .success(try await latest())
            } catch {
                result = .failure(error)
            }
            await self?.finishCheck(result, generation: current)
        }
    }

    private func finishCheck(_ result: Result<FeedResult, UpdaterError>, generation current: Int) {
        guard exitStatus == nil, current == generation, status.state == .checking else { return }
        defer { schedule(after: interval) }
        switch result {
        case .failure(let error):
            known = nil
            dependencies.log("The check failed: \(error.message)")
            setStatus(UpdaterStatus(state: .error, message: error.message))
        case .success(.noRelease):
            known = nil
            setStatus(UpdaterStatus(state: .upToDate))
        case .success(.release(let manifest, let manifestData, let diskImageURL)):
            let found = Known(manifest: manifest, manifestData: manifestData, diskImageURL: diskImageURL)
            let version = manifest.appVersion
            switch UpdateDecision.decide(manifest: manifest, runningBuild: runningBuild, systemVersion: systemVersion,
                                         installFailedText: installFailedText(build: manifest.build)) {
            case .upToDate:
                known = nil
                setStatus(UpdaterStatus(state: .upToDate))
            case .requiresNewerSystem:
                known = nil
                setStatus(UpdaterStatus(state: .upToDate, version: manifest.version, build: manifest.build,
                                        message: UpdaterTexts.requiresSystem(version, manifest.minimumSystemVersion)))
            case .previousInstallFailed(_, let text):
                known = found
                setStatus(UpdaterStatus(state: .error, version: manifest.version, build: manifest.build,
                                        message: UpdaterTexts.installFailed(version, text)))
            case .available:
                known = found
                setStatus(UpdaterStatus(state: .available, version: manifest.version, build: manifest.build))
                if autoUpdate {
                    startDownload()
                }
            }
        }
    }

    /// The text of `<build>/install-failed`, without its final line breaks; nil without the file.
    private func installFailedText(build: Int) -> String? {
        guard let data = FileManager.default.contents(atPath: installFailedURL(build: build).path) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    private func installFailedURL(build: Int) -> URL {
        UpdateDownloader.buildFolder(build, in: cacheRoot).appendingPathComponent(UpdateInstaller.installFailedName)
    }

    // MARK: Download and verification

    private func installRequested() {
        switch status.state {
        case .available where known != nil:
            startDownload()
        case .error where known != nil && status.build != nil:
            if let known {
                try? FileManager.default.removeItem(at: installFailedURL(build: known.manifest.build))
            }
            startDownload()
        default:
            postStatus()
        }
    }

    private func startDownload() {
        guard let known else { return }
        generation += 1
        let current = generation
        readyApp = nil
        setStatus(UpdaterStatus(state: .downloading, version: known.manifest.version, build: known.manifest.build))
        let download = dependencies.download
        let verify = dependencies.verify
        Task { [weak self] in
            let result: Result<URL, UpdaterError>
            do throws(UpdaterError) {
                let image = try await download(known.manifest, known.manifestData, known.diskImageURL)
                result = .success(try await verify(image, known.manifest))
            } catch {
                result = .failure(error)
            }
            await self?.finishDownload(result, known: known, generation: current)
        }
    }

    private func finishDownload(_ result: Result<URL, UpdaterError>, known: Known, generation current: Int) async {
        guard exitStatus == nil, current == generation, status.state == .downloading else { return }
        let manifest = known.manifest
        switch result {
        case .success(let app):
            readyApp = app
            dependencies.log("\(manifest.appVersion.display) is ready.")
            setStatus(UpdaterStatus(state: .ready, version: manifest.version, build: manifest.build))
            dependencies.post(.ready(version: manifest.version, build: manifest.build))
        case .failure(let error):
            dependencies.log("The download failed: \(error.message)")
            // The folder goes before the state changes: while it is `downloading`, no request starts another
            // download into it.
            await dependencies.discard(manifest.build)
            guard exitStatus == nil else { return }
            setStatus(UpdaterStatus(state: .error, version: manifest.version, build: manifest.build, message: error.message))
        }
    }

    // MARK: Installing

    private func appQuitting(restart: Bool, activate: Bool) {
        guard status.state == .ready, let known, readyApp != nil else {
            postStatus()
            return
        }
        installRestart = restart
        installActivate = activate
        setStatus(UpdaterStatus(state: .installing, version: known.manifest.version, build: known.manifest.build))
        quitTimeoutTask?.cancel()
        let sleep = dependencies.sleep
        quitTimeoutTask = Task { [weak self] in
            do {
                try await sleep(Self.quitTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.quitTimedOut()
        }
    }

    /// The app still runs 60 seconds after `app.quitting`: back to `ready`.
    private func quitTimedOut() {
        guard exitStatus == nil, !isInstalling, status.state == .installing, let known else { return }
        dependencies.log("The app didn't quit; the update waits.")
        setStatus(UpdaterStatus(state: .ready, version: known.manifest.version, build: known.manifest.build, message: UpdaterTexts.didNotQuit))
    }

    // MARK: Output

    private func setStatus(_ new: UpdaterStatus) {
        status = new
        postStatus()
    }

    private func postStatus() {
        dependencies.post(.status(status))
    }

    private func terminate(_ code: Int32) {
        exitStatus = code
        scheduleTask?.cancel()
        quitTimeoutTask?.cancel()
        dependencies.exit(code)
    }
}
