import Foundation
import MCPKit
import Testing
@testable import ChatData

/// The CLI's file tools a chat gets, and the app's answers when the CLI asks (docs/data.md › Chat processes ›
/// File tools). Paths are in a temporary folder.
struct ChatFileToolsTests {
    /// A project's folder with a `.hephaestus/` folder and a link to it from outside, deleted afterwards.
    final class Folder {
        let root: URL
        let project: URL
        let link: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatFileToolsTests-\(UUID().uuidString)").resolvingSymlinksInPath()
            project = root.appendingPathComponent("Repo")
            link = root.appendingPathComponent("Link")
            try FileManager.default.createDirectory(at: project.appendingPathComponent(".hephaestus"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: project)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test("Every CLI tool but its question tool; the editing tools taken away under Never")
    func tools() {
        #expect(ClaudeFileTools.disallowed(edits: .askFirst) == ["AskUserQuestion"])
        #expect(ClaudeFileTools.disallowed(edits: .always) == ["AskUserQuestion"])
        #expect(ClaudeFileTools.disallowed(edits: .never) == ["AskUserQuestion", "Edit", "Write", "NotebookEdit"])
        let launch = ChatLaunch(cliPath: "/bin/claude", chatID: "C", resume: false, model: "default", effort: .high,
                                mcpConfig: URL(fileURLWithPath: "/tmp/c.json"), tools: ["list_tickets"],
                                disallowedTools: ClaudeFileTools.disallowed(edits: .never), workingDirectory: "/tmp", environment: [:])
        #expect(!launch.arguments.contains("--tools"), "No list: the CLI's tools, as in V2")
        let index = launch.arguments.firstIndex(of: "--disallowedTools")
        #expect(index.map { launch.arguments[$0 + 1] } == "AskUserQuestion,Edit,Write,NotebookEdit")
        #expect(ClaudeFileTools.decision(tool: "Bash", input: ["command": "ls"], root: "/tmp", edits: .always) == nil, "A shell call keeps its card")
    }

    @Test("A read inside the project's folder runs; outside, it asks")
    func reads() throws {
        let folder = try Folder()
        let root = folder.project.path
        func decision(_ tool: String, _ input: JSONValue) -> ClaudeFileTools.Decision? {
            ClaudeFileTools.decision(tool: tool, input: input, root: root, edits: .never)
        }
        #expect(decision("Read", ["file_path": .string(root + "/Sources/App.swift")]) == .allow)
        #expect(decision("Read", ["file_path": "Sources/App.swift"]) == .allow)
        #expect(decision("Read", ["file_path": .string(root + "/.hephaestus/project.yml")]) == .allow)
        #expect(decision("Grep", ["pattern": "screenshot"]) == .allow)
        #expect(decision("Glob", ["pattern": "**/*.swift", "path": .string(folder.link.path + "/Sources")]) == .allow)
        #expect(decision("Read", ["file_path": "/etc/hosts"]) == .ask)
        #expect(decision("Read", ["file_path": .string(root + "/../Other/a.txt")]) == .ask)
        #expect(decision("Grep", ["pattern": "x", "path": .string(root + "Two")]) == .ask)
        #expect(decision("Bash", ["command": "ls"]) == nil)
        #expect(decision("mcp__hephaestus__add_comment", [:]) == nil)
    }

    @Test("An edit: refused under Never, asked under Ask First, run under Always inside the folder but not in .hephaestus")
    func edits() throws {
        let folder = try Folder()
        let root = folder.project.path
        let inside: JSONValue = ["file_path": .string(root + "/Sources/New.swift"), "content": "x"]
        let data: JSONValue = ["file_path": .string(root + "/.hephaestus/ticket/ORD-1.yml"), "old_string": "a", "new_string": "b"]
        let outside: JSONValue = ["file_path": "/tmp/example", "content": "hi"]
        #expect(ClaudeFileTools.decision(tool: "Write", input: inside, root: root, edits: .never) == .deny(ClaudeFileTools.editRefusal))
        #expect(ClaudeFileTools.decision(tool: "Write", input: inside, root: root, edits: .askFirst) == .ask)
        #expect(ClaudeFileTools.decision(tool: "Write", input: inside, root: root, edits: .always) == .allow)
        #expect(ClaudeFileTools.decision(tool: "Edit", input: data, root: root, edits: .always) == .ask)
        #expect(ClaudeFileTools.decision(tool: "Write", input: outside, root: root, edits: .always) == .ask)
        #expect(ClaudeFileTools.location(folder.link.path + "/Sources/New.swift", in: root) == .inside)
        #expect(ClaudeFileTools.location(root + "/.hephaestus", in: root) == .appData)
    }
}

/// The app answering the CLI's requests about file tools in a running chat.
@MainActor
struct ChatFileToolRequestTests {
    func request(_ id: String, _ tool: String, _ input: JSONValue) -> [Data] {
        [JSONValue.object(["type": "control_request", "request_id": .string(id),
                           "request": ["subtype": "can_use_tool", "tool_name": .string(tool), "input": input]]).data]
    }

    @Test("A read inside the project and an edit under Always are allowed at once; Never refuses; Ask First shows a card")
    func answers() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        var edits = ChatFileEdits.always
        world.session.fileEdits = { edits }
        let id = try await world.session.send("Look", references: [], to: nil, projectID: "ORD")
        let cli = try #require(world.launcher.chats.first)
        let root = world.repo.path
        cli.feed(request("r1", "Read", ["file_path": .string(root + "/README.md")]))
        cli.feed(request("r2", "Edit", ["file_path": "Sources/App.swift", "old_string": "a", "new_string": "b"]))
        try await world.until { cli.written.filter { $0["type"] == "control_response" }.count == 2 }
        let allowed = cli.written.filter { $0["type"] == "control_response" }
        #expect(allowed.map { $0["response"]?["request_id"] } == ["r1", "r2"])
        #expect(allowed.allSatisfy { $0["response"]?["response"]?["behavior"] == "allow" })
        edits = .never
        cli.feed(request("r3", "Write", ["file_path": .string(root + "/a.txt"), "content": "x"]))
        try await world.until { cli.written.filter { $0["type"] == "control_response" }.count == 3 }
        let refusal = cli.written.filter { $0["type"] == "control_response" }.last
        #expect(refusal?["response"]?["response"]?["behavior"] == "deny")
        #expect(refusal?["response"]?["response"]?["message"] == .string(ClaudeFileTools.editRefusal))
        #expect(!world.items(id).contains { if case .permissionRequest = $0 { true } else { false } })
        edits = .askFirst
        cli.feed(request("r4", "Edit", ["file_path": .string(root + "/a.txt"), "old_string": "x", "new_string": "y"]))
        try await world.until { world.session.state(of: id) == .waitingPermission }
        guard case .permissionRequest(let card)? = world.items(id).last else { Issue.record("no card"); return }
        #expect(card.requestID == "r4" && card.toolName == "Edit")
        world.session.answer(id, requestID: "r4", allow: true)
        #expect(cli.written.last?["response"]?["response"]?["behavior"] == "allow")
        cli.finish(.exited(0))
    }
}
