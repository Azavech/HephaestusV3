import Darwin
import FileStorage
import Foundation
import MCPKit
import ProjectData
import Testing
import Virtualization
@testable import MachineData

func withTemporaryFolder<T>(isolation: isolated (any Actor)? = #isolation, _ body: (URL) async throws -> T) async throws -> T {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MachineDataTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    return try await body(folder)
}

let imageID = "5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F"
let machineID = "7D2C1A90-5E4B-4F3A-8B6C-1D0E9F8A7B6C"
let created = ISODate.date(from: "2026-11-09T14:03:00Z")!

@Suite("Virtual machine files")
struct MachineFileTests {
    @Test("image.yml is written in its layout, nulls included, mode 0600")
    func imageFile() async throws {
        try await withTemporaryFolder { folder in
            let library = MachineLibrary(dataFolder: folder)
            try library.write(ImageFile(id: imageID, version: "27.2.1", build: "26B131", state: .ready, created: created))
            let file = library.folder(image: imageID).imageFile
            #expect(try String(contentsOf: file, encoding: .utf8) == """
                schema: 1
                id: 5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F
                version: 27.2.1
                build: 26B131
                state: ready
                failure: null
                userName: null
                password: null
                created: 2026-11-09T14:03:00Z

                """)
            #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect(library.readImages().map(\.id) == [imageID])
        }
    }

    @Test("An earlier image.yml keeps cores and memoryGB as unknown keys")
    func oldImage() throws {
        let image = try YAMLFile.decode(ImageFile.self, from: Data("""
            schema: 1
            id: 5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F
            version: 27.2.1
            build: 26B131
            cores: 2
            memoryGB: 4
            diskGB: 64
            state: ready
            failure: null
            created: 2026-11-09T14:03:00Z
            """.utf8), path: "image.yml")
        #expect(image.state == .ready)
        #expect(Set(image.unknownKeys.keys) == ["cores", "memoryGB"])
    }

    @Test("vm.yml round-trips its layout; a lowercase id is read in uppercase, unknown keys kept, state never stored")
    func machineFile() throws {
        let text = """
            schema: 1
            id: 7D2C1A90-5E4B-4F3A-8B6C-1D0E9F8A7B6C
            name: Menu checks
            imageID: 5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F
            version: 27.2.1
            build: 26B131
            cores: 4
            memoryGB: 8
            diskGB: null
            growContainer: false
            startedBy: user
            projectID: null
            chatID: null
            created: 2026-11-10T09:12:00Z

            """
        let machine = try YAMLFile.decode(MachineFile.self, from: Data(text.utf8), path: "vm.yml")
        #expect(try YAMLCoding.encode(machine) == text)
        let old = try YAMLFile.decode(MachineFile.self, from: Data("""
            id: 7d2c1a90-5e4b-4f3a-8b6c-1d0e9f8a7b6c
            name: Settings check
            imageID: 5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F
            version: '26.6'
            build: 25G72
            cores: 2
            memoryGB: 4
            startedBy: user
            created: 2026-11-10T10:40:00Z
            note: kept
            state: running
            startedAt: 2026-11-10T10:40:02Z
            """.utf8), path: "vm.yml")
        #expect(old.id == machineID)
        #expect(old.version == "26.6")
        let written = try YAMLCoding.encode(old)
        #expect(written.hasSuffix("created: 2026-11-10T10:40:00Z\nnote: kept\n"))
        #expect(!written.contains("state") && !written.contains("startedAt") && !written.contains("macAddress"))
    }

    @Test("Folders not named by a UUID, or without a valid file, are skipped; machines not started by the user are not listed")
    func reading() async throws {
        try await withTemporaryFolder { folder in
            let library = MachineLibrary(dataFolder: folder)
            try FileManager.default.createDirectory(at: library.images.appendingPathComponent("not-a-uuid"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: library.images.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: true)
            let image = ImageFile(id: imageID, version: "27.2", build: "27C61", state: .ready, created: created)
            try library.write(image)
            var claude = MachineFile(id: UUID().uuidString, name: "Claude's", image: image, cores: 2, memoryGB: 4, diskGB: nil, created: created)
            claude.startedBy = "claude"
            try library.write(claude)
            try library.write(MachineFile(id: machineID, name: "Mine", image: image, cores: 2, memoryGB: 4, diskGB: nil, created: created))
            #expect(library.readImages().map(\.id) == [imageID])
            #expect(library.readMachines().map(\.name) == ["Mine"])
        }
    }

    @Test("A guest file's destination that is a folder of this Mac is refused, never replaced; a file or a new path is fine")
    func fileDestination() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("heph-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("out"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("old".utf8).write(to: folder.appendingPathComponent("file.json"))
        #expect(throws: MachineError.self) { try MachineHost.requireFileDestination(folder.appendingPathComponent("out")) }
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("out").path))
        try MachineHost.requireFileDestination(folder.appendingPathComponent("file.json"))
        try MachineHost.requireFileDestination(folder.appendingPathComponent("new.json"))
    }

    @Test("A new machine copies the image's platform files and clones its disk, grown to its size")
    func createMachine() async throws {
        try await withTemporaryFolder { folder in
            let library = MachineLibrary(dataFolder: folder)
            let image = ImageFile(id: imageID, version: "27.2", build: "27C61", state: .ready, created: created)
            try library.write(image)
            let source = library.folder(image: imageID)
            for file in [source.hardwareModel, source.machineIdentifier, source.auxiliaryStorage] { try Data("x".utf8).write(to: file) }
            try MachineConfiguration.createDisk(at: source.disk, bytes: 1 << 20)
            let machine = try library.createMachine(named: "Test", image: image, cores: 2, memoryGB: 4, diskGB: 1, now: created)
            let target = library.folder(machine: machine.id)
            #expect(try Data(contentsOf: target.hardwareModel) == Data("x".utf8))
            #expect(target.diskGB == 1)
            // A disk without a partition table is only extended: the guest's container doesn't grow.
            #expect(!machine.growContainer)
            #expect(library.readMachines().map(\.id) == [machine.id])
        }
    }
}

@Suite("Guest disks")
struct GuestDiskTests {
    static let recoveryType = "52637672-7900-11AA-AA11-00306543ECAC"

    static func guidBytes(_ text: String) -> [UInt8] {
        let hex = text.replacing("-", with: "")
        let bytes = stride(from: 0, to: 32, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! }
        return [bytes[3], bytes[2], bytes[1], bytes[0], bytes[5], bytes[4], bytes[7], bytes[6]] + bytes[8...]
    }

    static func le(_ value: UInt64, _ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }

    /// A disk laid out as macOS's installer lays one out: a protective MBR, both copies of a table and three
    /// partitions, RecoveryOSContainer last, with markers and a pattern.
    static func makeDisk(_ url: URL, blocks: UInt64, recoveryBlocks: UInt64) throws -> (first: UInt64, last: UInt64) {
        let lastUsable = blocks - 34
        let recoveryLast = (lastUsable + 1) / 8 * 8 - 1
        let recoveryFirst = recoveryLast - recoveryBlocks + 1
        let partitions: [(String, UInt64, UInt64, String)] = [
            ("69646961-6700-11AA-AA11-00306543ECAC", 40, 2087, "iBootSystemContainer"),
            ("7C3457EF-0000-11AA-AA11-00306543ECAC", 2088, recoveryFirst - 1, "Container"),
            (recoveryType, recoveryFirst, recoveryLast, "RecoveryOSContainer"),
        ]
        var entries = [UInt8](repeating: 0, count: 128 * 128)
        for (index, partition) in partitions.enumerated() {
            var entry = guidBytes(partition.0) + guidBytes(UUID().uuidString) + le(partition.1, 8) + le(partition.2, 8) + le(0, 8)
            entry += partition.3.utf16.flatMap { le(UInt64($0), 2) }
            entries.replaceSubrange(index * 128..<index * 128 + entry.count, with: entry)
        }
        let entriesData = Data(entries)
        func header(current: UInt64, backup: UInt64, entriesLBA: UInt64) -> Data {
            var bytes = Array("EFI PART".utf8) + le(0x0001_0000, 4) + le(92, 4) + le(0, 4) + le(0, 4)
            bytes += le(current, 8) + le(backup, 8) + le(34, 8) + le(lastUsable, 8) + guidBytes(UUID().uuidString)
            bytes += le(entriesLBA, 8) + le(128, 4) + le(128, 4) + le(UInt64(CRC32.checksum(entriesData)), 4)
            var data = Data(bytes)
            data.setUInt32(CRC32.checksum(data), at: 16)
            return data + Data(count: 512 - 92)
        }
        var mbr = Data(count: 512)
        mbr.replaceSubrange(446..<462, with: [0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF] + le(1, 4) + le(blocks - 1, 4))
        mbr[510] = 0x55
        mbr[511] = 0xAA
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: blocks * 512)
        try handle.write(mbr, at: 0)
        try handle.write(header(current: 1, backup: blocks - 1, entriesLBA: 2), at: 512)
        try handle.write(entriesData, at: 2 * 512)
        try handle.write(entriesData, at: (blocks - 33) * 512)
        try handle.write(header(current: blocks - 1, backup: 1, entriesLBA: blocks - 33), at: (blocks - 1) * 512)
        try handle.write(Data("RECOVERY-FIRST".utf8), at: recoveryFirst * 512)
        try handle.write(Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 * 7 + 1) }), at: (recoveryFirst + recoveryBlocks / 2) * 512)
        try handle.write(Data("RECOVERY-LAST".utf8), at: recoveryLast * 512)
        return (recoveryFirst, recoveryLast)
    }

    static func read(_ url: URL, at offset: UInt64, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(at: offset, count: count)
    }

    @Test("The checksum is zlib's CRC-32")
    func checksum() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
    }

    @Test("A grown disk has RecoveryOSContainer at its new end, with its bytes, and both copies of the table rewritten")
    func growMovesRecovery() async throws {
        try await withTemporaryFolder { folder in
            let disk = folder.appendingPathComponent("Disk.img")
            let oldBlocks: UInt64 = 131_072
            let old = try Self.makeDisk(disk, blocks: oldBlocks, recoveryBlocks: 16_384)
            let length = old.last - old.first + 1
            let recovery = try Self.read(disk, at: old.first * 512, count: Int(length) * 512)
            let newBlocks: UInt64 = 262_144
            #expect(try GuestDisk.grow(disk, to: newBlocks * 512) == .recoveryMoved)
            let handle = try FileHandle(forReadingFrom: disk)
            defer { try? handle.close() }
            let table = try #require(try PartitionTable.read(handle, diskSize: newBlocks * 512))
            #expect(table.lastUsable == newBlocks - 34)
            #expect(table.backupLBA == newBlocks - 1)
            let moved = table.partition(2)
            #expect(moved.name == "RecoveryOSContainer")
            #expect(moved.last == 262_103)
            #expect(try handle.read(at: moved.first * 512, count: Int(length) * 512) == recovery)
            #expect(try handle.read(at: (oldBlocks - 33) * 512, count: 33 * 512) == Data(count: 33 * 512))
            #expect(try handle.read(at: 0, count: 512).uint32(at: 446 + 12) == UInt32(newBlocks - 1))
        }
    }

    @Test("A disk that keeps its size is not changed; one without a partition table is only extended")
    func otherDisks() async throws {
        try await withTemporaryFolder { folder in
            let plain = folder.appendingPathComponent("Plain.img")
            try Data("disk".utf8).write(to: plain)
            #expect(try GuestDisk.grow(plain, to: 4) == nil)
            #expect(try GuestDisk.grow(plain, to: 1 << 20) == .extendedOnly)
            #expect(try Self.read(plain, at: 0, count: 8) == Data("disk".utf8) + Data(count: 4))
        }
    }
}

@Suite("macOS versions")
struct MacOSVersionTests {
    @Test("ipsw.me's list: https only, the first of each build, newest first, checksums in lowercase")
    func parse() throws {
        let data = Data("""
            {"firmwares": [
              {"version": "26.6.2", "buildid": "25G90", "url": "https://updates.cdn-apple.com/a.ipsw", "filesize": 100, "releasedate": "2026-08-01T00:00:00Z"},
              {"version": "27.2", "buildid": "27C61", "url": "https://updates.cdn-apple.com/b.ipsw", "sha256sum": "\(String(repeating: "AB", count: 32))"},
              {"version": "27.2.1", "buildid": "27C70", "url": "https://updates.cdn-apple.com/c.ipsw", "sha256sum": "short"},
              {"version": "27.3", "buildid": "27D10", "url": "http://insecure.example/d.ipsw"},
              {"version": "27.2", "buildid": "27C61", "url": "https://updates.cdn-apple.com/duplicate.ipsw"},
              {"buildid": "27E1", "url": "https://updates.cdn-apple.com/e.ipsw"}
            ]}
            """.utf8)
        let versions = try #require(MacOSVersions.parse(data))
        #expect(versions.map(\.build) == ["27C70", "27C61", "25G90"])
        #expect(versions[1].sha256 == String(repeating: "ab", count: 32))
        #expect(versions[0].sha256 == nil)
        #expect(versions[2].sizeBytes == 100)
        #expect(MacOSVersions.parse(Data("[]".utf8)) == nil)
    }

    @Test("Versions compare number by number")
    func compare() {
        #expect(MacOSVersions.compare("27.2.1", "27.2") == .orderedDescending)
        #expect(MacOSVersions.compare("27.2", "26.6.2") == .orderedDescending)
        #expect(MacOSVersions.compare("27.2", "27.2.0") == .orderedSame)
    }
}

@Suite("Guest addresses")
struct DHCPLeaseTests {
    @Test("The last lease of the machine's MAC address, its octets without their leading zeros")
    func lease() {
        let text = """
            {
            	name=guest
            	ip_address=192.168.64.3
            	hw_address=1,a:b:c:1:2:3
            	lease=0x6735
            }
            {
            	name=other
            	ip_address=192.168.64.4
            	hw_address=1,a:b:c:1:2:4
            }
            {
            	ip_address=192.168.64.9
            	hw_address=1,a:b:c:1:2:3
            }
            """
        #expect(DHCPLeases.address(of: "0a:0b:0c:01:02:03", in: text) == "192.168.64.9")
        #expect(DHCPLeases.address(of: "0A:0B:0C:01:02:04", in: text) == "192.168.64.4")
        #expect(DHCPLeases.address(of: "0a:0b:0c:01:02:05", in: text) == nil)
    }
}

@Suite("Guest agent protocol")
struct GuestAgentProtocolTests {
    @Test("A frame carries its two lengths big-endian, then the JSON object and the data")
    func frame() throws {
        let frame = GuestAgentFrame(json: ["type": "hello", "protocol": 1], data: Data([1, 2, 3]))
        let bytes = try frame.encoded()
        let jsonLength = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        #expect(bytes[4..<8] == Data([0, 0, 0, 3]))
        let decoded = try GuestAgentFrame.decode(body: bytes.subdata(in: 8..<(8 + jsonLength)), data: bytes.suffix(3))
        #expect(decoded == frame)
        #expect(throws: GuestAgentError.self) { try GuestAgentFrame.decode(body: Data("[1]".utf8), data: Data()) }
    }

    @Test("The host reads the hello, sends requests and gives each its response; the end fails what waits")
    func connection() async throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let host = pair[0], agent = pair[1]
        // A tiny agent: the hello, then one answer per request, echoing the method.
        let thread = Thread {
            try? GuestAgentFrame(json: ["type": "hello", "protocol": 1, "status": ["version": "3.0", "sip": "disabled", "user": "tester"]]).write(to: agent)
            while let frame = try? GuestAgentFrame.read(from: agent) {
                let id = frame.json["id"] ?? 0
                let method = frame.json["method"]?.stringValue ?? ""
                let reply: GuestAgentFrame = method == "fail"
                    ? GuestAgentFrame(json: ["type": "response", "id": id, "error": "It failed."])
                    : GuestAgentFrame(json: ["type": "response", "id": id, "result": ["method": .string(method)]], data: frame.data)
                try? reply.write(to: agent)
            }
            close(agent)
        }
        thread.start()
        let connection = try await GuestAgentConnection.open(descriptor: host, closer: { close(host) })
        #expect(connection.status.sip == .disabled)
        #expect(connection.status.user == "tester")
        let response = try await connection.request("readFile", data: Data("bytes".utf8))
        #expect(response.result["method"] == "readFile")
        #expect(response.data == Data("bytes".utf8))
        await #expect(throws: GuestAgentError.failed(message: "It failed.")) { _ = try await connection.request("fail") }
        connection.close()
        await #expect(throws: GuestAgentError.self) { _ = try await connection.request("status") }
    }

    @Test("Shell words quote single quotes, and ~/ stays the account's home folder")
    func shellWords() {
        #expect(GuestShell.quote("it's") == "'it'\\''s'")
        #expect(GuestShell.path("~/My Folder") == "\"$HOME\"/'My Folder'")
        #expect(GuestShell.path("/tmp/x") == "'/tmp/x'")
        #expect(GuestShell.isGuestPath("~/x") && GuestShell.isGuestPath("/x") && !GuestShell.isGuestPath("x"))
    }
}

// MARK: The host, with a fake backend

@MainActor
final class FakeGuest: GuestMachine {
    var virtualMachine: VZVirtualMachine? { nil }
    var events: ((GuestMachineEvent) -> Void)?
    var started: [Bool] = []
    var stopped = 0
    var shutDowns = 0
    var startFailure: String?
    /// Whether a shutdown through the agent stops the guest.
    var shutsDown = true
    var requests: [String] = []

    func start(recovery: Bool) async throws {
        if let startFailure { throw MachineFailure(startFailure) }
        started.append(recovery)
    }

    func stop() async { stopped += 1 }
    func pause() async throws {}
    func resume() async throws {}

    func shutDownGuest() async throws {
        shutDowns += 1
        if shutsDown { events?(.stopped(error: nil)) }
    }

    func agentRequest(_ method: String, params: [String: JSONValue], data: Data, timeout: Duration) async throws -> GuestAgentResponse {
        requests.append(method)
        return GuestAgentResponse(result: ["exitStatus": 0, "stdout": "ok"])
    }

    func requestStop() throws {}

    func connectAgent(sip: GuestAgentStatus.SIP) { events?(.agentConnected(GuestAgentStatus(version: "3.0", sip: sip))) }
}

@MainActor
final class FakeBackend: MachineBackend {
    var supportsMachines = true
    var guests: [FakeGuest] = []
    var downloadFailure: String?
    var installed: [String] = []
    let versionList = [MacOSVersion(version: "27.2", build: "27C61", url: "https://example.com/a.ipsw", sizeBytes: 1000, sha256: nil)]

    func versions() async throws(MacOSVersions.ListError) -> [MacOSVersion] { versionList }

    func download(_ version: MacOSVersion, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        if let downloadFailure { throw MachineFailure(downloadFailure) }
        try Data("ipsw".utf8).write(to: file)
        progress(1)
    }

    func install(_ folder: MachineFolder, version: String, cores: Int, memoryGB: Int, progress: @escaping @Sendable (Double) -> Void) async throws {
        for file in [folder.hardwareModel, folder.machineIdentifier, folder.auxiliaryStorage] { try Data("x".utf8).write(to: file) }
        try MachineConfiguration.createDisk(at: folder.disk, bytes: 32 * MachineLibrary.bytesPerGB)
        installed.append(version)
    }

    func makeMachine(_ folder: MachineFolder, cores: Int, memoryGB: Int, macAddress: String?, sharedFolder: URL?) throws -> any GuestMachine {
        let guest = FakeGuest()
        guests.append(guest)
        return guest
    }
}

@Suite("Machine host")
@MainActor
struct MachineHostTests {
    static func host(_ folder: URL, backend: FakeBackend = FakeBackend(), tools: Bool = true) throws -> MachineHost {
        var guestTools: GuestTools?
        if tools {
            let agent = folder.appendingPathComponent("bundle/agent"), script = folder.appendingPathComponent("bundle/install.sh")
            try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("agent".utf8).write(to: agent)
            try Data("script".utf8).write(to: script)
            guestTools = GuestTools(agent: agent, installScript: script)
        }
        let host = MachineHost(dataFolder: DataFolder(url: folder.appendingPathComponent("data")), backend: backend, guestTools: guestTools,
                               now: { created })
        host.addressPoll = (.milliseconds(1), 1)
        host.leases = { _ in "192.168.64.7" }
        host.load()
        return host
    }

    static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    /// A Ready image with its files.
    static func readyImage(_ host: MachineHost) async throws -> ImageFile {
        let image = try await host.addImage(build: "27C61")
        try await waitUntil { host.image(image.id)?.state == .needsSetup }
        try await host.startSetup(image.id)
        let guest = try #require((host.setups[image.id]?.guest as? FakeGuest))
        guest.connectAgent(sip: .disabled)
        try await host.finishSetup(image.id)
        return try #require(host.image(image.id))
    }

    @Test("An image downloads, installs and waits for its setup; the IPSW is deleted")
    func addImage() async throws {
        try await withTemporaryFolder { folder in
            let backend = FakeBackend()
            let host = try Self.host(folder, backend: backend)
            let image = try await host.addImage(build: "27C61")
            #expect(image.state == .downloading)
            try await Self.waitUntil { host.image(image.id)?.state == .needsSetup }
            #expect(backend.installed == ["27.2"])
            #expect(!FileManager.default.fileExists(atPath: host.library!.folder(image: image.id).restoreImage.path))
            await #expect(throws: MachineError(.notFound, "macOS build 99Z1 not found.")) { try await host.addImage(build: "99Z1") }
        }
    }

    @Test("A failed download fails the image with its message; an image an earlier quit interrupted fails at load")
    func failures() async throws {
        try await withTemporaryFolder { folder in
            let backend = FakeBackend()
            backend.downloadFailure = "The download failed: HTTP 404."
            let host = try Self.host(folder, backend: backend)
            let image = try await host.addImage(build: "27C61")
            try await Self.waitUntil { host.image(image.id)?.state == .failed }
            #expect(host.image(image.id)?.failure == "The download failed: HTTP 404.")

            var interrupted = ImageFile(id: UUID().uuidString, version: "27.2", build: "27C61", state: .installing, created: created)
            interrupted.failure = nil
            try host.library!.write(interrupted)
            let again = try Self.host(folder)
            #expect(again.image(interrupted.id)?.state == .failed)
            #expect(again.image(interrupted.id)?.failure == "The app quit before the image was ready.")
        }
    }

    @Test("The setup shares the agent's files and boots; Finish Setup needs SIP off, then the image is Ready")
    func setup() async throws {
        try await withTemporaryFolder { folder in
            let host = try Self.host(folder)
            let image = try await host.addImage(build: "27C61")
            try await Self.waitUntil { host.image(image.id)?.state == .needsSetup }
            try await host.startSetup(image.id)
            #expect(FileManager.default.fileExists(atPath: host.sharedFolder!.appendingPathComponent("hephaestus-agent").path))
            let run = try #require(host.setups[image.id])
            #expect(run.state == .running)
            let guest = try #require(run.guest as? FakeGuest)
            guest.connectAgent(sip: .enabled)
            await #expect(throws: MachineError.self) { try await host.finishSetup(image.id) }
            guest.connectAgent(sip: .disabled)
            try await host.finishSetup(image.id)
            #expect(guest.shutDowns == 1)
            #expect(host.setups.isEmpty)
            #expect(host.image(image.id)?.state == .ready)
        }
    }

    @Test("Without the agent's files in the bundle, Set Up fails with its message")
    func setupWithoutAgent() async throws {
        try await withTemporaryFolder { folder in
            let host = try Self.host(folder, tools: false)
            let image = try await host.addImage(build: "27C61")
            try await Self.waitUntil { host.image(image.id)?.state == .needsSetup }
            await #expect(throws: MachineError(.unavailable, "The guest agent is missing from the app bundle.")) { try await host.startSetup(image.id) }
        }
    }

    @Test("New Machine checks its values, clones the image and starts; at most 2 run")
    func createMachine() async throws {
        try await withTemporaryFolder { folder in
            let host = try Self.host(folder)
            let image = try await Self.readyImage(host)
            await #expect(throws: MachineError(.invalid, "name: use 1 to 100 characters on one line.")) {
                try await host.createMachine(name: "  ", imageID: image.id, cores: 2, memoryGB: 4, diskGB: 64)
            }
            await #expect(throws: MachineError(.invalid, "diskGB: use a number from 32 to 2048.")) {
                try await host.createMachine(name: "A", imageID: image.id, cores: 2, memoryGB: 4, diskGB: 8)
            }
            let first = try await host.createMachine(name: "A", imageID: image.id, cores: 2, memoryGB: 4, diskGB: 64)
            #expect(first.macAddress != nil)
            #expect(host.runs[first.id]?.state == .running)
            try await Self.waitUntil { host.runs[first.id]?.address == "192.168.64.7" }
            _ = try await host.createMachine(name: "B", imageID: image.id, cores: 2, memoryGB: 4, diskGB: 64)
            await #expect(throws: MachineError(.conflict, "2 virtual machines are already running.")) {
                try await host.createMachine(name: "C", imageID: image.id, cores: 2, memoryGB: 4, diskGB: 64)
            }
        }
    }

    @Test("Stop shuts the guest down through the agent, or at once without it; a stopped machine can be edited, not a running one")
    func stopAndEdit() async throws {
        try await withTemporaryFolder { folder in
            let host = try Self.host(folder)
            let image = try await Self.readyImage(host)
            let machine = try await host.createMachine(name: "A", imageID: image.id, cores: 2, memoryGB: 4, diskGB: 64)
            let guest = try #require(host.runs[machine.id]?.guest as? FakeGuest)
            await #expect(throws: MachineError(.conflict, "The virtual machine is running.")) {
                try await host.updateMachine(machine.id, name: "B", cores: 2, memoryGB: 4, diskGB: 64)
            }
            try await host.stop(machine.id)
            #expect(guest.stopped == 1 && guest.shutDowns == 0)
            #expect(host.runs.isEmpty)
            await #expect(throws: MachineError(.invalid, "diskGB: use a number from 64 to 2048.")) {
                try await host.updateMachine(machine.id, name: "B", cores: 2, memoryGB: 4, diskGB: 40)
            }
            // Within this Mac's ranges: a release runner has 3 cores and 7 GB.
            let edited = try await host.updateMachine(machine.id, name: "B", cores: min(4, MachineDefaults.hostCores),
                                                memoryGB: min(8, MachineDefaults.hostMemoryGB), diskGB: 80)
            #expect(edited.name == "B" && edited.growContainer)
            #expect(host.library!.folder(machine: machine.id).diskGB == 80)

            try await host.start(machine.id)
            let second = try #require(host.runs[machine.id]?.guest as? FakeGuest)
            second.connectAgent(sip: .disabled)
            // The grown disk's container grows through the agent at the first start.
            try await Self.waitUntil { host.machine(machine.id)?.growContainer == false }
            #expect(second.requests.contains("exec"))
            try await host.stop(machine.id)
            #expect(second.shutDowns == 1)
        }
    }

    @Test("A machine that stops by itself leaves those that run; a failure is kept for the window")
    func stoppedByItself() async throws {
        try await withTemporaryFolder { folder in
            let host = try Self.host(folder)
            let image = try await Self.readyImage(host)
            let machine = try await host.createMachine(name: "A", imageID: image.id, cores: 2, memoryGB: 4, diskGB: 64)
            let guest = try #require(host.runs[machine.id]?.guest as? FakeGuest)
            guest.events?(.stopped(error: "The guest crashed."))
            #expect(host.runs.isEmpty)
            #expect(host.failures[machine.id] == "The guest crashed.")
            #expect(host.machine(machine.id) != nil)
        }
    }

    @Test("Deleting an image deletes its machines and its folder")
    func deleteImage() async throws {
        try await withTemporaryFolder { folder in
            let host = try Self.host(folder)
            let image = try await Self.readyImage(host)
            let machine = try await host.createMachine(name: "A", imageID: image.id, cores: 2, memoryGB: 4, diskGB: 64)
            try await host.deleteImage(image.id)
            #expect(host.images.isEmpty && host.machines.isEmpty && host.runs.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: host.library!.folder(machine: machine.id).url.path))
            #expect(!FileManager.default.fileExists(atPath: host.library!.folder(image: image.id).url.path))
        }
    }

    @Test("The guest account: trimmed, an empty value removes it, a line break is refused")
    func account() async throws {
        try await withTemporaryFolder { folder in
            let host = try Self.host(folder)
            let image = try await host.addImage(build: "27C61")
            try host.setAccount(image.id, userName: " tester ", password: "secret")
            #expect(host.image(image.id)?.userName == "tester")
            #expect(host.image(image.id)?.password == "secret")
            try host.setAccount(image.id, userName: "", password: nil)
            #expect(host.image(image.id)?.userName == nil)
            #expect(host.image(image.id)?.password == "secret")
            #expect(throws: MachineError(.invalid, "password: use one line.")) { try host.setAccount(image.id, userName: nil, password: "a\nb") }
        }
    }

    @Test("Defaults are kept in settings.yml, each in its range")
    func defaults() async throws {
        try await withTemporaryFolder { folder in
            let host = try Self.host(folder)
            #expect(host.defaults == MachineDefaults(cores: 2, memoryGB: 4, diskGB: 64))
            try host.setDefaults(MachineDefaults(cores: 2, memoryGB: 4, diskGB: 128))
            #expect(DataFolder(url: folder.appendingPathComponent("data")).readSettings().defaultVMDiskGB == 128)
            #expect(throws: MachineError.self) { try host.setDefaults(MachineDefaults(cores: 1, memoryGB: 4, diskGB: 64)) }
            var settings = SettingsFile()
            settings.defaultVMDiskGB = 9999
            #expect(MachineDefaults(settings).diskGB == 2048)
        }
    }
}
