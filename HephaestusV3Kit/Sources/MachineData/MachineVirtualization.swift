import CryptoKit
import Darwin
import Foundation
import Virtualization

/// A failure V3 words itself, or the message of the network's or the Virtualization framework's error, on one line.
public struct MachineFailure: Error, LocalizedError, Sendable, Hashable {
    public let message: String

    public init(_ message: String) { self.message = message }

    public var errorDescription: String? { message }

    public static func message(of error: any Error) -> String {
        let text = (error as? MachineFailure)?.message ?? error.localizedDescription
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " ")
        return line.isEmpty ? "Unknown error." : line
    }

    public static let needsAppleSilicon = MachineFailure("Virtual machines need a Mac with Apple silicon.")
}

/// The configuration of a macOS machine that boots the disk of a folder (docs/data.md › Virtual machines ›
/// Configuration): one display of 2560 × 1600 at 220 ppi, Mac and USB keyboards and pointing
/// devices, a virtio disk, a NAT network device, an entropy device, a socket device for the guest agent and an
/// optional read-only shared folder.
@MainActor
public enum MachineConfiguration {
    /// The port of the socket device the host listens on for the guest agent.
    public nonisolated static let agentPort: UInt32 = 47822

    public nonisolated static var isSupported: Bool {
        #if arch(arm64)
        VZVirtualMachine.isSupported
        #else
        false
        #endif
    }

    /// The platform of a folder: its hardware model, machine identifier and auxiliary storage.
    public static func platform(_ folder: MachineFolder) throws(MachineFailure) -> VZMacPlatformConfiguration {
        guard let model = (try? Data(contentsOf: folder.hardwareModel)).flatMap(VZMacHardwareModel.init(dataRepresentation:)) else {
            throw MachineFailure("The hardware model of the image cannot be read.")
        }
        guard model.isSupported else { throw MachineFailure("This Mac cannot run the macOS of the image.") }
        guard let identifier = (try? Data(contentsOf: folder.machineIdentifier)).flatMap(VZMacMachineIdentifier.init(dataRepresentation:)) else {
            throw MachineFailure("The machine identifier of the image cannot be read.")
        }
        guard FileManager.default.fileExists(atPath: folder.auxiliaryStorage.path) else {
            throw MachineFailure("The auxiliary storage of the image is missing.")
        }
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = model
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: folder.auxiliaryStorage)
        return platform
    }

    /// A validated configuration.
    public static func make(_ folder: MachineFolder, cores: Int, memoryGB: Int, macAddress: String? = nil,
                            sharedFolder: URL? = nil) throws(MachineFailure) -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = try platform(folder)
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = cores
        configuration.memorySize = UInt64(max(0, memoryGB)) * MachineLibrary.bytesPerGB
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 2560, heightInPixels: 1600, pixelsPerInch: 220)]
        configuration.graphicsDevices = [graphics]
        do {
            let attachment = try VZDiskImageStorageDeviceAttachment(url: folder.disk, readOnly: false)
            configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
        } catch {
            throw MachineFailure(MachineFailure.message(of: error))
        }
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        if let macAddress, let address = VZMACAddress(string: macAddress) { network.macAddress = address }
        configuration.networkDevices = [network]
        // A guest older than macOS 13 uses the USB devices, a later one the Mac's.
        configuration.keyboards = [VZMacKeyboardConfiguration(), VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        if let sharedFolder {
            let device = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
            device.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: sharedFolder, readOnly: true))
            configuration.directorySharingDevices = [device]
        }
        do {
            try configuration.validate()
        } catch {
            throw MachineFailure(MachineFailure.message(of: error))
        }
        return configuration
    }

    /// A sparse file of `bytes` bytes, replacing an existing one.
    public nonisolated static func createDisk(at url: URL, bytes: UInt64) throws(MachineFailure) {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw MachineFailure("The disk of the image cannot be created: \(String(cString: strerror(errno))).") }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(bytes)) == 0 else {
            throw MachineFailure("The disk of the image cannot be created: \(String(cString: strerror(errno))).")
        }
    }

    /// A new locally administered MAC address.
    public nonisolated static func newMACAddress() -> String {
        VZMACAddress.randomLocallyAdministered().string
    }
}

/// The install of macOS into an image's folder with `VZMacOSInstaller` (docs/data.md › Virtual machines ›
/// Adding an image).
@MainActor
public enum MachineInstaller {
    /// Reads `Restore.ipsw`, writes `HardwareModel`, `MachineIdentifier`, `AuxiliaryStorage` and a sparse
    /// `Disk.img` of 32 GB, then installs. Cancelling the task cancels the installer.
    public static func install(_ folder: MachineFolder, version: String, cores: Int, memoryGB: Int,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        let restore = try await VZMacOSRestoreImage.image(from: folder.restoreImage)
        guard let requirements = restore.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw MachineFailure("This Mac cannot run macOS \(version).")
        }
        let memoryBytes = UInt64(max(0, memoryGB)) * MachineLibrary.bytesPerGB
        if cores < requirements.minimumSupportedCPUCount || memoryBytes < requirements.minimumSupportedMemorySize {
            let minimumGB = (requirements.minimumSupportedMemorySize + MachineLibrary.bytesPerGB - 1) / MachineLibrary.bytesPerGB
            throw MachineFailure("macOS \(version) needs at least \(requirements.minimumSupportedCPUCount) cores and \(minimumGB) GB of memory.")
        }
        try Task.checkCancellation()
        try requirements.hardwareModel.dataRepresentation.write(to: folder.hardwareModel, options: .atomic)
        try VZMacMachineIdentifier().dataRepresentation.write(to: folder.machineIdentifier, options: .atomic)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: folder.auxiliaryStorage, hardwareModel: requirements.hardwareModel, options: [.allowOverwrite])
        try MachineConfiguration.createDisk(at: folder.disk, bytes: UInt64(MachineLibrary.imageDiskGB) * MachineLibrary.bytesPerGB)
        let machine = VZVirtualMachine(configuration: try MachineConfiguration.make(folder, cores: cores, memoryGB: memoryGB))
        let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: folder.restoreImage)
        let observation = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { value, _ in
            progress(value.fractionCompleted)
        }
        defer { observation.invalidate() }
        let cancellation = InstallCancellation(progress: installer.progress)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    installer.install { continuation.resume(with: $0) }
                    cancellation.started()
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            Task { @MainActor in cancellation.cancel() }
        }
        if machine.canStop { try? await machine.stop() }
    }

    /// The installer's progress can be cancelled only once the install has started.
    @MainActor private final class InstallCancellation {
        private let progress: Progress
        private var hasStarted = false
        private var isCancelled = false

        init(progress: Progress) { self.progress = progress }

        func started() {
            hasStarted = true
            if isCancelled { progress.cancel() }
        }

        func cancel() {
            isCancelled = true
            if hasStarted { progress.cancel() }
        }
    }
}

/// One download of an IPSW: written to the file as the bytes arrive and hashed on the way. No overall
/// timeout; it fails after 60 seconds without data. A failed or cancelled download leaves no file.
public final class IPSWDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let idleTimeout: TimeInterval = 60

    private let file: URL
    private let expectedSHA256: String?
    private let listedSize: Int64
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var task: URLSessionDataTask?
    private var isCancelled = false
    // On the delegate's serial queue only.
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var received: Int64 = 0
    private var expected: Int64 = 0
    private var lastPercentage = -1
    private var failure: (any Error)?

    public init(file: URL, version: MacOSVersion, progress: @escaping @Sendable (Double) -> Void) {
        self.file = file
        expectedSHA256 = version.sha256
        listedSize = version.sizeBytes
        self.progress = progress
    }

    public func run(_ url: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.idleTimeout
        configuration.timeoutIntervalForResource = 365 * 24 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let task = session.dataTask(with: URLRequest(url: url))
                let cancelNow = lock.withLock { () -> Bool in
                    self.continuation = continuation
                    self.task = task
                    return isCancelled
                }
                task.resume()
                if cancelNow { task.cancel() }
            }
        } onCancel: {
            let task = lock.withLock { () -> URLSessionDataTask? in
                isCancelled = true
                return self.task
            }
            task?.cancel()
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            failure = MachineFailure("The download failed: HTTP \(status).")
            completionHandler(.cancel)
            return
        }
        expected = response.expectedContentLength > 0 ? response.expectedContentLength : listedSize
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: file)
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
            }
            handle = try FileHandle(forWritingTo: file)
        } catch {
            failure = error
            completionHandler(.cancel)
            return
        }
        report()
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
            return
        }
        hasher.update(data: data)
        received += Int64(data.count)
        report()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        try? handle?.close()
        handle = nil
        var outcome = failure
        if outcome == nil, let error {
            let cancelled = lock.withLock { isCancelled }
            outcome = cancelled || (error as? URLError)?.code == .cancelled ? CancellationError() : error
        }
        if outcome == nil, let expectedSHA256 {
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            if digest != expectedSHA256 { outcome = MachineFailure("The downloaded file does not match its checksum.") }
        }
        if outcome != nil { try? FileManager.default.removeItem(at: file) }
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        if let outcome { continuation?.resume(throwing: outcome) } else { continuation?.resume() }
    }

    /// The fraction received, each time its whole percentage changes.
    private func report() {
        guard expected > 0 else { return }
        let fraction = min(1, Double(received) / Double(expected))
        let percentage = Int(fraction * 100)
        guard percentage != lastPercentage else { return }
        lastPercentage = percentage
        progress(fraction)
    }
}

/// The guest's address: the DHCP lease that macOS's NAT gave the machine's MAC address, in
/// `/var/db/dhcpd_leases`.
public enum DHCPLeases {
    public static let file = URL(fileURLWithPath: "/var/db/dhcpd_leases")

    /// The IP address of the last lease of `macAddress` in the text of the leases file.
    public static func address(of macAddress: String, in text: String) -> String? {
        let wanted = normalized(macAddress)
        var found: String?
        var ip: String?
        var hardware: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "{" {
                ip = nil
                hardware = nil
            } else if line == "}" {
                if let ip, let hardware, hardware == wanted { found = ip }
            } else if line.hasPrefix("ip_address=") {
                ip = String(line.dropFirst("ip_address=".count))
            } else if line.hasPrefix("hw_address=") {
                // `1,2:3:4:5:6:7`: the type, then the octets without their leading zeros.
                hardware = line.dropFirst("hw_address=".count).split(separator: ",", maxSplits: 1).last.map { normalized(String($0)) }
            }
        }
        return found
    }

    public static func address(of macAddress: String) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return address(of: macAddress, in: text)
    }

    /// Lowercase octets without their leading zeros, as the leases file writes them.
    static func normalized(_ address: String) -> String {
        address.lowercased().split(separator: ":").map { octet in
            let trimmed = octet.drop { $0 == "0" }
            return trimmed.isEmpty ? "0" : String(trimmed)
        }.joined(separator: ":")
    }
}
