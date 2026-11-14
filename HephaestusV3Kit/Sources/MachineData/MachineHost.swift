import FileStorage
import Foundation
import MCPKit
import Observation
import ProjectData

/// A refusal of the machine host: V2's kinds and messages (docs/data.md › Virtual machines).
public struct MachineError: Error, LocalizedError, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable { case invalid, notFound, conflict, unavailable, `internal` }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? { message }

    static let tooMany = MachineError(.conflict, "2 virtual machines are already running.")
    static let needsAppleSilicon = MachineError(.unavailable, MachineFailure.needsAppleSilicon.message)
}

/// The values new machines start with, and their ranges on this Mac.
public struct MachineDefaults: Sendable, Hashable {
    public var cores: Int
    public var memoryGB: Int
    public var diskGB: Int

    public static let coresDefault = 2, memoryDefault = 4, diskDefault = 64
    public static var hostCores: Int { max(2, ProcessInfo.processInfo.processorCount) }
    public static var hostMemoryGB: Int { max(4, Int(ProcessInfo.processInfo.physicalMemory / MachineLibrary.bytesPerGB)) }
    public static var coresRange: ClosedRange<Int> { 2...hostCores }
    public static var memoryRange: ClosedRange<Int> { 4...hostMemoryGB }
    public static let diskRange = 32...2048

    public init(cores: Int, memoryGB: Int, diskGB: Int) {
        self.cores = cores
        self.memoryGB = memoryGB
        self.diskGB = diskGB
    }

    /// The settings' values, each brought into its range on this Mac.
    public init(_ settings: SettingsFile) {
        cores = (settings.defaultVMCores ?? Self.coresDefault).clamped(to: Self.coresRange)
        memoryGB = (settings.defaultVMMemoryGB ?? Self.memoryDefault).clamped(to: Self.memoryRange)
        diskGB = (settings.defaultVMDiskGB ?? Self.diskDefault).clamped(to: Self.diskRange)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

/// A machine that runs: a user's machine, or the setup machine of an image.
@MainActor
@Observable
public final class MachineRun {
    public enum State: Sendable, Hashable { case starting, running, paused, stopping }

    /// The machine's id, or the image's for a setup.
    public let id: String
    public let isSetup: Bool
    public internal(set) var state: State = .starting
    public internal(set) var startedAt: Date
    /// The agent's status while it is connected.
    public internal(set) var agent: GuestAgentStatus?
    /// The guest's IP address, from the DHCP leases.
    public internal(set) var address: String?
    /// A setup restarting into macOS Recovery.
    public internal(set) var isRestarting = false
    public let guest: any GuestMachine
    var hasStopped = false
    var watcher: Task<Void, Never>?

    init(id: String, isSetup: Bool, guest: any GuestMachine, startedAt: Date) {
        self.id = id
        self.isSetup = isSetup
        self.guest = guest
        self.startedAt = startedAt
    }
}

/// The result of a shell command in a guest.
public struct ShellResult: Sendable, Hashable {
    public let exitStatus: Int
    public let timedOut: Bool
    public let stdout: String
    public let stderr: String
    public let truncated: Bool

    public init(exitStatus: Int, timedOut: Bool, stdout: String, stderr: String, truncated: Bool) {
        self.exitStatus = exitStatus
        self.timedOut = timedOut
        self.stdout = stdout
        self.stderr = stderr
        self.truncated = truncated
    }
}

/// The images and machines of the data folder and the machines that run: V2's engine for virtual machines
/// (docs/data.md › Virtual machines). At most 2 count at once: installs, setups and machines.
@MainActor
@Observable
public final class MachineHost {
    public static let maximumRunning = 2

    public private(set) var images: [ImageFile] = []
    public private(set) var machines: [MachineFile] = []
    /// An image's download or install, 0 to 1.
    public private(set) var progress: [String: Double] = [:]
    /// The size of the IPSW an image downloads, when ipsw.me gives it.
    public private(set) var downloadSizes: [String: Int64] = [:]
    public private(set) var runs: [String: MachineRun] = [:]
    /// Setup machines, by image id.
    public private(set) var setups: [String: MachineRun] = [:]
    /// Images whose install holds a place.
    public private(set) var installing: Set<String> = []
    public private(set) var versions: [MacOSVersion]?
    public private(set) var defaults: MachineDefaults
    /// A machine or setup that stopped with a failure: its id and the message, until `clearFailure`.
    public private(set) var failures: [String: String] = [:]
    public private(set) var isLoaded = false

    @ObservationIgnored public let library: MachineLibrary?
    @ObservationIgnored private let dataFolder: DataFolder?
    @ObservationIgnored private let backend: any MachineBackend
    @ObservationIgnored private let guestTools: GuestTools?
    @ObservationIgnored private let v2Folder: URL?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var installQueue: [String] = []
    /// Seconds between two looks at the DHCP leases, and how many.
    @ObservationIgnored var addressPoll: (interval: Duration, tries: Int) = (.seconds(3), 60)
    @ObservationIgnored var leases: (String) -> String? = { DHCPLeases.address(of: $0) }

    /// `v2Folder`: V2's `VirtualMachines/`, cloned in once; nil imports nothing (tests).
    public init(dataFolder: DataFolder?, backend: any MachineBackend = SystemMachineBackend(),
                guestTools: GuestTools? = .bundled(in: Bundle.main.bundleURL),
                v2Folder: URL? = MachineLibrary.v2Folder, now: @escaping () -> Date = ISODate.now) {
        self.dataFolder = dataFolder
        library = dataFolder.map { MachineLibrary(dataFolder: $0.url) }
        self.backend = backend
        self.guestTools = guestTools
        self.v2Folder = v2Folder
        self.now = now
        defaults = MachineDefaults(dataFolder?.readSettings() ?? SettingsFile())
    }

    public var supportsMachines: Bool { backend.supportsMachines }
    public var runningCount: Int { runs.count + setups.count + installing.count }
    public var canStartAnother: Bool { runningCount < Self.maximumRunning }

    public func image(_ id: String) -> ImageFile? { images.first { $0.id == id } }
    public func machine(_ id: String) -> MachineFile? { machines.first { $0.id == id } }

    // MARK: Loading

    /// Clones V2's images and machines in once, reads the folders, and fails the images an earlier quit
    /// interrupted.
    public func load() {
        guard let library else { return }
        if let v2Folder { library.importV2(from: v2Folder) }
        images = library.readImages()
        machines = library.readMachines()
        for index in images.indices where images[index].state == .downloading || images[index].state == .installing {
            images[index].state = .failed
            images[index].failure = "The app quit before the image was ready."
            try? FileManager.default.removeItem(at: library.folder(image: images[index].id).restoreImage)
            try? library.write(images[index])
        }
        isLoaded = true
    }

    public func clearFailure(_ id: String) { failures[id] = nil }

    // MARK: Images

    /// The macOS versions of ipsw.me; the list read last is kept.
    @discardableResult
    public func loadVersions() async throws(MachineError) -> [MacOSVersion] {
        do {
            let list = try await backend.versions()
            versions = list
            return list
        } catch {
            throw MachineError(.unavailable, error.message)
        }
    }

    /// A new image of a version: downloaded, then installed, in the background.
    @discardableResult
    public func addImage(build: String) async throws(MachineError) -> ImageFile {
        guard let library else { throw MachineError(.unavailable, "The app has no data folder.") }
        guard backend.supportsMachines else { throw .needsAppleSilicon }
        let list: [MacOSVersion]
        if let versions { list = versions } else { list = try await loadVersions() }
        guard let version = list.first(where: { $0.build == build }) else { throw MachineError(.notFound, "macOS build \(build) not found.") }
        let image = ImageFile(id: UUID().uuidString, version: version.version, build: version.build, state: .downloading, created: now())
        do {
            try library.write(image)
        } catch {
            throw MachineError(.internal, error.description)
        }
        images.append(image)
        progress[image.id] = 0
        if version.sizeBytes > 0 { downloadSizes[image.id] = version.sizeBytes }
        tasks[image.id] = Task { await self.provision(image.id, version) }
        return image
    }

    private func provision(_ id: String, _ version: MacOSVersion) async {
        guard let library else { return }
        let folder = library.folder(image: id)
        do {
            try await backend.download(version, to: folder.restoreImage) { value in
                Task { @MainActor in self.report(id, value, while: .downloading) }
            }
            try Task.checkCancellation()
            update(id) { $0.state = .installing }
            progress[id] = 0
            try await takePlace(forInstall: id)
            defer { installing.remove(id) }
            try await backend.install(folder, version: version.version, cores: defaults.cores, memoryGB: defaults.memoryGB) { value in
                Task { @MainActor in self.report(id, value, while: .installing) }
            }
            try? FileManager.default.removeItem(at: folder.restoreImage)
            try Task.checkCancellation()
            update(id) { $0.state = .needsSetup }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: folder.restoreImage)
        } catch {
            try? FileManager.default.removeItem(at: folder.restoreImage)
            if !Task.isCancelled {
                update(id) {
                    $0.state = .failed
                    $0.failure = MachineFailure.message(of: error)
                }
            }
        }
        progress[id] = nil
        downloadSizes[id] = nil
        tasks[id] = nil
    }

    private func report(_ id: String, _ value: Double, while state: ImageFile.State) {
        guard image(id)?.state == state else { return }
        progress[id] = max(0, min(1, value))
    }

    /// Waits for a place, installs in the order they began to wait.
    private func takePlace(forInstall id: String) async throws {
        installQueue.append(id)
        defer { installQueue.removeAll { $0 == id } }
        while !canStartAnother || installQueue.first != id {
            try await Task.sleep(for: .seconds(1))
        }
        installing.insert(id)
    }

    private func update(_ id: String, _ change: (inout ImageFile) -> Void) {
        guard let library, let index = images.firstIndex(where: { $0.id == id }) else { return }
        change(&images[index])
        try? library.write(images[index])
    }

    /// The guest account: an absent value keeps the stored one, an empty one removes it. The user name is
    /// trimmed; the password is stored as given.
    public func setAccount(_ id: String, userName: String?, password: String?) throws(MachineError) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { throw MachineError(.notFound, "Image \(id) not found.") }
        if userName?.contains(where: \.isNewline) == true { throw MachineError(.invalid, "userName: use one line.") }
        if password?.contains(where: \.isNewline) == true { throw MachineError(.invalid, "password: use one line.") }
        var image = images[index]
        if let userName {
            let trimmed = userName.trimmingCharacters(in: .whitespaces)
            image.userName = trimmed.isEmpty ? nil : trimmed
        }
        if let password { image.password = password.isEmpty ? nil : password }
        guard image != images[index], let library else { return }
        do {
            try library.write(image)
        } catch {
            throw MachineError(.internal, error.description)
        }
        images[index] = image
    }

    /// Ends the image's download, install or setup, deletes its machines, then its folder (not to the Trash:
    /// a disk there would keep its space).
    public func deleteImage(_ id: String) async throws(MachineError) {
        guard let library, image(id) != nil else { throw MachineError(.notFound, "Image \(id) not found.") }
        tasks[id]?.cancel()
        if let setup = setups[id] {
            setup.isRestarting = false
            await setup.guest.stop()
            ended(setup)
        }
        for machine in machines where machine.imageID == id {
            try? await deleteMachine(machine.id)
        }
        do {
            try FileManager.default.removeItem(at: library.folder(image: id).url)
        } catch {
            throw MachineError(.internal, "The image could not be deleted: \(MachineFailure.message(of: error))")
        }
        images.removeAll { $0.id == id }
        progress[id] = nil
    }

    // MARK: Setup

    public var sharedFolder: URL? { dataFolder?.url.appendingPathComponent("Runtime/guest", isDirectory: true) }

    /// Boots the image's own disk with the agent's files shared, or does nothing when its setup runs.
    public func startSetup(_ id: String) async throws(MachineError) {
        guard setups[id] == nil else { return }
        guard let library, let image = image(id) else { throw MachineError(.notFound, "Image \(id) not found.") }
        guard backend.supportsMachines else { throw .needsAppleSilicon }
        guard image.state == .needsSetup else { throw MachineError(.conflict, "The image is not waiting for setup.") }
        guard canStartAnother else { throw .tooMany }
        guard let guestTools, let sharedFolder else { throw MachineError(.unavailable, "The guest agent is missing from the app bundle.") }
        do {
            try guestTools.fill(sharedFolder)
        } catch {
            throw MachineError(.internal, MachineFailure.message(of: error))
        }
        let guest: any GuestMachine
        do {
            guest = try backend.makeMachine(library.folder(image: id), cores: defaults.cores, memoryGB: defaults.memoryGB, macAddress: nil,
                                            sharedFolder: sharedFolder)
        } catch {
            throw MachineError(.unavailable, MachineFailure.message(of: error))
        }
        let run = MachineRun(id: id, isSetup: true, guest: guest, startedAt: now())
        setups[id] = run
        try await boot(run, recovery: false)
    }

    /// Shuts the guest down (through the agent, else the framework's stop request, which macOS asks about),
    /// stops it after 30 seconds, then starts it into macOS Recovery.
    public func restartInRecovery(_ id: String) async throws(MachineError) {
        guard let run = setups[id], run.state == .running, !run.isRestarting else { throw MachineError(.conflict, "The setup is not running.") }
        run.isRestarting = true
        defer { run.isRestarting = false }
        var asked = false
        if run.agent != nil, (try? await run.guest.shutDownGuest()) != nil { asked = true }
        if !asked { asked = (try? run.guest.requestStop()) != nil }
        var stopped = false
        if asked { stopped = await waitForStop(run, seconds: 30) }
        if !stopped { await run.guest.stop() }
        guard setups[id] === run else { return }
        run.hasStopped = false
        run.agent = nil
        try await boot(run, recovery: true)
    }

    /// With the agent connected and SIP off: shuts the guest down, stops it after 60 seconds, and sets the
    /// image Ready.
    public func finishSetup(_ id: String) async throws(MachineError) {
        guard let run = setups[id] else { throw MachineError(.conflict, "The setup is not running.") }
        guard run.agent?.sip == .disabled else { throw MachineError(.conflict, "The agent is not connected with SIP off.") }
        run.state = .stopping
        if !(await shutDownThroughAgent(run, seconds: 60)) { await run.guest.stop() }
        ended(run)
        update(id) { $0.state = .ready }
    }

    /// Ends a setup: through the agent within 30 seconds, otherwise at once. The image stays waiting for setup.
    public func stopSetup(_ id: String) async {
        guard let run = setups[id] else { return }
        if run.isRestarting {
            await run.guest.stop()
            ended(run)
            return
        }
        guard run.state != .stopping else { return }
        run.state = .stopping
        if !(await shutDownThroughAgent(run, seconds: 30)) { await run.guest.stop() }
        ended(run)
    }

    // MARK: Machines

    /// Creates a machine of a Ready image, its disk a clone grown to `diskGB`, then starts it.
    @discardableResult
    public func createMachine(name: String, imageID: String, cores: Int, memoryGB: Int, diskGB: Int) async throws(MachineError) -> MachineFile {
        guard let library else { throw MachineError(.unavailable, "The app has no data folder.") }
        guard backend.supportsMachines else { throw .needsAppleSilicon }
        let name = try Self.checkedName(name)
        guard let image = image(imageID) else { throw MachineError(.notFound, "Image \(imageID) not found.") }
        guard image.state == .ready else { throw MachineError(.conflict, "The image is not Ready.") }
        try Self.check(cores: cores, memoryGB: memoryGB, diskGB: diskGB, minimumDisk: library.folder(image: imageID).diskGB)
        guard canStartAnother else { throw .tooMany }
        var machine: MachineFile
        do {
            machine = try library.createMachine(named: name, image: image, cores: cores, memoryGB: memoryGB, diskGB: diskGB, now: now())
        } catch {
            throw MachineError(.internal, "The virtual machine could not be created: \(error.description)")
        }
        machine.macAddress = MachineConfiguration.newMACAddress()
        try? library.write(machine)
        machines.append(machine)
        try await start(machine.id)
        return machine
    }

    public func start(_ id: String) async throws(MachineError) {
        guard let library, var machine = machine(id) else { throw MachineError(.notFound, "Virtual machine \(id) not found.") }
        guard runs[id] == nil else { throw MachineError(.conflict, "The virtual machine is running.") }
        guard backend.supportsMachines else { throw .needsAppleSilicon }
        guard canStartAnother else { throw .tooMany }
        if machine.macAddress == nil {
            machine.macAddress = MachineConfiguration.newMACAddress()
            try? library.write(machine)
            replace(machine)
        }
        let guest: any GuestMachine
        do {
            guest = try backend.makeMachine(library.folder(machine: id), cores: machine.cores, memoryGB: machine.memoryGB,
                                            macAddress: machine.macAddress, sharedFolder: nil)
        } catch {
            throw MachineError(.unavailable, MachineFailure.message(of: error))
        }
        let run = MachineRun(id: id, isSetup: false, guest: guest, startedAt: now())
        runs[id] = run
        try await boot(run, recovery: false)
        if let mac = machine.macAddress { watchAddress(run, mac: mac) }
    }

    /// Shuts the guest down through the agent, waiting up to 60 seconds, else stops it at once.
    public func stop(_ id: String) async throws(MachineError) {
        guard let run = runs[id] else { throw MachineError(.conflict, "The virtual machine is not running.") }
        guard run.state != .stopping else {
            _ = await waitForStop(run, seconds: 90)
            return
        }
        let wasPaused = run.state == .paused
        run.state = .stopping
        var stopped = false
        if !wasPaused { stopped = await shutDownThroughAgent(run, seconds: 60) }
        if !stopped { await run.guest.stop() }
        ended(run)
    }

    public func pause(_ id: String) async throws(MachineError) {
        guard let run = runs[id], run.state == .running else { throw MachineError(.conflict, "The virtual machine is not running.") }
        do {
            try await run.guest.pause()
            run.state = .paused
        } catch {
            throw MachineError(.unavailable, MachineFailure.message(of: error))
        }
    }

    public func resume(_ id: String) async throws(MachineError) {
        guard let run = runs[id], run.state == .paused else { throw MachineError(.conflict, "The virtual machine is not paused.") }
        do {
            try await run.guest.resume()
            run.state = .running
        } catch {
            throw MachineError(.unavailable, MachineFailure.message(of: error))
        }
    }

    /// A stopped machine's name, cores, memory and disk; a larger disk is grown, and the guest's container
    /// grows at the next start.
    @discardableResult
    public func updateMachine(_ id: String, name: String, cores: Int, memoryGB: Int, diskGB: Int) throws(MachineError) -> MachineFile {
        guard let library, var machine = machine(id) else { throw MachineError(.notFound, "Virtual machine \(id) not found.") }
        guard runs[id] == nil else { throw MachineError(.conflict, "The virtual machine is running.") }
        let name = try Self.checkedName(name)
        let folder = library.folder(machine: id)
        let current = machine.diskGB ?? folder.diskGB
        try Self.check(cores: cores, memoryGB: memoryGB, diskGB: diskGB, minimumDisk: current)
        if diskGB > current {
            do {
                _ = try GuestDisk.grow(folder.disk, to: UInt64(diskGB) * MachineLibrary.bytesPerGB)
            } catch {
                throw MachineError(.internal, "The virtual machine could not be changed: \(MachineFailure.message(of: error))")
            }
            machine.growContainer = true
        }
        machine.name = name
        machine.cores = cores
        machine.memoryGB = memoryGB
        machine.diskGB = diskGB
        do {
            try library.write(machine)
        } catch {
            throw MachineError(.internal, "The virtual machine could not be changed: \(error.description)")
        }
        replace(machine)
        return machine
    }

    /// Stops a running machine at once, then deletes its folder (not to the Trash).
    public func deleteMachine(_ id: String) async throws(MachineError) {
        guard let library, machine(id) != nil else { throw MachineError(.notFound, "Virtual machine \(id) not found.") }
        if let run = runs[id] {
            await run.guest.stop()
            ended(run)
        }
        do {
            try FileManager.default.removeItem(at: library.folder(machine: id).url)
        } catch {
            throw MachineError(.internal, "The virtual machine could not be deleted: \(MachineFailure.message(of: error))")
        }
        machines.removeAll { $0.id == id }
        failures[id] = nil
    }

    public func setDefaults(_ values: MachineDefaults) throws(MachineError) {
        try Self.check(cores: values.cores, memoryGB: values.memoryGB, diskGB: values.diskGB, minimumDisk: MachineDefaults.diskRange.lowerBound)
        guard let dataFolder else { throw MachineError(.unavailable, "The app has no data folder.") }
        var settings = dataFolder.readSettings()
        settings.defaultVMCores = values.cores == MachineDefaults.coresDefault ? nil : values.cores
        settings.defaultVMMemoryGB = values.memoryGB == MachineDefaults.memoryDefault ? nil : values.memoryGB
        settings.defaultVMDiskGB = values.diskGB == MachineDefaults.diskDefault ? nil : values.diskGB
        do {
            try dataFolder.writeSettings(settings)
        } catch {
            throw MachineError(.internal, error.description)
        }
        defaults = values
    }

    /// At quit: every machine and setup stops at once, every download and install ends.
    public func stopAll() {
        for task in tasks.values { task.cancel() }
        for run in Array(runs.values) + Array(setups.values) {
            let guest = run.guest
            Task { await guest.stop() }
        }
    }

    // MARK: The guest agent

    /// One request to a running machine's agent (a setup's too, by its image id).
    public func agentRequest(_ id: String, method: String, params: [String: JSONValue] = [:], data: Data = Data(),
                             timeout: Duration = .seconds(60)) async throws(MachineError) -> GuestAgentResponse {
        guard let run = runs[id] ?? setups[id], run.state == .running else { throw MachineError(.conflict, "The virtual machine is not running.") }
        guard run.agent != nil else { throw MachineError(.unavailable, GuestAgentError.disconnected.localizedDescription) }
        do {
            return try await run.guest.agentRequest(method, params: params, data: data, timeout: timeout)
        } catch {
            throw MachineError(.unavailable, MachineFailure.message(of: error))
        }
    }

    /// `/bin/zsh -lc <command>` in the guest's home folder, as the account or as root.
    public func shell(_ id: String, command: String, asRoot: Bool = false, timeout: Int = 60) async throws(MachineError) -> ShellResult {
        let seconds = timeout.clamped(to: 1...3600)
        let response = try await agentRequest(id, method: "exec", params: ["command": .string(command), "asRoot": .bool(asRoot), "timeout": .int(seconds)],
                                              timeout: .seconds(seconds + 10))
        let result = response.result
        return ShellResult(exitStatus: result["exitStatus"]?.intValue ?? -1, timedOut: result["timedOut"]?.boolValue ?? false,
                           stdout: result["stdout"]?.stringValue ?? "", stderr: result["stderr"]?.stringValue ?? "",
                           truncated: result["truncated"]?.boolValue ?? false)
    }

    /// The guest's main display, as a PNG.
    public func screenshot(_ id: String) async throws(MachineError) -> Data {
        let response = try await agentRequest(id, method: "screenshot", timeout: .seconds(30))
        guard !response.data.isEmpty else { throw MachineError(.unavailable, "The agent sent no screenshot.") }
        return response.data
    }

    // MARK: Running

    private func boot(_ run: MachineRun, recovery: Bool) async throws(MachineError) {
        run.guest.events = { [weak self, weak run] event in
            guard let self, let run else { return }
            self.handle(event, of: run)
        }
        run.state = .starting
        do {
            try await run.guest.start(recovery: recovery)
        } catch {
            await run.guest.stop()
            ended(run)
            throw MachineError(.unavailable, MachineFailure.message(of: error))
        }
        guard !run.hasStopped else { return }
        run.state = .running
        if !recovery { run.startedAt = run.isSetup && run.startedAt < now() ? run.startedAt : now() }
    }

    private func handle(_ event: GuestMachineEvent, of run: MachineRun) {
        switch event {
        case .agentConnected(let status):
            run.agent = status
            if !run.isSetup { growContainerIfNeeded(run) }
        case .agentDisconnected:
            run.agent = nil
        case .stopped(let error):
            run.hasStopped = true
            if run.isRestarting { return }
            if let error { failures[run.id] = error }
            ended(run)
        }
    }

    /// The machine left the list of those that run.
    private func ended(_ run: MachineRun) {
        run.hasStopped = true
        run.watcher?.cancel()
        run.agent = nil
        if run.isSetup {
            if setups[run.id] === run { setups[run.id] = nil }
        } else if runs[run.id] === run {
            runs[run.id] = nil
        }
    }

    /// Asks the agent to shut the guest down; whether the machine stopped within `seconds`.
    private func shutDownThroughAgent(_ run: MachineRun, seconds: Int) async -> Bool {
        guard run.agent != nil else { return false }
        do {
            try await run.guest.shutDownGuest()
        } catch {
            return false
        }
        return await waitForStop(run, seconds: seconds)
    }

    /// Whether the machine stopped within `seconds`.
    private func waitForStop(_ run: MachineRun, seconds: Int) async -> Bool {
        for _ in 0..<(seconds * 4) {
            if run.hasStopped { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return run.hasStopped
    }

    private func watchAddress(_ run: MachineRun, mac: String) {
        let (interval, tries) = addressPoll
        run.watcher = Task { [weak self, weak run] in
            for _ in 0..<tries {
                try? await Task.sleep(for: interval)
                guard let self, let run, !Task.isCancelled, !run.hasStopped else { return }
                if let address = self.leases(mac) {
                    run.address = address
                    return
                }
            }
        }
    }

    /// The first start after a disk grew: the guest's container grows over the free space, as root.
    private func growContainerIfNeeded(_ run: MachineRun) {
        guard let machine = machine(run.id), machine.growContainer else { return }
        Task {
            let result = try? await shell(run.id, command: GuestDisk.growContainerCommand, asRoot: true, timeout: GuestDisk.growContainerTimeout)
            guard result?.exitStatus == 0, var machine = self.machine(run.id), let library else { return }
            machine.growContainer = false
            try? library.write(machine)
            replace(machine)
        }
    }

    private func replace(_ machine: MachineFile) {
        if let index = machines.firstIndex(where: { $0.id == machine.id }) { machines[index] = machine }
    }

    // MARK: Rules

    static func checkedName(_ name: String) throws(MachineError) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard (1...100).contains(trimmed.count), !trimmed.contains(where: \.isNewline) else {
            throw MachineError(.invalid, "name: use 1 to 100 characters on one line.")
        }
        return trimmed
    }

    static func check(cores: Int, memoryGB: Int, diskGB: Int, minimumDisk: Int) throws(MachineError) {
        for (name, value, range) in [("cores", cores, MachineDefaults.coresRange), ("memoryGB", memoryGB, MachineDefaults.memoryRange),
                                     ("diskGB", diskGB, max(MachineDefaults.diskRange.lowerBound, minimumDisk)...MachineDefaults.diskRange.upperBound)]
            where !range.contains(value) {
            throw MachineError(.invalid, "\(name): use a number from \(range.lowerBound) to \(range.upperBound).")
        }
    }
}
