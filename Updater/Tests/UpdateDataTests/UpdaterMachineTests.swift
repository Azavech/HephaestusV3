import Foundation
import Synchronization
import Testing
@testable import UpdateData

/// The machine's world: a feed, downloads and installs answered by the test, a clock that only moves when the test
/// says so, and every message posted.
final class MachineWorld: Sendable {
    let feed = Mutex<Result<FeedResult, UpdaterError>>(.success(.noRelease))
    let downloadResult = Mutex<Result<URL, UpdaterError>>(.success(URL(fileURLWithPath: "/tmp/image.dmg")))
    let verifyResult = Mutex<Result<URL, UpdaterError>>(.success(URL(fileURLWithPath: "/tmp/expanded/HephaestusV3.app")))
    let installOutcome = Mutex<InstallOutcome>(.installed)
    let posted = Mutex<[UpdaterMessage]>([])
    let checks = Mutex(0)
    let downloads = Mutex(0)
    let installs = Mutex<[(restart: Bool, activate: Bool)]>([])
    let discarded = Mutex<[Int]>([])
    let exits = Mutex<[Int32]>([])
    /// The sleeps waiting, by duration: the test wakes them.
    let sleepers = Mutex<[(Duration, CheckedContinuation<Void, any Error>)]>([])
    let cacheRoot: URL

    init(cacheRoot: URL) {
        self.cacheRoot = cacheRoot
    }

    var dependencies: UpdaterMachine.Dependencies {
        UpdaterMachine.Dependencies(
            latest: { [self] () async throws(UpdaterError) -> FeedResult in
                checks.withLock { $0 += 1 }
                return try feed.withLock { $0 }.get()
            },
            download: { [self] (_, _, _) async throws(UpdaterError) -> URL in
                downloads.withLock { $0 += 1 }
                return try downloadResult.withLock { $0 }.get()
            },
            verify: { [self] (_, _) async throws(UpdaterError) -> URL in try verifyResult.withLock { $0 }.get() },
            install: { [self] _, _, restart, activate in
                installs.withLock { $0.append((restart, activate)) }
                return installOutcome.withLock { $0 }
            },
            discard: { [self] build in discarded.withLock { $0.append(build) } },
            post: { [self] message in posted.withLock { $0.append(message) } },
            sleep: { [self] duration in
                try await withCheckedThrowingContinuation { continuation in
                    sleepers.withLock { $0.append((duration, continuation)) }
                }
            },
            exit: { [self] status in exits.withLock { $0.append(status) } })
    }

    /// Wakes the first sleeper of `duration`, once it waits.
    func wake(_ duration: Duration) async -> Bool {
        let waits = await eventually { self.sleepers.withLock { $0.contains { $0.0 == duration } } }
        guard waits else { return false }
        let continuation = sleepers.withLock { sleepers -> CheckedContinuation<Void, any Error>? in
            guard let index = sleepers.firstIndex(where: { $0.0 == duration }) else { return nil }
            return sleepers.remove(at: index).1
        }
        continuation?.resume()
        return true
    }

    var statuses: [UpdaterStatus] {
        posted.withLock { $0.compactMap { if case .status(let status) = $0 { status } else { nil } } }
    }

    var lastState: UpdaterState? { statuses.last?.state }
}

@Suite("Updater states")
struct UpdaterMachineTests {
    let release = FeedResult.release(sampleManifest, manifestData: Data("{}".utf8), diskImageURL: URL(string: "https://github.com/x/y.dmg")!)

    func machine(_ world: MachineWorld, autoUpdate: Bool = true, runningBuild: Int = 78, interval: Int = 30) -> UpdaterMachine {
        UpdaterMachine(arguments: UpdaterArguments(appPath: "/Applications/HephaestusV3.app", pid: 42, intervalMinutes: interval, autoUpdate: autoUpdate),
                       runningBuild: runningBuild, systemVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0),
                       cacheRoot: world.cacheRoot, dependencies: world.dependencies)
    }

    func reaches(_ world: MachineWorld, _ state: UpdaterState) async -> Bool {
        await eventually { world.lastState == state }
    }

    @Test("idle, the first check 10 seconds later, then every interval")
    func schedule() async throws {
        let folder = try TemporaryFolder()
        let world = MachineWorld(cacheRoot: folder.url)
        let machine = machine(world, interval: 60)
        await machine.start()
        #expect(world.statuses == [.initial])
        #expect(await world.wake(.seconds(10)))
        #expect(await reaches(world, .upToDate))
        #expect(world.statuses.map(\.state) == [.idle, .checking, .upToDate])
        #expect(await world.wake(.seconds(3600)))
        #expect(await eventually { world.checks.withLock { $0 } == 2 })
    }

    @Test("A failed check is an error; the repository not shown keeps its message")
    func checkError() async throws {
        let folder = try TemporaryFolder()
        let world = MachineWorld(cacheRoot: folder.url)
        world.feed.withLock { $0 = .failure(UpdaterError(UpdaterTexts.repositoryHidden(ReleaseFeed.repository))) }
        let machine = machine(world)
        await machine.start()
        await machine.handle(.check(intervalMinutes: nil, autoUpdate: nil))
        #expect(await reaches(world, .error))
        #expect(world.statuses.last == UpdaterStatus(state: .error, message: UpdaterTexts.repositoryHidden(ReleaseFeed.repository)))
        // The next check waits for the interval: no retry before.
        #expect(world.checks.withLock { $0 } == 1)
        #expect(await eventually { world.sleepers.withLock { $0.contains { $0.0 == .seconds(1800) } } })
    }

    @Test("autoUpdate: available, downloading, ready, then installing and the install with a restart")
    func automatic() async throws {
        let folder = try TemporaryFolder()
        let world = MachineWorld(cacheRoot: folder.url)
        world.feed.withLock { $0 = .success(release) }
        let machine = machine(world)
        await machine.start()
        await machine.handle(.check(intervalMinutes: nil, autoUpdate: nil))
        #expect(await reaches(world, .ready))
        #expect(world.statuses.map(\.state) == [.idle, .checking, .available, .downloading, .ready])
        #expect(world.posted.withLock { $0.last } == .ready(version: "1.0.44", build: 80))
        // A check while ready makes no request.
        await machine.handle(.check(intervalMinutes: nil, autoUpdate: nil))
        #expect(world.checks.withLock { $0 } == 1)
        #expect(world.lastState == .ready)

        await machine.handle(.appQuitting(restart: true, activate: true))
        #expect(world.lastState == .installing)
        await machine.appExited()
        #expect(world.installs.withLock { $0.map(\.restart) } == [true])
        #expect(world.installs.withLock { $0.map(\.activate) } == [true])
        #expect(world.exits.withLock { $0 } == [0])
    }

    @Test("Without autoUpdate: available waits for install; turning it on downloads after the check")
    func manual() async throws {
        let folder = try TemporaryFolder()
        let world = MachineWorld(cacheRoot: folder.url)
        world.feed.withLock { $0 = .success(release) }
        let machine = machine(world, autoUpdate: false)
        await machine.start()
        await machine.handle(.check(intervalMinutes: nil, autoUpdate: nil))
        #expect(await reaches(world, .available))
        #expect(world.downloads.withLock { $0 } == 0)
        await machine.handle(.check(intervalMinutes: 15, autoUpdate: true))
        #expect(await reaches(world, .ready))
        #expect(await machine.intervalMinutes == 15)
        #expect(await machine.autoUpdate)

        let second = MachineWorld(cacheRoot: folder.url)
        second.feed.withLock { $0 = .success(release) }
        let other = self.machine(second, autoUpdate: false)
        await other.start()
        await other.handle(.check(intervalMinutes: nil, autoUpdate: nil))
        #expect(await reaches(second, .available))
        await other.handle(.install)
        #expect(await reaches(second, .ready))
    }

    @Test("Up to date, and a release that needs a newer macOS")
    func upToDate() async throws {
        let folder = try TemporaryFolder()
        let world = MachineWorld(cacheRoot: folder.url)
        world.feed.withLock { $0 = .success(release) }
        let current = machine(world, runningBuild: 80)
        await current.start()
        await current.handle(.check(intervalMinutes: nil, autoUpdate: nil))
        #expect(await reaches(world, .upToDate))

        var newer = sampleManifest
        newer.minimumSystemVersion = "28"
        let other = MachineWorld(cacheRoot: folder.url)
        other.feed.withLock { $0 = .success(.release(newer, manifestData: Data(), diskImageURL: URL(string: "https://x/y.dmg")!)) }
        let machine = machine(other)
        await machine.start()
        await machine.handle(.check(intervalMinutes: nil, autoUpdate: nil))
        #expect(await reaches(other, .upToDate))
        #expect(other.statuses.last == UpdaterStatus(state: .upToDate, version: "1.0.44", build: 80, message: "v1.0.44(80) requires macOS 28."))
    }

    @Test("A failed download is an error with its build, its folder discarded; install tries again")
    func downloadFailure() async throws {
        let folder = try TemporaryFolder()
        let world = MachineWorld(cacheRoot: folder.url)
        world.feed.withLock { $0 = .success(release) }
        world.verifyResult.withLock { $0 = .failure(UpdaterError(UpdaterTexts.invalidSignature)) }
        let machine = machine(world)
        await machine.start()
        await machine.handle(.check(intervalMinutes: nil, autoUpdate: nil))
        #expect(await reaches(world, .error))
        #expect(world.statuses.last == UpdaterStatus(state: .error, version: "1.0.44", build: 80, message: UpdaterTexts.invalidSignature))
        #expect(world.discarded.withLock { $0 } == [80])
        world.verifyResult.withLock { $0 = .success(URL(fileURLWithPath: "/tmp/app")) }
        await machine.handle(.install)
        #expect(await reaches(world, .ready))
    }

    @Test("A previous install that failed is an error until Install, which deletes install-failed")
    func installFailedBefore() async throws {
        let folder = try TemporaryFolder()
        let failed = folder.path("80/install-failed")
        try FileManager.default.createDirectory(at: failed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Permission denied\n".utf8).write(to: failed)
        let world = MachineWorld(cacheRoot: folder.url)
        world.feed.withLock { $0 = .success(release) }
        let machine = machine(world)
        await machine.start()
        await machine.handle(.check(intervalMinutes: nil, autoUpdate: nil))
        #expect(await reaches(world, .error))
        #expect(world.statuses.last?.message == "Installing v1.0.44(80) failed: Permission denied")
        #expect(world.downloads.withLock { $0 } == 0)
        await machine.handle(.install)
        #expect(await reaches(world, .ready))
        #expect(!FileManager.default.fileExists(atPath: failed.path))
    }

    @Test("The app doesn't quit within 60 seconds: back to ready, with the message")
    func quitTimeout() async throws {
        let folder = try TemporaryFolder()
        let world = MachineWorld(cacheRoot: folder.url)
        world.feed.withLock { $0 = .success(release) }
        let machine = machine(world)
        await machine.start()
        await machine.handle(.check(intervalMinutes: nil, autoUpdate: nil))
        #expect(await reaches(world, .ready))
        await machine.handle(.appQuitting(restart: false, activate: false))
        #expect(world.lastState == .installing)
        #expect(await world.wake(.seconds(60)))
        #expect(await reaches(world, .ready))
        #expect(world.statuses.last?.message == UpdaterTexts.didNotQuit)
    }

    @Test("The app quits in any other state: the Updater ends with 0; a failed install with 1")
    func ends() async throws {
        let folder = try TemporaryFolder()
        let world = MachineWorld(cacheRoot: folder.url)
        let machine = machine(world)
        await machine.start()
        await machine.handle(.appQuitting(restart: true, activate: false))
        #expect(world.lastState == .idle)
        await machine.appExited()
        #expect(world.exits.withLock { $0 } == [0])
        #expect(world.installs.withLock { $0 }.isEmpty)

        let failing = MachineWorld(cacheRoot: folder.url)
        failing.feed.withLock { $0 = .success(release) }
        failing.installOutcome.withLock { $0 = .failed("Denied.") }
        let other = self.machine(failing)
        await other.start()
        await other.handle(.check(intervalMinutes: nil, autoUpdate: nil))
        #expect(await reaches(failing, .ready))
        await other.handle(.appQuitting(restart: false, activate: false))
        await other.appExited()
        #expect(failing.exits.withLock { $0 } == [1])
    }

    @Test("Requests that don't apply post the current status again")
    func ignored() async throws {
        let folder = try TemporaryFolder()
        let world = MachineWorld(cacheRoot: folder.url)
        let machine = machine(world)
        await machine.start()
        await machine.handle(.install)
        await machine.handle(.appQuitting(restart: false, activate: false))
        #expect(world.statuses == [.initial, .initial, .initial])
    }
}
