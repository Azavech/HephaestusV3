import ExternalTools
import FileStorage
import Foundation
import Testing
@testable import ProjectData

@Suite("Session")
@MainActor
struct ProjectSessionTests {
    /// A folder with stand-ins for git and ssh, never run: the fake runner answers for them.
    private func toolsFolder(in world: World) throws -> String {
        let bin = world.path("bin")
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        for tool in ["git", "ssh", "kubectl"] {
            let path = bin + "/" + tool
            try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: path))
            chmod(path, 0o755)
        }
        return bin
    }

    @Test("Without a data folder the session fails, and every change says so")
    func noDataFolder() async {
        let session = ProjectSession(dataFolder: nil, runner: FakeRunner())
        await session.start()
        #expect(session.phase == .failed(.noDataFolder))
        await #expect(throws: ProjectError.noDataFolder) { try await session.remove("ORD") }
    }

    @Test("Start: lock, load, then the shell, the tools and the origins")
    func start() async throws {
        try await withTemporaryFolderAsync { world in
            let orders = try world.project("orders", id: "ORD")
            try world.register(orders)
            let bin = try toolsFolder(in: world)
            let runner = FakeRunner(origins: [orders: "git@github.com:example/orders.git"], environment: "PATH=\(bin)\0HOME=/x\0")
            let session = ProjectSession(dataFolder: world.data, runner: runner, processEnvironment: ["PATH": "/usr/bin"])
            await session.start()
            #expect(session.phase == .ready)
            #expect(session.snapshot.projects.map(\.id) == ["ORD"])
            #expect(session.shell?.outcome == .captured(count: 2))
            #expect(session.tools.git == bin + "/git")
            #expect(session.kubectl?.executable == bin + "/kubectl")
            #expect(session.snapshot.project("ORD")?.resolved.githubPage == "https://github.com/example/orders")

            let second = ProjectSession(dataFolder: world.data, runner: runner)
            await second.start()
            #expect(second.phase == .failed(.storage(.folderInUse(path: world.data.url.path))))
            await session.stop()
        }
    }

    @Test("Load shows the projects without the shell, the tools or the origins; the lookup comes after")
    func loadBeforeTools() async throws {
        try await withTemporaryFolderAsync { world in
            let orders = try world.project("orders", id: "ORD")
            try world.register(orders)
            let bin = try toolsFolder(in: world)
            let runner = FakeRunner(origins: [orders: "git@github.com:example/orders.git"], environment: "PATH=\(bin)\0HOME=/x\0")
            let session = ProjectSession(dataFolder: world.data, runner: runner, processEnvironment: ["PATH": "/usr/bin"])
            await session.load()
            #expect(session.phase == .ready && session.snapshot.projects.map(\.id) == ["ORD"])
            #expect(!session.hasLookedUpTools && session.shell == nil)
            await session.lookUpTools()
            #expect(session.hasLookedUpTools && session.tools.git == bin + "/git")
            #expect(session.snapshot.project("ORD")?.resolved.githubPage == "https://github.com/example/orders")
            await session.stop()
        }
    }

    @Test("A wait for the tools ends with the first lookup; after it, or for a session that can't start, at once")
    func waitForTools() async throws {
        try await withTemporaryFolderAsync { world in
            let bin = try toolsFolder(in: world)
            let session = ProjectSession(dataFolder: world.data, runner: FakeRunner(environment: "PATH=\(bin)\0HOME=/x\0"),
                                         processEnvironment: ["PATH": "/usr/bin"])
            #expect(!session.hasLookedUpTools)
            let waiter = Task { @MainActor in
                await session.waitForTools()
                return session.kubectl?.executable
            }
            await session.start()
            #expect(await waiter.value == bin + "/kubectl")
            #expect(session.hasLookedUpTools)
            await session.waitForTools()
            await session.stop()
        }
        let failed = ProjectSession(dataFolder: nil, runner: FakeRunner())
        await failed.start()
        await failed.waitForTools()
        #expect(!failed.hasLookedUpTools)
    }

    @Test("Changes go through the library and the session shows the result")
    func changes() async throws {
        try await withTemporaryFolderAsync { world in
            let session = ProjectSession(dataFolder: world.data, runner: FakeRunner())
            await session.start()
            #expect(session.snapshot.projects.isEmpty)
            let id = try await session.create(NewProject(name: "Orders", identifier: "ORD", kind: .goService,
                                                         folder: world.path("orders"), createsFolder: true))
            #expect(id == "ORD")
            try await session.update("ORD", ProjectChange(environments: [EnvironmentEntry(name: "local"), EnvironmentEntry(name: "staging")]))
            try await session.setCurrentEnvironment("ORD", to: "staging")
            #expect(session.snapshot.project("ORD")?.resolved.currentEnvironment == "staging")
            try await session.remove("ORD")
            #expect(session.snapshot.projects.isEmpty)
            await session.stop()
        }
    }

    @Test("A project file changed outside the app shows in the session")
    func outsideChange() async throws {
        try await withTemporaryFolderAsync { world in
            let orders = try world.project("orders", id: "ORD", name: "Orders")
            try world.register(orders)
            let hub = FileEventHub(quietDelay: .milliseconds(50), maximumDelay: .milliseconds(400))
            let session = ProjectSession(dataFolder: world.data, runner: FakeRunner(), hub: hub)
            await session.start()
            try await Task.sleep(for: .milliseconds(300))
            try world.project("orders", id: "ORD", name: "Orders API")
            let deadline = ContinuousClock.now + .seconds(10)
            while session.snapshot.project("ORD")?.file.name != "Orders API", ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(session.snapshot.project("ORD")?.file.name == "Orders API")
            await session.stop()
        }
    }
}
