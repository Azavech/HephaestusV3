import Darwin
import FileStorage
import Foundation
import Testing
@testable import ProjectData

@Suite("Data folder")
struct DataFolderTests {
    @Test("HEPHAESTUS_DATA_DIR names the folder; otherwise the App Group container")
    func resolve() {
        let container = URL(fileURLWithPath: "/containers/group", isDirectory: true)
        #expect(DataFolder.resolve(environment: ["HEPHAESTUS_DATA_DIR": "/dev/data"], container: { _ in container })?.url.path == "/dev/data")
        #expect(DataFolder.resolve(environment: ["HEPHAESTUS_DATA_DIR": "relative"], container: { _ in container })?.url == container)
        var asked: String?
        #expect(DataFolder.resolve(environment: [:], container: { asked = $0; return container })?.url == container)
        #expect(asked == "group.fr.azavech.hephaestusv3")
        #expect(DataFolder.resolve(environment: [:], container: { _ in nil }) == nil)
    }

    @Test("The folder is created with mode 0700, and its lock is exclusive")
    func createAndLock() throws {
        try withTemporaryFolder { root in
            let folder = DataFolder(url: root.appendingPathComponent("nested/data"))
            try folder.createIfNeeded()
            var status = stat()
            stat(folder.url.path, &status)
            #expect(status.st_mode & 0o777 == 0o700)
            #expect(folder.registryFile.lastPathComponent == "registry.yml")
            #expect(folder.invalidCopy(of: folder.registryFile).lastPathComponent == "registry.yml.invalid")
            let lock = try folder.lock()
            #expect(throws: StorageError.folderInUse(path: folder.url.path)) { try folder.lock() }
            lock.release()
        }
    }

    @Test(".hephaestus/.gitignore holds the line chats/")
    func gitignore() throws {
        try withTemporaryFolder { root in
            let folder = ProjectFolder(root: root)
            try folder.ensureGitignore()
            #expect(try String(contentsOf: folder.gitignoreFile, encoding: .utf8) == "chats/\n")
            #expect(try folder.ensureGitignore() == nil)
            try Data("attachments/".utf8).write(to: folder.gitignoreFile)
            try folder.ensureGitignore()
            #expect(try String(contentsOf: folder.gitignoreFile, encoding: .utf8) == "attachments/\nchats/\n")
        }
    }
}

@Suite("Import from HephaestusV2")
struct V2ImportTests {
    @Test("V2's list comes over in order, without V2's own project, invalid entries or duplicates")
    func importsTheList() throws {
        try withTemporaryFolder { root in
            let v2 = root.appendingPathComponent("V2", isDirectory: true)
            let orders = root.appendingPathComponent("orders").path
            let heph = root.appendingPathComponent("HephaestusV2").path
            let website = root.appendingPathComponent("website").path
            try makeProject("ORD", in: URL(fileURLWithPath: orders))
            try makeProject("HEPH", in: URL(fileURLWithPath: heph))
            try FileManager.default.createDirectory(at: v2, withIntermediateDirectories: true)
            try YAMLFile.write(RegistryFile(projects: [orders, heph, "relative/path", website, orders]),
                               to: v2.appendingPathComponent("registry.yml"))
            try YAMLFile.write(CurrentEnvironmentsFile(projects: ["ORD": "staging", "HEPH": "local"]),
                               to: v2.appendingPathComponent("current-environments.yml"))
            let folder = DataFolder(url: root.appendingPathComponent("V3", isDirectory: true))
            let writes = OwnWrites()
            let result = try #require(try V2Import.runIfNeeded(into: folder, from: v2, ownWrites: writes))
            #expect(result.foundV2List)
            #expect(result.imported == [orders, website])
            #expect(result.skippedV2Project == [heph])
            #expect(result.skippedInvalid == ["relative/path", orders])
            #expect(result.currentEnvironments == 1)
            #expect(try YAMLFile.read(RegistryFile.self, at: folder.registryFile).projects == [orders, website])
            #expect(try YAMLFile.read(CurrentEnvironmentsFile.self, at: folder.currentEnvironmentsFile).projects == ["ORD": "staging"])
            #expect(writes.isOwnWrite(path: folder.registryFile.path, data: try Data(contentsOf: folder.registryFile)))
        }
    }

    @Test("The import runs once: an emptied list never brings V2's projects back")
    func runsOnce() throws {
        try withTemporaryFolder { root in
            let v2 = root.appendingPathComponent("V2", isDirectory: true)
            try FileManager.default.createDirectory(at: v2, withIntermediateDirectories: true)
            try YAMLFile.write(RegistryFile(projects: ["/somewhere/orders"]), to: v2.appendingPathComponent("registry.yml"))
            let folder = DataFolder(url: root.appendingPathComponent("V3", isDirectory: true))
            #expect(try V2Import.runIfNeeded(into: folder, from: v2)?.imported == ["/somewhere/orders"])
            try YAMLFile.write(RegistryFile(projects: []), to: folder.registryFile)
            #expect(try V2Import.runIfNeeded(into: folder, from: v2) == nil)
            #expect(try YAMLFile.read(RegistryFile.self, at: folder.registryFile).projects.isEmpty)
        }
    }

    @Test("Without V2, the import writes an empty list, and doesn't run again")
    func withoutV2() throws {
        try withTemporaryFolder { root in
            let folder = DataFolder(url: root.appendingPathComponent("V3", isDirectory: true))
            let result = try #require(try V2Import.runIfNeeded(into: folder, from: root.appendingPathComponent("missing")))
            #expect(!result.foundV2List)
            #expect(result.imported.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: folder.currentEnvironmentsFile.path))
            #expect(try YAMLFile.read(RegistryFile.self, at: folder.registryFile) == RegistryFile())
            #expect(try V2Import.runIfNeeded(into: folder, from: root.appendingPathComponent("missing")) == nil)
        }
    }

    @Test("V2's data folder is in Application Support")
    func defaultFolder() {
        #expect(V2Import.defaultV2Folder(homeDirectory: "/Users/someone").path
            == "/Users/someone/Library/Application Support/HephaestusV2")
    }
}

@Suite("Rules and GitHub")
struct RulesTests {
    @Test("Identifiers are 2 to 8 letters A–Z; a name suggests one")
    func identifiers() {
        #expect(ProjectRules.isIdentifier("HEPH"))
        #expect(!ProjectRules.isIdentifier("H"))
        #expect(!ProjectRules.isIdentifier("ABCDEFGHI"))
        #expect(!ProjectRules.isIdentifier("Heph"))
        #expect(!ProjectRules.isIdentifier("HÉPH"))
        #expect(ProjectRules.suggestedIdentifier(fromName: "Orders API") == "ORDE")
        #expect(ProjectRules.suggestedIdentifier(fromName: "Éclair") == "ECLA")
        #expect(ProjectRules.suggestedIdentifier(fromName: "A1") == "")
    }

    @Test("Paths, URLs and Kubernetes values")
    func values() throws {
        #expect(ProjectRules.isRelativePath("apps/ios"))
        for path in ["", "/apps", "apps/", "apps//ios", "./apps", "apps/.."] {
            #expect(!ProjectRules.isRelativePath(path), "\(path)")
        }
        #expect(ProjectRules.isAbsolutePath("/Users/someone/orders"))
        #expect(!ProjectRules.isAbsolutePath("/Users/someone/orders/"))
        #expect(ProjectRules.isHTTPURL("https://staging.example.com"))
        #expect(!ProjectRules.isHTTPURL("ftp://example.com"))
        #expect(try ProjectRules.environmentURL("  ", field: "url") == nil)
        #expect(throws: ProjectRuleError.url(field: "url")) { try ProjectRules.environmentURL("example.com", field: "url") }
        #expect(throws: ProjectRuleError.port(field: "port")) { try ProjectRules.port(0, field: "port") }
        #expect(ProjectRules.isJaegerService("tracing/jaeger"))
        #expect(!ProjectRules.isJaegerService("jaeger"))
        #expect(ProjectRules.isArgoCDApplication("orders") && ProjectRules.isArgoCDApplication("argocd/orders"))
        #expect(!ProjectRules.isArgoCDApplication("a/b/c"))
        #expect(try ProjectRules.kubeconfig(" ~/.kube/config ", field: "kubeconfig") == "~/.kube/config")
        #expect(throws: ProjectRuleError.kubeconfig(field: "kubeconfig")) { try ProjectRules.kubeconfig("kube/config", field: "kubeconfig") }
        #expect(try ProjectRules.name("  Orders  ", field: "name") == "Orders")
        #expect(throws: ProjectRuleError.nameLength(field: "name")) { try ProjectRules.name("two\nlines", field: "name") }
    }

    @Test("GitHub pages and the forms of a remote")
    func github() throws {
        #expect(GitHubPage.normalized(" https://github.com/example/orders/ ") == "https://github.com/example/orders")
        #expect(GitHubPage.normalized("https://github.com/example/orders/tree/main") == nil)
        #expect(GitHubPage.normalized("https://github.com/example/..") == nil)
        #expect(GitHubPage.ownerAndName(of: "https://github.com/example/orders.swift")?.name == "orders.swift")
        #expect(throws: ProjectRuleError.githubPage) { try GitHubPage.validated("github.com/example/orders") }

        let scp = try #require(GitRemote(remoteURL: "git@github.com:example/orders.git"))
        #expect(scp == GitRemote(host: "github.com", owner: "example", name: "orders", isSSH: true))
        #expect(scp.gitHubPage() == "https://github.com/example/orders")
        let https = try #require(GitRemote(remoteURL: "https://user@GitHub.com:443/example/orders"))
        #expect(https.isGitHubHost && !https.isSSH)
        let alias = try #require(GitRemote(remoteURL: "ssh://git@work/example/orders.git"))
        #expect(alias.gitHubPage() == nil)
        #expect(alias.gitHubPage(resolvedHostName: "github.com") == "https://github.com/example/orders")
        #expect(GitRemote(remoteURL: "https://gitlab.com/group/sub/repo")  == nil)
        #expect(GitRemote(remoteURL: "/local/path/repo.git") == nil)
        #expect(try #require(GitRemote(remoteURL: "https://gitlab.com/example/orders")).gitHubPage(resolvedHostName: "github.com") == nil)
    }

    @Test("The tints of the format are ToolsFoundation's")
    func tints() {
        #expect(ProjectColor.normalized("info") == "info")
        #expect(ProjectColor.normalized("Info") == nil)
        #expect(ProjectColor.normalized("#a1b2c3") == "#A1B2C3")
        #expect(ProjectColor.normalized("#a1b2c") == nil)
    }
}
