import ExternalTools
import FileStorage
import Foundation
import Testing
@testable import ProjectData

@Suite("Loading")
struct LoadingTests {
    @Test("Projects load depth first; entries that can't load are reported and kept")
    func depthFirstAndIssues() async throws {
        try await withTemporaryFolderAsync { world in
            let orders = try world.project("orders", id: "ORD", extra: "subprojects:\n- worker\n- missing\n- ../escape\n")
            try world.project("orders/worker", id: "WRK", extra: "subprojects:\n- jobs\n")
            try world.project("orders/worker/jobs", id: "JOB")
            let shop = try world.project("shop", id: "SHOP")
            let twin = try world.project("twin", id: "ORD")
            let broken = try world.project("broken", id: "BRK")
            try Data("id: [".utf8).write(to: URL(fileURLWithPath: broken).appendingPathComponent(".hephaestus/project.yml"))
            let empty = world.path("empty")
            try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
            try world.register(orders, shop, twin, broken, empty, world.path("gone"), "relative")
            let snapshot = await world.library().load()
            #expect(snapshot.projects.map(\.id) == ["ORD", "WRK", "JOB", "SHOP"])
            #expect(snapshot.projects.map(\.depth) == [0, 1, 2, 0])
            #expect(snapshot.project("ORD")?.childIDs == ["WRK"])
            #expect(snapshot.project("JOB")?.parentID == "WRK")
            #expect(snapshot.family(of: "ORD").map(\.id) == ["ORD", "WRK", "JOB"])
            let reasons = Dictionary(uniqueKeysWithValues: snapshot.issues.map { ($0.path, $0.reason) })
            #expect(reasons[orders + "/missing"] == .folderMissing)
            #expect(reasons[orders + "/../escape"] == .invalidEntry)
            #expect(reasons[twin] == .identifierInUse(identifier: "ORD", by: "ORD"))
            #expect(reasons[empty] == .fileMissing)
            #expect(reasons[world.path("gone")] == .folderMissing)
            #expect(reasons["relative"] == .invalidEntry)
            guard case .invalidFile? = reasons[broken] else { Issue.record("expected invalidFile"); return }
        }
    }

    @Test("A missing registry is created; invalid data folder files are set aside")
    func dataFolderFiles() async throws {
        try await withTemporaryFolderAsync { world in
            _ = await world.library().load()
            #expect(try YAMLFile.read(RegistryFile.self, at: world.data.registryFile) == RegistryFile())
            #expect(YAMLFile.isMissing(world.data.currentEnvironmentsFile))
            try Data("projects: [".utf8).write(to: world.data.registryFile)
            try Data("projects: 3".utf8).write(to: world.data.currentEnvironmentsFile)
            _ = await world.library().load()
            #expect(try YAMLFile.read(RegistryFile.self, at: world.data.registryFile) == RegistryFile())
            #expect(FileManager.default.fileExists(atPath: world.data.invalidCopy(of: world.data.registryFile).path))
            #expect(FileManager.default.fileExists(atPath: world.data.invalidCopy(of: world.data.currentEnvironmentsFile).path))
            #expect(YAMLFile.isMissing(world.data.currentEnvironmentsFile))
        }
    }
}

@Suite("Outside changes")
struct OutsideChangesTests {
    private func changed(_ path: String) -> [FileEvent] {
        [FileEvent(path: path, kind: .modified)]
    }

    @Test("A changed project file reloads; an invalid one keeps the loaded version and says why")
    func projectFile() async throws {
        try await withTemporaryFolderAsync { world in
            let orders = try world.project("orders", id: "ORD", name: "Orders")
            try world.register(orders)
            let library = await world.library()
            let first = await library.load()
            try world.project("orders", id: "ORD", name: "Orders API")
            let renamed = try #require(await library.handle(changed(orders + "/.hephaestus/project.yml")))
            #expect(renamed.project("ORD")?.file.name == "Orders API")
            #expect(renamed.revision > first.revision)
            try Data("id: [".utf8).write(to: URL(fileURLWithPath: orders).appendingPathComponent(".hephaestus/project.yml"))
            let invalid = try #require(await library.handle(changed(orders + "/.hephaestus/project.yml")))
            #expect(invalid.project("ORD")?.file.name == "Orders API")
            #expect(invalid.project("ORD")?.fileIssue?.hasPrefix("not valid YAML") == true)
            try world.project("orders", id: "OTHER")
            let changedID = try #require(await library.handle(changed(orders + "/.hephaestus/project.yml")))
            #expect(changedID.project("ORD")?.fileIssue == "id: the identifier can't change")
        }
    }

    @Test("A deleted project file unloads the project and its sub projects; they load again when it comes back")
    func deletedFile() async throws {
        try await withTemporaryFolderAsync { world in
            let orders = try world.project("orders", id: "ORD", extra: "subprojects:\n- worker\n")
            try world.project("orders/worker", id: "WRK")
            try world.register(orders)
            let library = await world.library()
            _ = await library.load()
            let file = URL(fileURLWithPath: orders).appendingPathComponent(".hephaestus/project.yml")
            let saved = try Data(contentsOf: file)
            try FileManager.default.removeItem(at: file)
            let unloaded = try #require(await library.handle([FileEvent(path: file.path, kind: .removed)]))
            #expect(unloaded.projects.isEmpty)
            #expect(unloaded.issues.map(\.reason) == [.fileMissing])
            try saved.write(to: file)
            let reloaded = try #require(await library.handle([FileEvent(path: file.path, kind: .created)]))
            #expect(reloaded.projects.map(\.id) == ["ORD", "WRK"])
        }
    }

    @Test("An edited registry loads added folders and unloads removed ones")
    func registry() async throws {
        try await withTemporaryFolderAsync { world in
            let orders = try world.project("orders", id: "ORD")
            let shop = try world.project("shop", id: "SHOP")
            try world.register(orders)
            let library = await world.library()
            _ = await library.load()
            try world.register(shop)
            let snapshot = try #require(await library.handle(changed(world.data.registryFile.path)))
            #expect(snapshot.projects.map(\.id) == ["SHOP"])
            try Data("projects: [".utf8).write(to: world.data.registryFile)
            #expect(await library.handle(changed(world.data.registryFile.path)) == nil)
        }
    }

    @Test("The app's own writes and unrelated files change nothing")
    func ownAndUnrelated() async throws {
        try await withTemporaryFolderAsync { world in
            let orders = try world.project("orders", id: "ORD")
            try world.register(orders)
            let library = await world.library()
            _ = await library.load()
            _ = try await library.update("ORD", ProjectChange(name: "Orders"))
            #expect(await library.handle(changed(orders + "/.hephaestus/project.yml")) == nil)
            #expect(await library.handle(changed(orders + "/Sources/main.go")) == nil)
            #expect(await library.handle([FileEvent(path: orders + "/.hephaestus/project.yml", kind: .metadata)]) == nil)
        }
    }

    @Test("Relevant events: project files, data files, git configuration, project folders, dropped events")
    func relevance() {
        let roots: Set<String> = ["/p/orders"]
        #expect(ProjectLibrary.isRelevant(FileEvent(path: "/p/orders/.hephaestus/project.yml", kind: .modified), roots: roots))
        #expect(ProjectLibrary.isRelevant(FileEvent(path: "/p/orders/.git/config", kind: .modified), roots: roots))
        #expect(ProjectLibrary.isRelevant(FileEvent(path: "/p", kind: .renamed), roots: roots))
        #expect(ProjectLibrary.isRelevant(FileEvent(path: "/x/y", kind: .mustRescan), roots: roots))
        #expect(!ProjectLibrary.isRelevant(FileEvent(path: "/p/orders/main.go", kind: .modified), roots: roots))
        #expect(!ProjectLibrary.isRelevant(FileEvent(path: "/p/orders/.hephaestus/ticket/ORD-1.yml", kind: .modified), roots: roots))
    }
}

@Suite("Creating, opening and removing")
struct ProjectChangesTests {
    @Test("Create writes the project file and .gitignore, then registers the folder")
    func create() async throws {
        try await withTemporaryFolderAsync { world in
            let library = await world.library()
            _ = await library.load()
            let folder = world.path("orders")
            let (id, snapshot) = try await library.create(NewProject(name: "  Orders  ", identifier: "ord", kind: .goService,
                                                                     folder: folder, createsFolder: true))
            #expect(id == "ORD")
            #expect(snapshot.project("ORD")?.root == folder)
            let file = try world.readProject(folder)
            #expect(file == ProjectFile(id: "ORD", name: "Orders", created: ISODate.date(from: "2026-11-13T10:00:00Z")!, type: .goService))
            #expect(try String(contentsOfFile: folder + "/.hephaestus/.gitignore", encoding: .utf8) == "chats/\n")
            #expect(try YAMLFile.read(RegistryFile.self, at: world.data.registryFile).projects == [folder])
        }
    }

    @Test("Create refuses bad names and identifiers, used identifiers, projects already there and missing folders")
    func createRefusals() async throws {
        try await withTemporaryFolderAsync { world in
            let orders = try world.project("orders", id: "ORD", name: "Orders")
            try world.register(orders)
            let library = await world.library()
            _ = await library.load()
            func attempt(_ name: String = "New", identifier: String = "NEW", folder: String? = nil, creates: Bool = true,
                         parent: String? = nil) async -> ProjectError? {
                do {
                    _ = try await library.create(NewProject(name: name, identifier: identifier, folder: folder ?? world.path("new"),
                                                            createsFolder: creates, parentID: parent))
                    return nil
                } catch {
                    return error
                }
            }
            #expect(await attempt(" ") == .rule(.nameLength(field: "name")))
            #expect(await attempt(identifier: "N3W") == .rule(.identifierFormat))
            #expect(await attempt(identifier: "ord") == .rule(.identifierInUse(identifier: "ORD", by: "Orders")))
            #expect(await attempt(folder: orders) == .alreadyContainsProject(path: orders))
            #expect(await attempt(folder: world.path("absent"), creates: false) == .folderMissing(path: world.path("absent")))
            #expect(await attempt(folder: world.path("elsewhere"), parent: "ORD") == .notInsideParent(parentName: "Orders"))
            #expect(!FileManager.default.fileExists(atPath: world.path("elsewhere")))
        }
    }

    @Test("Create in an existing folder keeps its .gitignore lines and adds chats/")
    func existingFolder() async throws {
        try await withTemporaryFolderAsync { world in
            let folder = world.path("site")
            try FileManager.default.createDirectory(atPath: folder + "/.hephaestus", withIntermediateDirectories: true)
            try Data("attachments/big/".utf8).write(to: URL(fileURLWithPath: folder + "/.hephaestus/.gitignore"))
            let library = await world.library()
            _ = await library.load()
            _ = try await library.create(NewProject(name: "Site", identifier: "WEB", folder: folder, createsFolder: false))
            #expect(try String(contentsOfFile: folder + "/.hephaestus/.gitignore", encoding: .utf8) == "attachments/big/\nchats/\n")
        }
    }

    @Test("A project created or opened inside a loaded project becomes its sub project")
    func subprojects() async throws {
        try await withTemporaryFolderAsync { world in
            let orders = try world.project("orders", id: "ORD")
            try world.register(orders)
            let library = await world.library()
            _ = await library.load()
            _ = try await library.create(NewProject(name: "Worker", identifier: "WRK", folder: orders + "/services/worker",
                                                    createsFolder: true))
            let existing = try world.project("orders/web", id: "WEB")
            let (id, snapshot) = try await library.open(folder: existing)
            #expect(id == "WEB")
            #expect(try world.readProject(orders).subprojects == ["services/worker", "web"])
            #expect(snapshot.projects.map(\.id) == ["ORD", "WRK", "WEB"])
            #expect(try YAMLFile.read(RegistryFile.self, at: world.data.registryFile).projects == [orders])
            #expect(try await library.open(folder: existing).id == "WEB")
        }
    }

    @Test("Opening a parent removes the registry entries of the sub projects it lists")
    func openParent() async throws {
        try await withTemporaryFolderAsync { world in
            let worker = try world.project("orders/worker", id: "WRK")
            let orders = try world.project("orders", id: "ORD", extra: "subprojects:\n- worker\n")
            try world.register(worker)
            let library = await world.library()
            _ = await library.load()
            let snapshot = try await library.open(folder: orders).snapshot
            #expect(snapshot.projects.map(\.id) == ["ORD", "WRK"])
            #expect(snapshot.issues.isEmpty)
            #expect(try YAMLFile.read(RegistryFile.self, at: world.data.registryFile).projects == [orders])
        }
    }

    @Test("Open fails without a project, with an invalid file or with a used identifier")
    func openFailures() async throws {
        try await withTemporaryFolderAsync { world in
            let orders = try world.project("orders", id: "ORD", name: "Orders")
            try world.register(orders)
            let library = await world.library()
            _ = await library.load()
            let empty = world.path("empty")
            try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
            await #expect(throws: ProjectError.noProject(path: empty)) { try await library.open(folder: empty) }
            let twin = try world.project("twin", id: "ORD")
            await #expect(throws: ProjectError.rule(.identifierInUse(identifier: "ORD", by: "Orders"))) {
                try await library.open(folder: twin)
            }
            let broken = try world.project("broken", id: "BRK")
            try Data("id: 3".utf8).write(to: URL(fileURLWithPath: broken + "/.hephaestus/project.yml"))
            let error = await #expect(throws: ProjectError.self) { try await library.open(folder: broken) }
            guard case .storage(.invalidFile)? = error else { Issue.record("unexpected \(String(describing: error))"); return }
        }
    }

    @Test("Remove takes the project and its sub projects out and leaves their files")
    func remove() async throws {
        try await withTemporaryFolderAsync { world in
            let orders = try world.project("orders", id: "ORD", extra: "subprojects:\n- worker\n")
            let worker = try world.project("orders/worker", id: "WRK", extra: "subprojects:\n- jobs\n")
            try world.project("orders/worker/jobs", id: "JOB")
            let shop = try world.project("shop", id: "SHOP")
            try world.register(orders, shop)
            let library = await world.library()
            _ = await library.load()
            var snapshot = try await library.remove("WRK")
            #expect(snapshot.projects.map(\.id) == ["ORD", "SHOP"])
            #expect(try world.readProject(orders).subprojects.isEmpty)
            #expect(FileManager.default.fileExists(atPath: worker + "/.hephaestus/project.yml"))
            snapshot = try await library.remove("ORD")
            #expect(snapshot.projects.map(\.id) == ["SHOP"])
            #expect(try YAMLFile.read(RegistryFile.self, at: world.data.registryFile).projects == [shop])
        }
    }

    @Test("A project skipped because its identifier was used loads once the other is removed")
    func duplicateLoadsLater() async throws {
        try await withTemporaryFolderAsync { world in
            let first = try world.project("first", id: "ORD", name: "First")
            let second = try world.project("second", id: "ORD", name: "Second")
            try world.register(first, second)
            let library = await world.library()
            _ = await library.load()
            let snapshot = try await library.remove("ORD")
            #expect(snapshot.project("ORD")?.file.name == "Second")
            #expect(snapshot.issues.isEmpty)
        }
    }

    @Test("Update changes only the values it sets, with the write rules, and keeps unknown keys")
    func update() async throws {
        try await withTemporaryFolderAsync { world in
            let orders = try world.project("orders", id: "ORD", extra: "commands:\n- make\n")
            try world.register(orders)
            let library = await world.library()
            _ = await library.load()
            _ = try await library.update("ORD", ProjectChange(name: "Orders", color: .some("#34c759"), icon: .some(" hammer "),
                                                              docsPath: "guide", githubPage: .some("https://github.com/example/orders/")))
            var file = try world.readProject(orders)
            #expect(file.name == "Orders")
            #expect(file.color == "#34C759")
            #expect(file.icon == "hammer")
            #expect(file.docsPath == "guide")
            #expect(file.githubPage == "https://github.com/example/orders")
            #expect(file.unknownKeys.keys == ["commands"])
            _ = try await library.update("ORD", ProjectChange(color: .some("info"), icon: .some(nil), githubPage: .some(nil)))
            file = try world.readProject(orders)
            #expect(file.color == "info")
            #expect(file.icon == nil && file.githubPage == nil)
            await #expect(throws: ProjectError.rule(.color)) { try await library.update("ORD", ProjectChange(color: .some("red"))) }
            await #expect(throws: ProjectError.rule(.relativePath(field: "docsPath"))) {
                try await library.update("ORD", ProjectChange(docsPath: ".hephaestus/docs"))
            }
            await #expect(throws: ProjectError.rule(.githubPage)) {
                try await library.update("ORD", ProjectChange(githubPage: .some("https://gitlab.com/a/b")))
            }
            await #expect(throws: ProjectError.projectNotLoaded("NOPE")) { try await library.update("NOPE", ProjectChange()) }
        }
    }

    @Test("Environments are checked and trimmed; a stored one a hand edit made invalid is written back as it is")
    func environments() async throws {
        try await withTemporaryFolderAsync { world in
            let orders = try world.project("orders", id: "ORD", extra: environmentsYAML([("odd", "not a url")]))
            try world.register(orders)
            let library = await world.library()
            let stored = await library.load().project("ORD")!.file.environments
            let added = EnvironmentEntry(name: " staging ", url: " https://staging.example.com ", port: 8443, namespace: " orders ")
            _ = try await library.update("ORD", ProjectChange(environments: stored + [added]))
            let file = try world.readProject(orders)
            #expect(file.environments.map(\.name) == ["odd", "staging"])
            #expect(file.environments[0].url == "not a url")
            #expect(file.environments[1].url == "https://staging.example.com")
            #expect(file.environments[1].namespace == "orders")
            await #expect(throws: ProjectError.rule(.url(field: "environments[1].url"))) {
                try await library.update("ORD", ProjectChange(environments: stored + [EnvironmentEntry(name: "x", url: "ftp://x")]))
            }
            await #expect(throws: ProjectError.rule(.duplicateEnvironment("odd"))) {
                try await library.update("ORD", ProjectChange(environments: stored + [EnvironmentEntry(name: "odd ")]))
            }
            // A copy of a stored environment is checked: the hand-edited URL it carries is refused.
            await #expect(throws: ProjectError.rule(.url(field: "environments[1].url"))) {
                try await library.update("ORD", ProjectChange(environments: stored + stored))
            }
            await #expect(throws: ProjectError.rule(.port(field: "environments[1].port"))) {
                try await library.update("ORD", ProjectChange(environments: stored + [EnvironmentEntry(name: "y", port: 70000)]))
            }
        }
    }
}

@Suite("Inherited settings")
struct InheritedSettingsTests {
    /// A Go service with `local` and `staging`, and a Go service sub project of it.
    private func family(_ world: World, subprojectExtra: String) throws -> (parent: String, child: String) {
        let parent = try world.project("orders", id: "ORD", name: "Orders", extra: """
        type: goService
        githubPage: https://github.com/example/orders
        graphEnabled: true
        subprojects:
        - worker
        environments:
        - name: local
          url: http://127.0.0.1
          port: 8080
        - name: staging
          url: https://staging.example.com
          allowInvalidCertificates: true
          namespace: orders

        """)
        let child = try world.project("orders/worker", id: "WRK", name: "Worker", extra: "type: goService\n" + subprojectExtra)
        try world.register(parent)
        return (parent, child)
    }

    @Test("With Use parent settings on, the parent's environments come first with the changes, then the sub project's own")
    func inherits() async throws {
        try await withTemporaryFolderAsync { world in
            _ = try family(world, subprojectExtra: """
            environments:
            - name: replay
              url: http://127.0.0.1
              port: 9090
            - name: staging
            environmentOverrides:
              local:
                port: 8081
              staging:
                allowInvalidCertificates: false
                deployment: orders-worker
              gone:
                port: 1

            """)
            let worker = await world.library().load().project("WRK")!.resolved
            #expect(worker.environments.map(\.name) == ["local", "staging", "replay"])
            #expect(worker.environments.map(\.baseURL) == ["http://127.0.0.1:8081", "https://staging.example.com", "http://127.0.0.1:9090"])
            #expect(worker.environments[1].allowInvalidCertificates == false)
            #expect(worker.environments[1].namespace == "orders")
            #expect(worker.environments[1].deployment == "orders-worker")
            #expect(worker.inheritedEnvironments.map(\.name) == ["local", "staging"])
            #expect(worker.inheritedEnvironments[0].port == 8080)
            #expect(worker.githubPage == "https://github.com/example/orders")
            #expect(worker.graphEnabled)
        }
    }

    @Test("With Use parent settings off, only the sub project's own settings apply; its changes are kept")
    func off() async throws {
        try await withTemporaryFolderAsync { world in
            let (_, child) = try family(world, subprojectExtra: """
            useParentSettings: false
            environments:
            - name: replay
            environmentOverrides:
              local:
                port: 8081

            """)
            let worker = await world.library().load().project("WRK")!
            #expect(worker.resolved.environments.map(\.name) == ["replay"])
            #expect(worker.resolved.inheritedEnvironments.isEmpty)
            #expect(worker.resolved.githubPage == nil)
            #expect(!worker.resolved.graphEnabled)
            #expect(try world.readProject(child).environmentOverrides.keys.sorted() == ["local"])
        }
    }

    @Test("Nested sub projects inherit what their parent inherits; another type gives no environments")
    func nestedAndTypes() async throws {
        try await withTemporaryFolderAsync { world in
            _ = try family(world, subprojectExtra: "subprojects:\n- jobs\nenvironmentOverrides:\n  local:\n    port: 8081\n")
            try world.project("orders/worker/jobs", id: "JOB", extra: "type: goService\nenvironmentOverrides:\n  local:\n    url: http://10.0.0.1\n")
            let snapshot = await world.library().load()
            #expect(snapshot.project("JOB")?.resolved.environments.first?.baseURL == "http://10.0.0.1:8081")
            try world.project("orders/worker", id: "WRK", extra: "subprojects:\n- jobs\n")
            let other = await world.library().load()
            #expect(other.project("WRK")?.resolved.environments.isEmpty == true)
            #expect(other.project("JOB")?.resolved.environments.isEmpty == true)
        }
    }

    @Test("An own environment can't take an inherited name")
    func nameClash() async throws {
        try await withTemporaryFolderAsync { world in
            _ = try family(world, subprojectExtra: "")
            let library = await world.library()
            _ = await library.load()
            await #expect(throws: ProjectError.rule(.duplicateEnvironment("local"))) {
                try await library.update("WRK", ProjectChange(environments: [EnvironmentEntry(name: "local")]))
            }
        }
    }
}

@Suite("Current environment")
struct CurrentEnvironmentTests {
    @Test("The first environment is current until the user chooses one; the choice is kept outside project.yml")
    func choosing() async throws {
        try await withTemporaryFolderAsync { world in
            let orders = try world.project("orders", id: "ORD", extra: environmentsYAML([("local", nil), ("staging", nil)]))
            try world.register(orders)
            let library = await world.library()
            #expect(await library.load().project("ORD")?.resolved.currentEnvironment == "local")
            let projectFile = try Data(contentsOf: URL(fileURLWithPath: orders + "/.hephaestus/project.yml"))
            let snapshot = try await library.setCurrentEnvironment("ORD", to: "staging")
            #expect(snapshot.project("ORD")?.resolved.currentEnvironment == "staging")
            #expect(try YAMLFile.read(CurrentEnvironmentsFile.self, at: world.data.currentEnvironmentsFile).projects == ["ORD": "staging"])
            #expect(try Data(contentsOf: URL(fileURLWithPath: orders + "/.hephaestus/project.yml")) == projectFile)
            await #expect(throws: ProjectError.unknownEnvironment("prod")) { try await library.setCurrentEnvironment("ORD", to: "prod") }
        }
    }

    @Test("A rename keeps the environment current; a removal gives way to the first and forgets the choice")
    func renameAndRemoval() async throws {
        try await withTemporaryFolderAsync { world in
            let orders = try world.project("orders", id: "ORD", extra: environmentsYAML([("local", nil), ("staging", nil)]))
            try world.register(orders)
            let library = await world.library()
            _ = await library.load()
            _ = try await library.setCurrentEnvironment("ORD", to: "staging")
            let renamed = [EnvironmentEntry(name: "local"), EnvironmentEntry(name: "preprod")]
            var snapshot = try await library.update("ORD", ProjectChange(environments: renamed))
            #expect(snapshot.project("ORD")?.resolved.currentEnvironment == "preprod")
            snapshot = try await library.update("ORD", ProjectChange(environments: [EnvironmentEntry(name: "local")]))
            #expect(snapshot.project("ORD")?.resolved.currentEnvironment == "local")
            #expect(try YAMLFile.read(CurrentEnvironmentsFile.self, at: world.data.currentEnvironmentsFile).projects.isEmpty)
        }
    }

    @Test("Renamed environments changed name at the same place of a list of the same length")
    func renamedRule() {
        let old = [EnvironmentEntry(name: "a"), EnvironmentEntry(name: "b")]
        #expect(ProjectLibrary.renamedEnvironments(from: old, to: [EnvironmentEntry(name: "a"), EnvironmentEntry(name: "c")]) == ["b": "c"])
        #expect(ProjectLibrary.renamedEnvironments(from: old, to: [EnvironmentEntry(name: "c")]).isEmpty)
    }

    @Test("Removing a project forgets its choice and its sub projects'")
    func removalForgets() async throws {
        try await withTemporaryFolderAsync { world in
            let orders = try world.project("orders", id: "ORD", extra: environmentsYAML([("local", nil), ("staging", nil)]))
            let shop = try world.project("shop", id: "SHOP", extra: environmentsYAML([("a", nil), ("b", nil)]))
            try world.register(orders, shop)
            let library = await world.library()
            _ = await library.load()
            _ = try await library.setCurrentEnvironment("ORD", to: "staging")
            _ = try await library.setCurrentEnvironment("SHOP", to: "b")
            _ = try await library.remove("ORD")
            #expect(try YAMLFile.read(CurrentEnvironmentsFile.self, at: world.data.currentEnvironmentsFile).projects == ["SHOP": "b"])
        }
    }
}

@Suite("GitHub page")
struct GitHubPageResolutionTests {
    @Test("The origin's page, by host or SSH alias; a typed page replaces it; without ssh an alias stays unresolved")
    func origins() async throws {
        try await withTemporaryFolderAsync { world in
            let orders = try world.project("orders", id: "ORD")
            let shop = try world.project("shop", id: "SHOP")
            let lab = try world.project("lab", id: "LAB")
            try world.register(orders, shop, lab)
            let runner = FakeRunner(origins: [orders: "git@github.com:example/orders.git", shop: "git@work:example/shop.git",
                                              lab: "https://gitlab.com/example/lab"], hostNames: ["work": "github.com"])
            let library = await world.library(runner, tools: Tools(environment: [:], git: "/usr/bin/git", ssh: "/usr/bin/ssh"))
            _ = await library.load()
            var snapshot = try #require(await library.refreshOrigins())
            #expect(snapshot.project("ORD")?.resolved.githubPage == "https://github.com/example/orders")
            #expect(snapshot.project("SHOP")?.resolved.githubPage == "https://github.com/example/shop")
            #expect(snapshot.project("LAB")?.resolved.githubPage == nil)
            snapshot = try await library.update("ORD", ProjectChange(githubPage: .some("https://github.com/example/typed")))
            #expect(snapshot.project("ORD")?.resolved.githubPage == "https://github.com/example/typed")
            #expect(snapshot.project("ORD")?.resolved.originGithubPage == "https://github.com/example/orders")

            let withoutSSH = await World(world.root).library(runner, tools: Tools(environment: [:], git: "/usr/bin/git"))
            _ = await withoutSSH.load()
            #expect(await withoutSSH.refreshOrigins()?.project("SHOP")?.resolved.githubPage == nil)
        }
    }

    @Test("A sub project takes its parent's page while it uses its parent's settings; a changed .git/config is read again")
    func inheritanceAndGitConfig() async throws {
        try await withTemporaryFolderAsync { world in
            let orders = try world.project("orders", id: "ORD", extra: "subprojects:\n- worker\n")
            let worker = try world.project("orders/worker", id: "WRK", extra: "githubPage: https://github.com/example/worker\n")
            try world.register(orders)
            let runner = FakeRunner(origins: [orders: "https://github.com/example/orders.git"])
            let library = await world.library(runner, tools: Tools(environment: [:], git: "/usr/bin/git"))
            _ = await library.load()
            var snapshot = try #require(await library.refreshOrigins())
            #expect(snapshot.project("WRK")?.resolved.githubPage == "https://github.com/example/orders")
            snapshot = try await library.update("WRK", ProjectChange(useParentSettings: false))
            #expect(snapshot.project("WRK")?.resolved.githubPage == "https://github.com/example/worker")
            runner.setOrigin("https://github.com/example/renamed", for: orders)
            snapshot = try #require(await library.handle([FileEvent(path: orders + "/.git/config", kind: .modified)]))
            #expect(snapshot.project("ORD")?.resolved.githubPage == "https://github.com/example/renamed")
            _ = worker
        }
    }
}

/// Runs `body` with a temporary world, deleted afterwards.
func withTemporaryFolderAsync<T>(isolation: isolated (any Actor)? = #isolation,
                                 _ body: (World) async throws -> T) async throws -> T {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectDataTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    return try await body(World(folder.resolvingSymlinksInPath()))
}
