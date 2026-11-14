import Foundation
import MCPKit
import Virtualization

/// What a running machine tells its owner.
public enum GuestMachineEvent: Sendable, Hashable {
    /// The guest agent connected, or reported a new status.
    case agentConnected(GuestAgentStatus)
    case agentDisconnected
    /// The machine stopped without `stop()` asking: the guest shut down (`error` nil) or the machine failed.
    case stopped(error: String?)
}

/// One machine booting the disk of a folder. `SystemMachineBackend` makes the Virtualization framework's; tests
/// make stand-ins. On the main actor, as the framework's machine is.
@MainActor
public protocol GuestMachine: AnyObject {
    /// The framework's machine, for the screen's view; nil for a stand-in.
    var virtualMachine: VZVirtualMachine? { get }
    var events: ((GuestMachineEvent) -> Void)? { get set }
    func start(recovery: Bool) async throws
    /// Stops at once, as a power cut does. No `stopped` event follows.
    func stop() async
    func pause() async throws
    func resume() async throws
    /// Asks the connected agent to shut the guest down; `stopped` follows once it has.
    func shutDownGuest() async throws
    func agentRequest(_ method: String, params: [String: JSONValue], data: Data, timeout: Duration) async throws -> GuestAgentResponse
    /// The framework's stop request, as a Mac's power button: macOS asks in the guest.
    func requestStop() throws
}

/// What the app reaches for virtual machines: ipsw.me, Apple's download server and the Virtualization
/// framework. Tests use a stand-in.
@MainActor
public protocol MachineBackend: AnyObject {
    var supportsMachines: Bool { get }
    func versions() async throws(MacOSVersions.ListError) -> [MacOSVersion]
    /// Downloads the IPSW to `file`; a failed download leaves no file.
    func download(_ version: MacOSVersion, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws
    func install(_ folder: MachineFolder, version: String, cores: Int, memoryGB: Int, progress: @escaping @Sendable (Double) -> Void) async throws
    func makeMachine(_ folder: MachineFolder, cores: Int, memoryGB: Int, macAddress: String?, sharedFolder: URL?) throws -> any GuestMachine
}

@MainActor
public final class SystemMachineBackend: MachineBackend {
    public init() {}

    public var supportsMachines: Bool { MachineConfiguration.isSupported }

    public func versions() async throws(MacOSVersions.ListError) -> [MacOSVersion] {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        return try await MacOSVersions.fetch(session: session)
    }

    public func download(_ version: MacOSVersion, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let url = URL(string: version.url) else { throw MachineFailure("The download failed: the URL of the IPSW is not valid.") }
        try await IPSWDownload(file: file, version: version, progress: progress).run(url)
    }

    public func install(_ folder: MachineFolder, version: String, cores: Int, memoryGB: Int,
                        progress: @escaping @Sendable (Double) -> Void) async throws {
        try await MachineInstaller.install(folder, version: version, cores: cores, memoryGB: memoryGB, progress: progress)
    }

    public func makeMachine(_ folder: MachineFolder, cores: Int, memoryGB: Int, macAddress: String?, sharedFolder: URL?) throws -> any GuestMachine {
        try MacGuestMachine(MachineConfiguration.make(folder, cores: cores, memoryGB: memoryGB, macAddress: macAddress, sharedFolder: sharedFolder))
    }
}

/// A macOS machine of the Virtualization framework, with the listener of its socket device for the agent.
@MainActor
final class MacGuestMachine: NSObject, GuestMachine, VZVirtualMachineDelegate, VZVirtioSocketListenerDelegate {
    private let machine: VZVirtualMachine
    private let listener = VZVirtioSocketListener()
    /// One connection at a time, the newest.
    private(set) var agent: GuestAgentConnection?
    private var connectionToken: UUID?
    /// From `stop()` to the next start: the stop the owner asked for sends no event.
    private var stopRequested = false
    /// Starts and stops run one after the other: the framework stops no machine that is starting.
    private var lastOperation: Task<Void, Never>?

    var events: ((GuestMachineEvent) -> Void)?
    var virtualMachine: VZVirtualMachine? { machine }

    init(_ configuration: VZVirtualMachineConfiguration) {
        machine = VZVirtualMachine(configuration: configuration)
        super.init()
        machine.delegate = self
        listener.delegate = self
        (machine.socketDevices.first as? VZVirtioSocketDevice)?.setSocketListener(listener, forPort: MachineConfiguration.agentPort)
    }

    func start(recovery: Bool) async throws {
        try await inOrder { [self] in
            stopRequested = false
            let options = VZMacOSVirtualMachineStartOptions()
            options.startUpFromMacOSRecovery = recovery
            try await machine.start(options: options)
        }
    }

    func stop() async {
        stopRequested = true
        dropAgent()
        try? await inOrder { [self] in
            stopRequested = true
            guard machine.canStop else { return }
            try? await machine.stop()
        }
    }

    func pause() async throws {
        guard machine.canPause else { throw MachineFailure("The virtual machine cannot be paused now.") }
        try await machine.pause()
    }

    func resume() async throws {
        guard machine.canResume else { throw MachineFailure("The virtual machine cannot be resumed now.") }
        try await machine.resume()
    }

    func shutDownGuest() async throws {
        guard let agent else { throw GuestAgentError.disconnected }
        try await agent.shutDownGuest()
    }

    func agentRequest(_ method: String, params: [String: JSONValue], data: Data, timeout: Duration) async throws -> GuestAgentResponse {
        guard let agent else { throw GuestAgentError.disconnected }
        return try await agent.request(method, params: params, data: data, timeout: timeout)
    }

    func requestStop() throws {
        guard machine.canRequestStop else { throw MachineFailure("The virtual machine takes no stop request.") }
        try machine.requestStop()
    }

    private func inOrder(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = lastOperation
        let task = Task { @MainActor in
            await previous?.value
            try await operation()
        }
        lastOperation = Task { @MainActor in _ = try? await task.value }
        try await task.value
    }

    // MARK: VZVirtualMachineDelegate, on the main queue

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { machineStopped(error: nil) }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        let message = MachineFailure.message(of: error)
        MainActor.assumeIsolated { machineStopped(error: message) }
    }

    private func machineStopped(error: String?) {
        dropAgent()
        guard !stopRequested else { return }
        events?(.stopped(error: error))
    }

    // MARK: VZVirtioSocketListenerDelegate, on the main queue

    nonisolated func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                              from socketDevice: VZVirtioSocketDevice) -> Bool {
        nonisolated(unsafe) let connection = connection
        MainActor.assumeIsolated { accept(connection) }
        return true
    }

    /// A new connection replaces the one held. The framework's connection object lives until the agent's
    /// connection has ended, and is closed on the main queue.
    private func accept(_ connection: VZVirtioSocketConnection) {
        dropAgent()
        let token = UUID()
        connectionToken = token
        let descriptor = connection.fileDescriptor
        let holder = SocketConnectionHolder(connection)
        let owner = WeakMachine(self)
        Task {
            let opened = try? await GuestAgentConnection.open(descriptor: descriptor, closer: { holder.close() },
                                                              onClose: { Task { @MainActor in owner.machine?.agentClosed(token) } })
            guard let machine = owner.machine, let opened else { return }
            guard machine.connectionToken == token else {
                opened.close()
                return
            }
            machine.agent = opened
            machine.events?(.agentConnected(opened.status))
        }
    }

    private final class WeakMachine: @unchecked Sendable {
        weak var machine: MacGuestMachine?
        init(_ machine: MacGuestMachine) { self.machine = machine }
    }

    private func agentClosed(_ token: UUID) {
        guard connectionToken == token else { return }
        connectionToken = nil
        let wasConnected = agent != nil
        agent = nil
        if wasConnected { events?(.agentDisconnected) }
    }

    private func dropAgent() {
        connectionToken = nil
        guard let agent else { return }
        self.agent = nil
        agent.close()
        events?(.agentDisconnected)
    }

    private final class SocketConnectionHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var connection: VZVirtioSocketConnection?

        init(_ connection: VZVirtioSocketConnection) { self.connection = connection }

        func close() {
            let connection = lock.withLock { () -> VZVirtioSocketConnection? in
                defer { self.connection = nil }
                return self.connection
            }
            guard let connection else { return }
            nonisolated(unsafe) let closing = connection
            DispatchQueue.main.async { closing.close() }
        }
    }
}

/// The guest agent and the install script of the app bundle, copied into the folder shared with the setup
/// machine: `Contents/Helpers/HephaestusAgent` and `Contents/Resources/install-agent.sh`.
public struct GuestTools: Sendable, Hashable {
    public var agent: URL
    public var installScript: URL

    public static let agentName = "hephaestus-agent"
    public static let installScriptName = "install.sh"
    /// Where a macOS guest shows the shared folder.
    public static let guestMountPoint = "/Volumes/My Shared Files"
    /// What the user types in the guest's Terminal, the setup's third step.
    public static let installCommand = "sh \"\(guestMountPoint)/\(installScriptName)\""

    public init(agent: URL, installScript: URL) {
        self.agent = agent
        self.installScript = installScript
    }

    /// Nil when the bundle lacks one of the two files.
    public static func bundled(in bundle: URL) -> GuestTools? {
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let tools = GuestTools(agent: contents.appendingPathComponent("Helpers/HephaestusAgent"),
                               installScript: contents.appendingPathComponent("Resources/install-agent.sh"))
        guard FileManager.default.fileExists(atPath: tools.agent.path), FileManager.default.fileExists(atPath: tools.installScript.path) else { return nil }
        return tools
    }

    /// Fills `folder` with `install.sh` and `hephaestus-agent`, replacing older copies.
    public func fill(_ folder: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        for (source, name, mode) in [(agent, Self.agentName, 0o755), (installScript, Self.installScriptName, 0o644)] {
            let destination = folder.appendingPathComponent(name)
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.copyItem(at: source, to: destination)
            try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: destination.path)
        }
    }
}
