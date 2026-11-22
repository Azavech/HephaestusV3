import FileStorage
import Foundation
import Testing
@testable import MemoryData

/// A temporary folder, removed after the test.
final class TemporaryFolder {
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryDataTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        path = realpath(url.path, &buffer).map { _ in String(cString: buffer) } ?? url.path
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    func file(_ relative: String, _ text: String) throws {
        let full = (path as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: full))
    }

    func text(_ relative: String) -> String? {
        try? String(contentsOfFile: (path as NSString).appendingPathComponent(relative), encoding: .utf8)
    }

    func sub(_ relative: String) -> String { (path as NSString).appendingPathComponent(relative) }
}

/// Moves files to a folder of the test, never the user's Trash.
func testTrash(_ temporary: TemporaryFolder) -> Trash {
    let bin = temporary.sub("Trash")
    try? FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
    return .folder(URL(fileURLWithPath: bin))
}

@Suite("Memory folders")
struct MemoryLocationsTests {
    @Test("A folder name keeps ASCII letters and digits; a long one gets the Java hash")
    func folderName() {
        #expect(MemoryLocations.folderName("/Users/example/Developer/HephaestusV2") == "-Users-example-Developer-HephaestusV2")
        #expect(MemoryLocations.folderName("/tmp/é x") == "-tmp---x")
        let long = "/" + String(repeating: "a", count: 250)
        let name = MemoryLocations.folderName(long)
        #expect(name.hasPrefix("-" + String(repeating: "a", count: 199) + "-"))
        // Java's "abc".hashCode() is 96354, "1ihu" in base 36.
        #expect(MemoryLocations.folderName("/" + String(repeating: "b", count: 200)).count > 201)
        var hash: Int32 = 0
        for unit in "abc".utf16 { hash = hash &* 31 &+ Int32(unit) }
        #expect(hash == 96354)
    }

    @Test("The global folder and the config folder follow CLAUDE_CONFIG_DIR")
    func global() {
        #expect(MemoryLocations(home: "/Users/u", environment: [:]).globalFolder == "/Users/u/.claude/memory")
        #expect(MemoryLocations(home: "/Users/u", environment: ["CLAUDE_CONFIG_DIR": ""]).globalFolder == "/Users/u/.claude/memory")
        #expect(MemoryLocations(home: "/Users/u", environment: ["CLAUDE_CONFIG_DIR": "/c"]).globalFolder == "/c/memory")
        #expect(MemoryLocations(home: "/Users/u", environment: ["CLAUDE_CONFIG_DIR": "conf"]).globalFolder == "/Users/u/conf/memory")
    }

    @Test("A project in a repository uses the repository's folder; outside git, its own")
    func projects() throws {
        let temporary = try TemporaryFolder()
        let repo = temporary.sub("Suite")
        try temporary.file("Suite/.git/HEAD", "ref: refs/heads/main\n")
        try temporary.file("Suite/site/readme.md", "")
        try temporary.file("Notes/readme.md", "")
        let locations = MemoryLocations(home: temporary.sub("home"), environment: [:], managedFolder: temporary.sub("managed"))
        let expected = temporary.sub("home/.claude/projects/\(MemoryLocations.folderName(repo))/memory")
        #expect(locations.projectFolder(root: repo) == expected)
        #expect(locations.projectFolder(root: temporary.sub("Suite/site")) == expected)
        #expect(locations.projectFolder(root: temporary.sub("Notes"))
            == temporary.sub("home/.claude/projects/\(MemoryLocations.folderName(temporary.sub("Notes")))/memory"))
    }

    @Test("A linked worktree uses its main working tree's folder")
    func worktree() throws {
        let temporary = try TemporaryFolder()
        let main = temporary.sub("Main")
        try temporary.file("Main/.git/worktrees/wt/commondir", "../..\n")
        try temporary.file("Main/.git/worktrees/wt/gitdir", temporary.sub("Tree/.git") + "\n")
        try temporary.file("Tree/.git", "gitdir: \(temporary.sub("Main/.git/worktrees/wt"))\n")
        let locations = MemoryLocations(home: temporary.sub("home"), environment: [:], managedFolder: temporary.sub("managed"))
        #expect(locations.projectFolder(root: temporary.sub("Tree")) == locations.projectFolder(root: main))
    }

    @Test("autoMemoryDirectory: managed first, then local, project and user settings; a refused value gives the default")
    func autoMemoryDirectory() throws {
        let temporary = try TemporaryFolder()
        try temporary.file("P/readme.md", "")
        let root = temporary.sub("P")
        let home = temporary.sub("home")
        let locations = MemoryLocations(home: home, environment: [:], managedFolder: temporary.sub("managed"))
        let fallback = home + "/.claude/projects/\(MemoryLocations.folderName(root))/memory"
        #expect(locations.projectFolder(root: root) == fallback)
        try temporary.file("home/.claude/settings.json", #"{"autoMemoryDirectory": "~/mem"}"#)
        #expect(locations.projectFolder(root: root) == home + "/mem")
        try temporary.file("P/.claude/settings.json", #"{"autoMemoryDirectory": "/shared/mem/"}"#)
        #expect(locations.projectFolder(root: root) == "/shared/mem")
        try temporary.file("P/.claude/settings.local.json", #"{"autoMemoryDirectory": null}"#)
        #expect(locations.projectFolder(root: root) == "/shared/mem")
        try temporary.file("managed/managed-settings.json", #"{"autoMemoryDirectory": "relative/path"}"#)
        #expect(locations.projectFolder(root: root) == fallback)
        try temporary.file("managed/managed-settings.d/10.json", #"{"autoMemoryDirectory": "/org/mem"}"#)
        #expect(locations.projectFolder(root: root) == "/org/mem")
        #expect(locations.validated("~/../x") == nil)
        #expect(locations.validated("//server/share") == nil)
        #expect(locations.validated("/Volumes/a/./b/../c") == "/Volumes/a/c")
    }

    @Test("A sub project inherits its ancestors' folders but its own, nearest first, each once")
    func inherited() throws {
        let temporary = try TemporaryFolder()
        try temporary.file("Suite/.git/HEAD", "")
        try temporary.file("Suite/app/.git/HEAD", "")
        try temporary.file("Suite/app/web/readme.md", "")
        let locations = MemoryLocations(home: temporary.sub("home"), environment: [:], managedFolder: temporary.sub("managed"))
        let web = locations.projectFolder(root: temporary.sub("Suite/app/web"))
        let folders = locations.inherited(ownFolder: web, ancestors: [(id: "APP", name: "App", root: temporary.sub("Suite/app")),
                                                                      (id: "SUITE", name: "Suite", root: temporary.sub("Suite"))])
        #expect(folders.map(\.projectID) == ["SUITE"])
        #expect(folders.first?.folder == locations.projectFolder(root: temporary.sub("Suite")))
    }
}

@Suite("Memory files")
struct MemoryFolderTests {
    static let userRole = """
        ---
        name: user-role
        description: The user is a backend developer
        metadata:
          type: user
          originSessionId: 3F2504E0
        ---

        Writes Go daily.

        """

    @Test("Reading: name, description, type, other front matter and body; MEMORY.md and hidden files aren't memories")
    func reading() throws {
        let temporary = try TemporaryFolder()
        try temporary.file("m/user-role.md", Self.userRole)
        try temporary.file("m/MEMORY.md", "- [user-role](user-role.md) — role\n")
        try temporary.file("m/.hidden.md", "x")
        try temporary.file("m/sub/inner.md", "x")
        try temporary.file("m/plain.md", "Just a body")
        try temporary.file("m/old.md", "---\ntype: feedback\n---\nBody")
        try temporary.file("m/broken.md", "---\nname: x\n")
        let folder = MemoryFolder(path: temporary.sub("m"))
        let listing = try folder.list()
        #expect(listing.hasIndex)
        #expect(listing.memories.map(\.file) == ["old.md", "plain.md", "user-role.md"])
        #expect(listing.skipped["broken.md"] == "its front matter has no closing line")
        let memory = try folder.read("user-role.md")
        #expect(memory.summary == MemorySummary(file: "user-role.md", name: "user-role", description: "The user is a backend developer", type: .user))
        #expect(memory.body == "\nWrites Go daily.\n")
        #expect(memory.otherFrontMatter == "metadata:\n  originSessionId: 3F2504E0")
        #expect(try folder.read("old.md").summary.type == .feedback)
        #expect(try folder.read("plain.md").summary.type == .other)
        #expect(try folder.read("plain.md").body == "Just a body")
    }

    @Test("Create writes the file and appends its MEMORY.md line; names are checked")
    func create() throws {
        let temporary = try TemporaryFolder()
        try temporary.file("m/MEMORY.md", "- [a](a.md) — first")
        let folder = MemoryFolder(path: temporary.sub("m"))
        try folder.create(name: "go-style", description: "How the user\nwrites Go", type: .feedback)
        #expect(temporary.text("m/go-style.md") == "---\nname: go-style\ndescription: |-\n  How the user\n  writes Go\nmetadata:\n  type: feedback\n---\n")
        #expect(temporary.text("m/MEMORY.md") == "- [a](a.md) — first\n- [go-style](go-style.md) — How the user writes Go\n")
        #expect(throws: MemoryFileError.self) { try folder.create(name: "go-style", description: "x", type: .user) }
        #expect(throws: MemoryFileError.self) { try folder.create(name: "Go", description: "x", type: .user) }
        #expect(throws: MemoryFileError.self) { try folder.create(name: "memory", description: "x", type: .user) }
        // A new folder is made, with its MEMORY.md.
        let fresh = MemoryFolder(path: temporary.sub("new/memory"))
        try fresh.create(name: "a", description: "d", type: .user)
        #expect(temporary.text("new/memory/MEMORY.md") == "- [a](a.md) — d\n")
    }

    @Test("Update changes values in place and keeps the other keys; a body change keeps the front matter as written")
    func update() throws {
        let temporary = try TemporaryFolder()
        try temporary.file("m/user-role.md", Self.userRole)
        let folder = MemoryFolder(path: temporary.sub("m"))
        try folder.update("user-role.md", MemoryChange(body: "New body\r\n"))
        #expect(temporary.text("m/user-role.md") == Self.userRole.replacing("\nWrites Go daily.\n", with: "New body\n"))
        try folder.update("user-role.md", MemoryChange(description: "Changed", type: .project))
        #expect(temporary.text("m/user-role.md")
            == "---\nname: user-role\ndescription: Changed\nmetadata:\n  type: project\n  originSessionId: 3F2504E0\n---\nNew body\n")
        try temporary.file("m/plain.md", "Body")
        try folder.update("plain.md", MemoryChange(type: .user))
        #expect(temporary.text("m/plain.md") == "---\nmetadata:\n  type: user\n---\nBody")
        try temporary.file("m/bad.md", "---\nmetadata: 3\n---\n")
        #expect(throws: MemoryFileError.self) { try folder.update("bad.md", MemoryChange(type: .user)) }
    }

    @Test("Rename moves the file, retargets MEMORY.md and the [[links]] of the other memories")
    func rename() throws {
        let temporary = try TemporaryFolder()
        try temporary.file("m/user-role.md", Self.userRole)
        try temporary.file("m/other.md", "---\nname: other\n---\nSee [[user-role]] and [[user-roles]].\n")
        try temporary.file("m/MEMORY.md", "- [Role](user-role.md) — r\n- [Other](./other.md) — o\n- [Again](./user-role.md) — a\n")
        let folder = MemoryFolder(path: temporary.sub("m"))
        let file = try folder.update("user-role.md", MemoryChange(name: "job"))
        #expect(file == "job.md")
        #expect(temporary.text("m/user-role.md") == nil)
        #expect(temporary.text("m/job.md")?.hasPrefix("---\nname: job\n") == true)
        #expect(temporary.text("m/MEMORY.md") == "- [Role](job.md) — r\n- [Other](./other.md) — o\n- [Again](./job.md) — a\n")
        #expect(temporary.text("m/other.md") == "---\nname: other\n---\nSee [[job]] and [[user-roles]].\n")
        #expect(throws: MemoryFileError.self) { try folder.update("job.md", MemoryChange(name: "other")) }
    }

    @Test("Delete removes the MEMORY.md lines, then moves the file to the Trash")
    func delete() throws {
        let temporary = try TemporaryFolder()
        try temporary.file("m/a.md", "x")
        try temporary.file("m/MEMORY.md", "- [A](a.md) — a\n- [B](b.md) — b\n")
        let folder = MemoryFolder(path: temporary.sub("m"), trash: testTrash(temporary))
        try folder.delete("a.md")
        #expect(temporary.text("m/a.md") == nil)
        let trashed = try FileManager.default.subpathsOfDirectory(atPath: temporary.sub("Trash")).filter { $0.hasSuffix("/a.md") }
        #expect(trashed.count == 1)
        #expect(temporary.text("m/MEMORY.md") == "- [B](b.md) — b\n")
    }
}

@Suite("Memories in chats")
struct MemoryContextTests {
    @Test("MEMORY.md as a chat gets it: LF, trimmed, at most 200 lines")
    func index() {
        #expect(MemoryContext.indexForPrompt(nil) == "")
        #expect(MemoryContext.indexForPrompt("\u{FEFF}\r\n- a\r\n- b\r\n\n") == "- a\n- b")
        let many = (1...250).map { "- \($0)" }.joined(separator: "\n")
        #expect(MemoryContext.indexForPrompt(many).split(separator: "\n").count == 200)
        let wide = String(repeating: "x", count: 20_000) + "\n" + String(repeating: "y", count: 20_000)
        #expect(MemoryContext.indexForPrompt(wide) == String(repeating: "x", count: 20_000))
    }

    @Test("The skill's placeholders take the folders and their MEMORY.md; a blank skill gives nothing")
    func render() throws {
        let temporary = try TemporaryFolder()
        try temporary.file("Suite/.git/HEAD", "")
        try temporary.file("Suite/app/.git/HEAD", "")
        let home = temporary.sub("home")
        let locations = MemoryLocations(home: home, environment: [:], managedFolder: temporary.sub("managed"))
        let suiteFolder = locations.projectFolder(root: temporary.sub("Suite"))
        try FileManager.default.createDirectory(atPath: suiteFolder, withIntermediateDirectories: true)
        try Data("- [x](x.md) — suite\n".utf8).write(to: URL(fileURLWithPath: suiteFolder + "/MEMORY.md"))
        let context = MemoryContext.load(locations: locations, root: temporary.sub("Suite/app"),
                                          ancestors: [(id: "SUITE", name: "Suite", root: temporary.sub("Suite"))])
        #expect(context.globalFolderReady)
        #expect(FileManager.default.fileExists(atPath: home + "/.claude/memory"))
        #expect(context.render("G {{globalMemoriesFolder}} [{{globalMemories}}]\n{{parentMemories}}")
            == "G \(home)/.claude/memory []\nSuite (SUITE), \(suiteFolder):\n- [x](x.md) — suite")
        #expect(context.render(" \n") == nil)
        #expect(context.readRules == ["Read(/\(suiteFolder)/**)"])
    }
}
