import ExternalTools
import FileStorage
import Foundation
import ProjectData
import Testing
import ToolsFoundation
@testable import ProjectsKit

/// Answers every run with success and no output: no process starts.
private final class QuietRunner: ProcessRunning {
    func run(_ request: ProcessRequest, input: Data?, timeout: Duration?) async throws -> ProcessResult {
        ProcessResult(termination: .exited(0), standardOutput: Data("PATH=/usr/bin\0".utf8))
    }
}

@MainActor
@Suite("Project Settings")
struct ProjectSettingsTests {
    /// A started session on a temporary data folder, with Orders (a service with `local` and `staging`) and
    /// its sub project Worker.
    private func withSession(_ body: (ProjectSession, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectsKitTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ folder: String, _ text: String) throws {
            let file = root.appendingPathComponent(folder).appendingPathComponent(".hephaestus/project.yml")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        try write("orders", """
        id: ORD
        name: Orders
        created: 2026-10-31T09:30:00Z
        type: goService
        subprojects:
        - worker
        environments:
        - name: local
          url: http://127.0.0.1
        - name: staging
          url: https://staging.example.com
          allowInvalidCertificates: true
          deployment: orders

        """)
        try write("orders/worker", "id: WRK\nname: Worker\ncreated: 2026-10-31T09:30:00Z\ntype: goService\n")
        let data = DataFolder(url: root.appendingPathComponent("Data", isDirectory: true))
        try data.createIfNeeded()
        try YAMLFile.write(RegistryFile(projects: [root.appendingPathComponent("orders").path]), to: data.registryFile)
        let session = ProjectSession(dataFolder: data, runner: QuietRunner(), v2Folder: root.appendingPathComponent("none"),
                                     hub: FileEventHub(quietDelay: .milliseconds(20), maximumDelay: .milliseconds(100)))
        await session.start()
        try await body(session, root)
        await session.stop()
    }

    @Test("Each field applies on its own, with V2's rules and messages")
    func generalFields() async throws {
        try await withSession { session, _ in
            let model = ProjectSettingsModel(projectID: "ORD", backend: session)
            #expect(model.name == "Orders")
            model.name = "  "
            await model.applyName()
            #expect(model.message(.name) == "Enter a name of 1 to 100 characters.")
            model.name = "Orders API"
            await model.applyName()
            #expect(model.message(.name) == nil)
            #expect(session.snapshot.project("ORD")?.file.name == "Orders API")
            model.icon = "not.a.symbol.anywhere"
            await model.applyIcon()
            #expect(model.message(.icon) == "not.a.symbol.anywhere is not an SF Symbol of this Mac.")
            model.icon = "hammer"
            await model.applyIcon()
            #expect(session.snapshot.project("ORD")?.file.icon == "hammer")
            model.docsPath = ".hephaestus"
            await model.applyDocsPath()
            #expect(model.message(.docsPath) == "Enter a folder path inside the project, for example docs.")
            model.githubPage = " https://github.com/example/orders/ "
            await model.applyGitHubPage()
            #expect(session.snapshot.project("ORD")?.file.githubPage == "https://github.com/example/orders")
            #expect(model.githubPage == "https://github.com/example/orders")
            await model.applyTint(.success)
            #expect(session.snapshot.project("ORD")?.file.color == "success")
            await model.applyKind(.library)
            #expect(session.snapshot.project("ORD")?.file.type == .library)
        }
    }

    @Test("+ names a new environment, a rename keeps it selected, − selects the first")
    func environments() async throws {
        try await withSession { session, _ in
            let model = ProjectSettingsModel(projectID: "ORD", backend: session)
            #expect(model.selectedEnvironment == "local")
            await model.addEnvironment()
            #expect(model.selectedEnvironment == "New Environment")
            await model.addEnvironment()
            #expect(model.selectedEnvironment == "New Environment 2")
            model.environmentName = "preview"
            await model.applyEnvironmentField(.environmentName)
            #expect(model.selectedEnvironment == "preview")
            #expect(session.snapshot.project("ORD")?.file.environments.map(\.name) == ["local", "staging", "New Environment", "preview"])
            model.port = "70000"
            await model.applyEnvironmentField(.port)
            #expect(model.message(.port) == "Enter a port from 1 to 65535.")
            model.port = "8080"
            model.url = "http://127.0.0.1"
            await model.applyPendingEnvironmentFields()
            #expect(session.snapshot.project("ORD")?.file.environments.last?.baseURL == "http://127.0.0.1:8080")
            model.environmentName = "local"
            await model.applyEnvironmentField(.environmentName)
            #expect(model.message(.environmentName) == "An environment named “local” already exists.")
            await model.removeEnvironment()
            #expect(model.selectedEnvironment == "local")
            #expect(session.snapshot.project("ORD")?.file.environments.count == 3)
        }
    }

    @Test("An inherited environment changes only in the sub project's changes, the parent's values as placeholders")
    func inherited() async throws {
        try await withSession { session, _ in
            let model = ProjectSettingsModel(projectID: "WRK", backend: session)
            #expect(model.usesParentSettings)
            await model.select("staging")
            #expect(model.isInherited)
            #expect(model.parentEnvironment?.deployment == "orders")
            #expect(model.deployment.isEmpty)
            model.deployment = "worker"
            await model.applyEnvironmentField(.deployment)
            #expect(session.snapshot.project("WRK")?.file.environmentOverrides["staging"]?.deployment == "worker")
            #expect(model.selected?.deployment == "worker")
            await model.applyCertificates(false)
            #expect(session.snapshot.project("WRK")?.file.environmentOverrides["staging"]?.allowInvalidCertificates == false)
            await model.applyCertificates(true)
            #expect(session.snapshot.project("WRK")?.file.environmentOverrides["staging"]?.allowInvalidCertificates == nil)
            model.deployment = ""
            await model.applyEnvironmentField(.deployment)
            #expect(session.snapshot.project("WRK")?.file.environmentOverrides["staging"] == nil)
            await model.removeEnvironment()
            #expect(session.snapshot.project("ORD")?.file.environments.count == 2)
        }
    }
}
