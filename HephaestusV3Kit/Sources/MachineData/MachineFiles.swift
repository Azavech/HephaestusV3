import Darwin
import FileStorage
import Foundation

/// `VirtualMachines/Images/<IMAGE-ID>/image.yml`: one macOS image (docs/data.md › Virtual machines). V2's format.
public struct ImageFile: Codable, Sendable, Hashable, Identifiable {
    public enum State: String, Codable, Sendable, Hashable {
        case downloading, installing, needsSetup, ready, failed
    }

    public var schema: Int
    /// An uppercase UUID, the folder's name.
    public var id: String
    public var version: String
    public var build: String
    public var state: State
    public var failure: String?
    public var userName: String?
    public var password: String?
    public var created: Date
    public var unknownKeys: YAMLMapping

    public init(id: String, version: String, build: String, state: State, created: Date) {
        schema = 1
        self.id = id
        self.version = version
        self.build = build
        self.state = state
        self.created = created
        unknownKeys = [:]
    }

    static let knownKeys: Set<String> = ["schema", "id", "version", "build", "state", "failure", "userName", "password", "created", "diskGB",
                                         "progress", "diskBytes"]

    /// A UUID in uppercase, as the folders are named; other text as is.
    static func normalized(_ id: String) -> String { UUID(uuidString: id)?.uuidString ?? id }

    public init(from decoder: any Decoder) throws {
        let c = try MappingReader(decoder)
        schema = try c.schema()
        id = try Self.normalized(c.required("id"))
        version = try c.required("version")
        build = try c.required("build")
        state = try c.required("state")
        failure = try c.optional("failure")
        userName = try c.optional("userName")
        password = try c.optional("password")
        created = try c.requiredDate("created")
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = MappingWriter(encoder)
        try c.encode(schema, "schema")
        try c.encode(id, "id")
        try c.encode(version, "version")
        try c.encode(build, "build")
        try c.encode(state, "state")
        try c.encodeOptional(failure, "failure")
        try c.encodeOptional(userName, "userName")
        try c.encodeOptional(password, "password")
        try c.encodeDate(created, "created")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }
}

/// `VirtualMachines/Machines/<VM-ID>/vm.yml`: one virtual machine. V2's format.
public struct MachineFile: Codable, Sendable, Hashable, Identifiable {
    public var schema: Int
    public var id: String
    /// One line, 1 to 100 characters.
    public var name: String
    public var imageID: String
    public var version: String
    public var build: String
    public var cores: Int
    /// GB of 1024³ bytes.
    public var memoryGB: Int
    public var diskGB: Int?
    public var growContainer: Bool
    /// `user`, or V2's `claude` (a machine Claude started).
    public var startedBy: String
    public var projectID: String?
    public var chatID: String?
    public var created: Date
    /// V3 addition: the network device's MAC address, `xx:xx:xx:xx:xx:xx`, fixed so the guest's address can be
    /// found in the DHCP leases. A machine without one gets one at its next start.
    public var macAddress: String?
    public var unknownKeys: YAMLMapping

    public init(id: String, name: String, image: ImageFile, cores: Int, memoryGB: Int, diskGB: Int?, created: Date) {
        schema = 1
        self.id = id
        self.name = name
        imageID = image.id
        version = image.version
        build = image.build
        self.cores = cores
        self.memoryGB = memoryGB
        self.diskGB = diskGB
        growContainer = diskGB != nil
        startedBy = "user"
        self.created = created
        unknownKeys = [:]
    }

    static let knownKeys: Set<String> = ["schema", "id", "name", "imageID", "version", "build", "cores", "memoryGB", "diskGB", "growContainer",
                                         "startedBy", "projectID", "chatID", "created", "macAddress", "state", "startedAt"]

    public init(from decoder: any Decoder) throws {
        let c = try MappingReader(decoder)
        schema = try c.schema()
        id = try ImageFile.normalized(c.required("id"))
        name = try c.required("name")
        imageID = try ImageFile.normalized(c.required("imageID"))
        version = try c.required("version")
        build = try c.required("build")
        cores = try c.required("cores")
        memoryGB = try c.required("memoryGB")
        diskGB = try c.optional("diskGB")
        growContainer = try c.value("growContainer", default: false)
        startedBy = try c.value("startedBy", default: "user")
        projectID = try c.optional("projectID")
        chatID = try c.optional("chatID")
        created = try c.requiredDate("created")
        macAddress = try c.optional("macAddress")
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = MappingWriter(encoder)
        try c.encode(schema, "schema")
        try c.encode(id, "id")
        try c.encode(name, "name")
        try c.encode(imageID, "imageID")
        try c.encode(version, "version")
        try c.encode(build, "build")
        try c.encode(cores, "cores")
        try c.encode(memoryGB, "memoryGB")
        try c.encodeOptional(diskGB, "diskGB")
        try c.encode(growContainer, "growContainer")
        try c.encode(startedBy, "startedBy")
        try c.encodeOptional(projectID, "projectID")
        try c.encodeOptional(chatID, "chatID")
        try c.encodeDate(created, "created")
        try c.encodeIfPresent(macAddress, "macAddress")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }
}

/// The files of an image's or a machine's folder.
public struct MachineFolder: Sendable, Hashable {
    public let url: URL

    public init(_ url: URL) { self.url = url }

    public var hardwareModel: URL { url.appendingPathComponent("HardwareModel") }
    public var machineIdentifier: URL { url.appendingPathComponent("MachineIdentifier") }
    public var auxiliaryStorage: URL { url.appendingPathComponent("AuxiliaryStorage") }
    public var disk: URL { url.appendingPathComponent("Disk.img") }
    public var restoreImage: URL { url.appendingPathComponent("Restore.ipsw") }
    public var imageFile: URL { url.appendingPathComponent("image.yml") }
    public var machineFile: URL { url.appendingPathComponent("vm.yml") }

    /// The disk's size, in GB rounded up.
    public var diskGB: Int {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: disk.path)[.size] as? UInt64) ?? 0
        return Int((bytes + MachineLibrary.bytesPerGB - 1) / MachineLibrary.bytesPerGB)
    }

    /// The space the folder's files take on disk: for the sparse disk, what was written.
    public var bytesOnDisk: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0) }
    }
}

/// The images and machines of the data folder: `VirtualMachines/Images/` and `VirtualMachines/Machines/`
/// (docs/data.md › Virtual machines).
public struct MachineLibrary: Sendable {
    public let root: URL
    public static let bytesPerGB: UInt64 = 1024 * 1024 * 1024
    /// The disk of a new image.
    public static let imageDiskGB = 32

    public init(dataFolder: URL) {
        root = dataFolder.appendingPathComponent("VirtualMachines", isDirectory: true)
    }

    public var images: URL { root.appendingPathComponent("Images", isDirectory: true) }
    public var machines: URL { root.appendingPathComponent("Machines", isDirectory: true) }

    public func folder(image id: String) -> MachineFolder { MachineFolder(images.appendingPathComponent(id, isDirectory: true)) }
    public func folder(machine id: String) -> MachineFolder { MachineFolder(machines.appendingPathComponent(id, isDirectory: true)) }

    /// The images: folders named by an uppercase UUID with a valid `image.yml` whose `id` is the name.
    public func readImages() -> [ImageFile] {
        read(images) { (try? YAMLFile.read(ImageFile.self, at: MachineFolder($0).imageFile)) }.sorted { $0.created < $1.created }
    }

    /// The machines, those V2's Claude started and left behind excepted.
    public func readMachines() -> [MachineFile] {
        read(machines) { (try? YAMLFile.read(MachineFile.self, at: MachineFolder($0).machineFile)) }
            .filter { $0.startedBy == "user" }.sorted { $0.created < $1.created }
    }

    private func read<T: Identifiable>(_ folder: URL, _ load: (URL) -> T?) -> [T] where T.ID == String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name in
            guard UUID(uuidString: name)?.uuidString == name, let file = load(folder.appendingPathComponent(name)), file.id == name else { return nil }
            return file
        }
    }

    /// Mode 0600: the file holds the guest account's password.
    public func write(_ image: ImageFile) throws(StorageError) {
        try createFolder(folder(image: image.id).url)
        try YAMLFile.write(image, to: folder(image: image.id).imageFile, newFileMode: AtomicFile.privateMode)
    }

    public func write(_ machine: MachineFile) throws(StorageError) {
        try createFolder(folder(machine: machine.id).url)
        try YAMLFile.write(machine, to: folder(machine: machine.id).machineFile)
    }

    private func createFolder(_ url: URL) throws(StorageError) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw .writeFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    /// A new machine of an image: its folder, a copy of the image's hardware model, machine identifier and auxiliary
    /// storage, and a clone of its disk (APFS: it shares the image's blocks), grown to `diskGB`.
    public func createMachine(named name: String, image: ImageFile, cores: Int, memoryGB: Int, diskGB: Int?, now: Date = Date()) throws(StorageError) -> MachineFile {
        var machine = MachineFile(id: UUID().uuidString, name: name, image: image, cores: cores, memoryGB: memoryGB, diskGB: diskGB, created: now)
        let source = folder(image: image.id)
        let target = folder(machine: machine.id)
        try createFolder(target.url)
        do {
            for (from, to) in [(source.hardwareModel, target.hardwareModel), (source.machineIdentifier, target.machineIdentifier),
                               (source.auxiliaryStorage, target.auxiliaryStorage)] {
                try FileManager.default.copyItem(at: from, to: to)
            }
            try Self.clone(source.disk, to: target.disk)
            machine.growContainer = false
            if let diskGB {
                machine.growContainer = try GuestDisk.grow(target.disk, to: UInt64(diskGB) * Self.bytesPerGB) == .recoveryMoved
            }
        } catch {
            try? FileManager.default.removeItem(at: target.url)
            throw .writeFailed(path: target.url.path, reason: (error as NSError).localizedDescription)
        }
        try write(machine)
        return machine
    }

    /// An APFS clone of a file (`clonefile`), or a copy where cloning isn't possible.
    public static func clone(_ source: URL, to target: URL) throws {
        if clonefile(source.path, target.path, 0) != 0 {
            try FileManager.default.copyItem(at: source, to: target)
        }
    }

    /// `~/Library/Application Support/HephaestusV2/VirtualMachines/`.
    public static var v2Folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/HephaestusV2/VirtualMachines")
    }

    /// V2's images and machines, cloned in once, when V3 has no `VirtualMachines/` folder yet. Each folder is copied
    /// file by file with APFS clones, so the import takes almost no space; machines V2's Claude started are left.
    /// Returns how many came.
    @discardableResult
    public func importV2(from v2: URL) -> Int {
        guard !FileManager.default.fileExists(atPath: root.path), FileManager.default.fileExists(atPath: v2.path) else { return 0 }
        var count = 0
        for kind in ["Images", "Machines"] {
            let from = v2.appendingPathComponent(kind)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: from.path)) ?? [] where UUID(uuidString: name)?.uuidString == name {
                let source = from.appendingPathComponent(name)
                if kind == "Machines", (try? YAMLFile.read(MachineFile.self, at: MachineFolder(source).machineFile))?.startedBy != "user" { continue }
                let target = root.appendingPathComponent(kind).appendingPathComponent(name)
                guard (try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)) != nil else { continue }
                for file in (try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? [] where !file.hasPrefix(".") {
                    try? Self.clone(source.appendingPathComponent(file), to: target.appendingPathComponent(file))
                }
                count += 1
            }
        }
        return count
    }
}
