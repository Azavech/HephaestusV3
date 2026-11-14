import Foundation
import MachineData
import Observation
import SwiftUI
import ToolsFoundation
import Virtualization

/// Where the machines and images come from, and what acts on them: `LiveMachineStore` on the data folder,
/// `SampleMachineStore` for the previews and tests.
protocol MachineStore: AnyObject {
    /// The Mac's virtual machines, in the order the list shows them.
    var machines: [VirtualMachine] { get }
    /// The system images new machines start from, in the order the list shows them.
    var images: [MachineImage] { get }
    /// Snapshots are sample data only: the machines of the data folder have none yet.
    var offersSnapshots: Bool { get }
    var defaults: MachineDefaults { get }
    /// Fewer than 2 machines, setups and installs run.
    var canStartAnother: Bool { get }
    /// A machine or setup that stopped with a failure, by id.
    var failures: [String: String] { get }
    func clearFailure(_ id: String)

    func versions() async throws(MachineError) -> [MacOSVersion]
    func addImage(build: String) async throws(MachineError) -> MachineImage.ID
    func deleteImage(_ id: MachineImage.ID) async throws(MachineError)
    func setAccount(_ id: MachineImage.ID, userName: String?, password: String?) throws(MachineError)
    func password(ofImage id: MachineImage.ID) -> String?

    func startSetup(_ id: MachineImage.ID) async throws(MachineError)
    func restartInRecovery(_ id: MachineImage.ID) async throws(MachineError)
    func finishSetup(_ id: MachineImage.ID) async throws(MachineError)
    func stopSetup(_ id: MachineImage.ID) async

    func createMachine(name: String, imageID: MachineImage.ID, cores: Int, memoryGB: Int, diskGB: Int) async throws(MachineError) -> VirtualMachine.ID
    func start(_ id: VirtualMachine.ID) async throws(MachineError)
    func stop(_ id: VirtualMachine.ID) async throws(MachineError)
    func pause(_ id: VirtualMachine.ID) async throws(MachineError)
    func resume(_ id: VirtualMachine.ID) async throws(MachineError)
    func updateMachine(_ id: VirtualMachine.ID, name: String, cores: Int, memoryGB: Int, diskGB: Int) throws(MachineError)
    func deleteMachine(_ id: VirtualMachine.ID) async throws(MachineError)
    func setDefaults(_ values: MachineDefaults) throws(MachineError)
    func shell(_ id: VirtualMachine.ID, command: String, asRoot: Bool) async throws(MachineError) -> ShellResult

    /// The framework's machine of a running machine, or of an image's setup, for its screen; nil for samples.
    func screen(_ id: String) -> VZVirtualMachine?
    /// The smallest disk of a machine of the image, in GB.
    func minimumDiskGB(ofImage id: MachineImage.ID) -> Int
}

extension EnvironmentValues {
    /// The app's machines; nil in previews, which use the sample store.
    @Entry public var machineStore: LiveMachineStore?
}

/// The machines and images of the data folder, through the machine host (docs/architecture.md › MachineData).
@MainActor
public final class LiveMachineStore: MachineStore {
    public let host: MachineHost

    public init(host: MachineHost) {
        self.host = host
    }

    var machines: [VirtualMachine] {
        host.machines.map { file in
            let run = host.runs[file.id]
            let state: VirtualMachine.State = switch run?.state {
            case nil: .stopped
            case .starting?: .starting
            case .running?: .running
            case .paused?: .paused
            case .stopping?: .stopping
            }
            let diskGB = file.diskGB ?? host.library?.folder(machine: file.id).diskGB ?? 0
            return VirtualMachine(id: file.id, name: file.name, system: .macOS, systemVersion: "macOS \(file.version)", state: state,
                                  cores: file.cores, memoryGB: file.memoryGB, diskGB: diskGB, address: run?.address, projectID: file.projectID,
                                  cpuUsage: nil, snapshots: [], imageID: file.imageID, agentConnected: run?.agent != nil, startedAt: run?.startedAt)
        }
    }

    var images: [MachineImage] {
        host.images.map { file in
            let progress = host.progress[file.id] ?? 0
            let state: MachineImage.State = switch file.state {
            case .downloading: .downloading(progress: progress)
            case .installing: .installing(progress: progress)
            case .needsSetup: .needsSetup
            case .ready: .ready
            case .failed: .failed(file.failure ?? "")
            }
            let bytes = file.state == .downloading
                ? Double(host.downloadSizes[file.id] ?? 0) : Double(host.library?.folder(image: file.id).bytesOnDisk ?? 0)
            let setup = host.setups[file.id].map { run in
                ImageSetup(state: run.state == .starting ? .starting : run.state == .stopping ? .stopping : .running,
                           agentConnected: run.agent != nil, sipOff: run.agent?.sip == .disabled, isRestarting: run.isRestarting,
                           startedAt: run.startedAt)
            }
            return MachineImage(id: file.id, name: "macOS \(file.version)", system: .macOS, sizeGB: bytes / Double(MachineLibrary.bytesPerGB),
                                state: state, build: file.build, userName: file.userName, hasPassword: !(file.password ?? "").isEmpty, setup: setup)
        }
    }

    var offersSnapshots: Bool { false }
    var defaults: MachineDefaults { host.defaults }
    var canStartAnother: Bool { host.canStartAnother }
    var failures: [String: String] { host.failures }
    func clearFailure(_ id: String) { host.clearFailure(id) }

    func versions() async throws(MachineError) -> [MacOSVersion] {
        if let versions = host.versions { return versions }
        return try await host.loadVersions()
    }

    func addImage(build: String) async throws(MachineError) -> MachineImage.ID { try await host.addImage(build: build).id }
    func deleteImage(_ id: MachineImage.ID) async throws(MachineError) { try await host.deleteImage(id) }
    func setAccount(_ id: MachineImage.ID, userName: String?, password: String?) throws(MachineError) {
        try host.setAccount(id, userName: userName, password: password)
    }
    func password(ofImage id: MachineImage.ID) -> String? { host.image(id)?.password }
    func startSetup(_ id: MachineImage.ID) async throws(MachineError) { try await host.startSetup(id) }
    func restartInRecovery(_ id: MachineImage.ID) async throws(MachineError) { try await host.restartInRecovery(id) }
    func finishSetup(_ id: MachineImage.ID) async throws(MachineError) { try await host.finishSetup(id) }
    func stopSetup(_ id: MachineImage.ID) async { await host.stopSetup(id) }

    func createMachine(name: String, imageID: MachineImage.ID, cores: Int, memoryGB: Int, diskGB: Int) async throws(MachineError) -> VirtualMachine.ID {
        try await host.createMachine(name: name, imageID: imageID, cores: cores, memoryGB: memoryGB, diskGB: diskGB).id
    }
    func start(_ id: VirtualMachine.ID) async throws(MachineError) { try await host.start(id) }
    func stop(_ id: VirtualMachine.ID) async throws(MachineError) { try await host.stop(id) }
    func pause(_ id: VirtualMachine.ID) async throws(MachineError) { try await host.pause(id) }
    func resume(_ id: VirtualMachine.ID) async throws(MachineError) { try await host.resume(id) }
    func updateMachine(_ id: VirtualMachine.ID, name: String, cores: Int, memoryGB: Int, diskGB: Int) throws(MachineError) {
        try host.updateMachine(id, name: name, cores: cores, memoryGB: memoryGB, diskGB: diskGB)
    }
    func deleteMachine(_ id: VirtualMachine.ID) async throws(MachineError) { try await host.deleteMachine(id) }
    func setDefaults(_ values: MachineDefaults) throws(MachineError) { try host.setDefaults(values) }
    func shell(_ id: VirtualMachine.ID, command: String, asRoot: Bool) async throws(MachineError) -> ShellResult {
        try await host.shell(id, command: command, asRoot: asRoot)
    }

    func screen(_ id: String) -> VZVirtualMachine? { (host.runs[id] ?? host.setups[id])?.guest.virtualMachine }

    func minimumDiskGB(ofImage id: MachineImage.ID) -> Int {
        max(MachineDefaults.diskRange.lowerBound, host.library?.folder(image: id).diskGB ?? 0)
    }
}

/// The sample machines and images, or others for a preview; its actions change them in memory.
@Observable
final class SampleMachineStore: MachineStore {
    private(set) var machines: [VirtualMachine]
    private(set) var images: [MachineImage]
    let offersSnapshots = true
    private(set) var defaults = MachineDefaults(cores: 2, memoryGB: 4, diskGB: 64)
    private(set) var failures: [String: String] = [:]
    private var passwords: [String: String] = [:]
    /// The samples were designed with three machines that aren't stopped: they apply the limit of 2 only when asked.
    private let enforcesLimit: Bool

    init(machines: [VirtualMachine] = VirtualMachine.samples, images: [MachineImage] = MachineImage.samples, failures: [String: String] = [:],
         enforcesLimit: Bool = false) {
        self.machines = machines
        self.images = images
        self.failures = failures
        self.enforcesLimit = enforcesLimit
    }

    var canStartAnother: Bool {
        !enforcesLimit || machines.count { $0.state != .stopped } + images.count { $0.setup != nil } < MachineHost.maximumRunning
    }

    func clearFailure(_ id: String) { failures[id] = nil }

    func versions() async throws(MachineError) -> [MacOSVersion] {
        [MacOSVersion(version: "27.3", build: "27D50", url: "https://example.com/27.3.ipsw", sizeBytes: 19_000_000_000, sha256: nil),
         MacOSVersion(version: "27.2", build: "27C61", url: "https://example.com/27.2.ipsw", sizeBytes: 18_400_000_000, sha256: nil)]
    }

    func addImage(build: String) async throws(MachineError) -> MachineImage.ID {
        let id = "image-\(build)"
        images.append(MachineImage(id: id, name: "macOS \(build)", system: .macOS, sizeGB: 18.9, state: .downloading(progress: 0), build: build))
        return id
    }

    func deleteImage(_ id: MachineImage.ID) async throws(MachineError) {
        images.removeAll { $0.id == id }
        machines.removeAll { $0.imageID == id }
    }

    func setAccount(_ id: MachineImage.ID, userName: String?, password: String?) throws(MachineError) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { throw MachineError(.notFound, "Image \(id) not found.") }
        if let userName { images[index].userName = userName.isEmpty ? nil : userName }
        if let password {
            passwords[id] = password.isEmpty ? nil : password
            images[index].hasPassword = !password.isEmpty
        }
    }

    func password(ofImage id: MachineImage.ID) -> String? { passwords[id] }

    func startSetup(_ id: MachineImage.ID) async throws(MachineError) {
        guard canStartAnother else { throw MachineError(.conflict, "2 virtual machines are already running.") }
        updateImage(id) { $0.setup = ImageSetup(state: .running, agentConnected: false, sipOff: false, isRestarting: false) }
    }

    func restartInRecovery(_ id: MachineImage.ID) async throws(MachineError) {}

    func finishSetup(_ id: MachineImage.ID) async throws(MachineError) {
        updateImage(id) { image in
            image = MachineImage(id: image.id, name: image.name, system: image.system, sizeGB: image.sizeGB, state: .ready, build: image.build,
                                 userName: image.userName, hasPassword: image.hasPassword)
        }
    }

    func stopSetup(_ id: MachineImage.ID) async { updateImage(id) { $0.setup = nil } }

    func createMachine(name: String, imageID: MachineImage.ID, cores: Int, memoryGB: Int, diskGB: Int) async throws(MachineError) -> VirtualMachine.ID {
        guard canStartAnother else { throw MachineError(.conflict, "2 virtual machines are already running.") }
        let id = "machine-\(machines.count + 1)"
        let version = images.first { $0.id == imageID }?.name ?? "macOS"
        machines.append(VirtualMachine(id: id, name: name, system: .macOS, systemVersion: version, state: .running, cores: cores, memoryGB: memoryGB,
                                       diskGB: diskGB, address: nil, projectID: nil, cpuUsage: nil, snapshots: [], imageID: imageID))
        return id
    }

    func start(_ id: VirtualMachine.ID) async throws(MachineError) {
        guard canStartAnother else { throw MachineError(.conflict, "2 virtual machines are already running.") }
        setState(id, .running)
    }

    func stop(_ id: VirtualMachine.ID) async throws(MachineError) { setState(id, .stopped) }
    func pause(_ id: VirtualMachine.ID) async throws(MachineError) { setState(id, .paused) }
    func resume(_ id: VirtualMachine.ID) async throws(MachineError) { setState(id, .running) }

    func updateMachine(_ id: VirtualMachine.ID, name: String, cores: Int, memoryGB: Int, diskGB: Int) throws(MachineError) {
        guard let index = machines.firstIndex(where: { $0.id == id }) else { throw MachineError(.notFound, "Virtual machine \(id) not found.") }
        let old = machines[index]
        machines[index] = VirtualMachine(id: id, name: name, system: old.system, systemVersion: old.systemVersion, state: old.state, cores: cores,
                                         memoryGB: memoryGB, diskGB: diskGB, address: old.address, projectID: old.projectID, cpuUsage: old.cpuUsage,
                                         snapshots: old.snapshots, imageID: old.imageID)
    }

    func deleteMachine(_ id: VirtualMachine.ID) async throws(MachineError) { machines.removeAll { $0.id == id } }
    func setDefaults(_ values: MachineDefaults) throws(MachineError) { defaults = values }

    func shell(_ id: VirtualMachine.ID, command: String, asRoot: Bool) async throws(MachineError) -> ShellResult {
        ShellResult(exitStatus: 0, timedOut: false, stdout: "sample output of \(command)\n", stderr: "", truncated: false)
    }

    func screen(_ id: String) -> VZVirtualMachine? { nil }
    func minimumDiskGB(ofImage id: MachineImage.ID) -> Int { 32 }

    private func setState(_ id: VirtualMachine.ID, _ state: VirtualMachine.State) {
        guard let index = machines.firstIndex(where: { $0.id == id }) else { return }
        let old = machines[index]
        machines[index] = VirtualMachine(id: id, name: old.name, system: old.system, systemVersion: old.systemVersion, state: state, cores: old.cores,
                                         memoryGB: old.memoryGB, diskGB: old.diskGB, address: state == .stopped ? nil : old.address,
                                         projectID: old.projectID, cpuUsage: state == .running ? old.cpuUsage : 0, snapshots: old.snapshots,
                                         imageID: old.imageID, agentConnected: state == .running)
    }

    private func updateImage(_ id: MachineImage.ID, _ change: (inout MachineImage) -> Void) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        change(&images[index])
    }
}
