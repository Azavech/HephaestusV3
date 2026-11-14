import Darwin
import FileStorage
import Foundation
import Testing
@testable import ProjectData

@Suite("Data folder")
struct DataFolderTests {
    @Test("HEPHAESTUS_DATA_DIR names the folder; otherwise HephaestusV3 in Application Support")
    func resolve() {
        let support = URL(fileURLWithPath: "/support", isDirectory: true)
        #expect(DataFolder.resolve(environment: ["HEPHAESTUS_DATA_DIR": "/dev/data"], applicationSupport: support)?.url.path == "/dev/data")
        #expect(DataFolder.resolve(environment: ["HEPHAESTUS_DATA_DIR": "relative"], applicationSupport: support)?.url.path == "/support/HephaestusV3")
        #expect(DataFolder.resolve(environment: [:], applicationSupport: support)?.url.path == "/support/HephaestusV3")
        #expect(DataFolder.resolve(environment: [:], applicationSupport: nil) == nil)
    }

    @Test("The App Group container's data is copied once, without the system's Library, and left in place")
    func migrate() throws {
        try withTemporaryFolder { root in
            let container = root.appendingPathComponent("group", isDirectory: true)
            try FileManager.default.createDirectory(at: container.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: container.appendingPathComponent("VirtualMachines/Images"), withIntermediateDirectories: true)
            try Data("projects: []\n".utf8).write(to: container.appendingPathComponent("registry.yml"))
            let folder = DataFolder(url: root.appendingPathComponent("Support/HephaestusV3"))
            #expect(folder.migrateFromAppGroup(container: container))
            #expect(try String(contentsOf: folder.registryFile, encoding: .utf8) == "projects: []\n")
            #expect(FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("VirtualMachines/Images").path))
            #expect(!FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("Library").path))
            #expect(FileManager.default.fileExists(atPath: container.appendingPathComponent("registry.yml").path))
            // Never again once the folder exists, and nothing from an empty, missing or unreadable container.
            #expect(!folder.migrateFromAppGroup(container: container))
            let other = DataFolder(url: root.appendingPathComponent("Other/HephaestusV3"))
            #expect(!other.migrateFromAppGroup(container: nil))
            #expect(!other.migrateFromAppGroup(container: root.appendingPathComponent("missing")))
            let empty = root.appendingPathComponent("empty/Library", isDirectory: true)
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            #expect(!other.migrateFromAppGroup(container: empty.deletingLastPathComponent()))
            #expect(!FileManager.default.fileExists(atPath: other.url.path))
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.url.deletingLastPathComponent().path)
            #expect(leftovers == ["HephaestusV3"])
        }
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

@Suite("Rules and GitHub")
struct RulesTests {
    @Test("Identifiers are 2 to 8 letters A–Z; a name suggests one")
    func identifiers() {
        #expect(ProjectRules.isIdentifier("HEPH"))
        #expect(!ProjectRules.isIdentifier("H"))
        #expect(!ProjectRules.isIdentifier("ABCDEFGHI"))
        #expect(!ProjectRules.isIdentifier("Heph"))
        #expect(!ProjectRules.isIdentifier("HÉPH"))
        // A name that starts with a capital gives its capitals, when there are two or more.
        #expect(ProjectRules.suggestedIdentifier(fromName: "AntiBeeCycle") == "ABC")
        #expect(ProjectRules.suggestedIdentifier(fromName: "YeenCloud") == "YC")
        #expect(ProjectRules.suggestedIdentifier(fromName: "Orders API") == "OAPI")
        #expect(ProjectRules.suggestedIdentifier(fromName: " ÉtéDeLAn") == "EDLA")
        #expect(ProjectRules.suggestedIdentifier(fromName: "ABCDEFGHIJ") == "ABCDEFGH")
        // Otherwise its first four letters.
        #expect(ProjectRules.suggestedIdentifier(fromName: "Orders") == "ORDE")
        #expect(ProjectRules.suggestedIdentifier(fromName: "Éclair") == "ECLA")
        #expect(ProjectRules.suggestedIdentifier(fromName: "orders API") == "ORDE")
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
