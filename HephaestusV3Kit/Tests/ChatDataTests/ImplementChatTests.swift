import ExternalTools
import FileStorage
import Foundation
import MCPKit
import ProjectData
import Synchronization
import Testing
@testable import ChatData

/// Answers `claude --version`, and git's commands as `answer` says: by default `show-ref` finds no branch and every
/// other command succeeds. It records git's commands; nothing real starts.
final class GitRecorder: ProcessRunning, @unchecked Sendable {
    private let recorded = Mutex<[[String]]>([])
    private let answer: @Sendable ([String]) -> ProcessResult?

    init(answer: @escaping @Sendable ([String]) -> ProcessResult? = { _ in nil }) {
        self.answer = answer
    }

    /// The commands, but the projects' own `git config` reading their origin.
    var commands: [[String]] { recorded.withLock { $0 }.filter { $0.first != "config" } }

    func run(_ request: ProcessRequest, input: Data?, timeout: Duration?) async throws -> ProcessResult {
        if request.arguments == ["--version"] {
            return ProcessResult(termination: .exited(0), standardOutput: Data("2.1.322 (Claude Code)\n".utf8))
        }
        guard request.executable.hasSuffix("/git") else { return ProcessResult(termination: .exited(1)) }
        recorded.withLock { $0.append(request.arguments) }
        return answer(request.arguments) ?? ProcessResult(termination: .exited(request.arguments.first == "show-ref" ? 1 : 0))
    }
}

/// A text the test sets once the world exists, which the stand-in git then prints.
private final class Listing: @unchecked Sendable {
    private let text = Mutex("")
    var value: String {
        get { text.withLock { $0 } }
        set { text.withLock { $0 = newValue } }
    }
}

/// docs/data.md › Implement chats: the chats of Implement and Implement All, the branch and worktree of a ticket chat
/// a bundle's chat starts, its working folder, the reports to the orchestrator and the questions it doesn't ask. In
/// temporary folders, with a fake CLI.
@Suite("Implement chats")
@MainActor
struct ImplementChatTests {
    /// The text of the first message the app wrote to a chat's CLI.
    private func firstMessage(_ connection: FakeConnection) -> String? {
        connection.written.first { $0["type"]?.stringValue == "user" }?["message"]?["content"]?.arrayValue?.last?["text"]?.stringValue
    }

    @Test("Implement makes a ticket chat that calls implement-ticket, linked before its first message, asking nothing")
    func ticketChat() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        var linked: [String] = []
        let request = ImplementChat(.ticket("ORD-142"), projectID: "ORD", itemTitle: "Retry storm between checkout and payments",
                                    settings: ChatSettings(model: "opus", effort: .medium))
        let id = try await world.session.startImplementChat(request) { chatID throws(ChatError) in
            #expect(world.launcher.chats.isEmpty, "The link comes before the message")
            linked.append(chatID)
        }
        #expect(linked == [id])
        let file = try #require(world.session.chats[id]?.file)
        #expect(file.kind == .ticket && file.ticketID == "ORD-142" && file.bundleID == nil && file.orchestratorChatID == nil)
        #expect(file.questionsBlocked && file.kindViolation == nil)
        #expect(file.title == "Implement ORD-142: Retry storm between checkout and payments")
        #expect(file.settings.model == "opus" && file.settings.effort == .medium)
        let written = try YAMLFile.read(ChatFile.self, at: world.repo.appendingPathComponent(".hephaestus/chats/\(id).yml"))
        #expect(written.questionsBlocked && written.ticketID == "ORD-142")

        let cli = try #require(world.launcher.chats.last)
        try await world.until { firstMessage(cli) != nil }
        #expect(firstMessage(cli) == "/hephaestus-skills:implement-ticket ORD-142")
        #expect(cli.request.currentDirectory == world.repo.path, "A chat without an orchestrator works in the project's folder")
        let plugins = try #require(cli.request.arguments.firstIndex(of: "--plugin-dir").map { cli.request.arguments[$0 + 1] })
        let skill = try String(contentsOfFile: plugins + "/hephaestus-skills/skills/implement-ticket/SKILL.md", encoding: .utf8)
        #expect(skill.hasPrefix("---\nname: implement-ticket\n---\nImplement the ticket the arguments name."))
        #expect(world.session.chats(ofTicket: "ORD-142").map(\.id) == [id])
        cli.finish(.exited(0))
    }

    @Test("Implement All makes a bundle chat that calls implement-bundle")
    func bundleChat() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let request = ImplementChat(.bundle("ORD-B3"), projectID: "ORD", itemTitle: "Checkout reliability", settings: ChatSettings())
        let id = try await world.session.startImplementChat(request) { _ throws(ChatError) in }
        let file = try #require(world.session.chats[id]?.file)
        #expect(file.kind == .bundle && file.bundleID == "ORD-B3" && file.ticketID == nil && !file.questionsBlocked)
        #expect(file.title == "Implement All ORD-B3: Checkout reliability")
        let cli = try #require(world.launcher.chats.last)
        try await world.until { firstMessage(cli) != nil }
        #expect(firstMessage(cli) == "/hephaestus-skills:implement-bundle ORD-B3")
        #expect(world.session.chats(ofBundle: "ORD-B3").map(\.id) == [id])
        cli.finish(.exited(0))
    }

    @Test("A link that fails deletes the chat's file and starts nothing")
    func failedLink() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let request = ImplementChat(.bundle("ORD-B3"), projectID: "ORD", itemTitle: "Checkout reliability", settings: ChatSettings())
        await #expect(throws: ChatError.conflict("ORD-B3 is in progress; set it to To Do to implement it.")) {
            try await world.session.startImplementChat(request) { _ throws(ChatError) in
                throw .conflict("ORD-B3 is in progress; set it to To Do to implement it.")
            }
        }
        #expect(world.session.chats.isEmpty && world.launcher.chats.isEmpty)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: world.repo.appendingPathComponent(".hephaestus/chats").path)) ?? []
        #expect(!names.contains { $0.hasSuffix(".yml") })
    }

    @Test("Long titles are cut to 80 characters, on one line")
    func title() {
        let request = ImplementChat(.ticket("ORD-1"), projectID: "ORD", itemTitle: String(repeating: "x", count: 100), settings: ChatSettings())
        let file = request.file(id: "ID", created: Date(timeIntervalSince1970: 0))
        #expect(file.title.count == 80 && file.title.hasPrefix("Implement ORD-1: xxx"))
    }

    @Test("A bundle chat's implement_ticket, for a ticket of its bundle: the orchestrator, its settings, the branch and worktree, the working folder")
    func orchestrated() async throws {
        let git = GitRecorder()
        let world = try await ChatWorld(runner: git, git: true)
        defer { Task { await world.close() } }
        let bundleChat = try await world.session.startImplementChat(
            ImplementChat(.bundle("ORD-B3"), projectID: "ORD", itemTitle: "Checkout reliability", settings: ChatSettings(model: "opus", effort: .low))
        ) { _ throws(ChatError) in }
        let tickets: @MainActor (String) -> [String]? = { bundle in bundle == "ORD-B3" ? ["ORD-141", "ORD-142"] : nil }
        let orchestrator = try #require(world.session.orchestrator(for: "ORD-142", caller: bundleChat, bundleTickets: tickets))
        #expect(orchestrator == ImplementChat.Orchestrator(chatID: bundleChat, bundleID: "ORD-B3"))
        #expect(world.session.orchestrator(for: "ORD-9", caller: bundleChat, bundleTickets: tickets) == nil, "Not a ticket of the bundle")
        #expect(world.session.orchestrator(for: "ORD-142", caller: nil, bundleTickets: tickets) == nil, "No calling chat")

        let settings = try #require(world.session.chats[bundleChat]?.file.settings)
        let id = try await world.session.startImplementChat(
            ImplementChat(.ticket("ORD-142", orchestrator: orchestrator), projectID: "ORD", itemTitle: "Retry storm", settings: settings)
        ) { _ throws(ChatError) in }
        let file = try #require(world.session.chats[id]?.file)
        #expect(file.orchestratorChatID == bundleChat && file.questionsBlocked && file.settings.model == "opus" && file.kindViolation == nil)
        let worktree = world.root.appendingPathComponent("Data/Worktrees/ORD/ORD-142")
        #expect(git.commands == [
            ["worktree", "list", "--porcelain"],
            ["show-ref", "--verify", "--quiet", "refs/heads/ORD-B3/ORD-142"],
            ["worktree", "add", "-b", "ORD-B3/ORD-142", worktree.path, "HEAD"],
        ])
        let cli = try #require(world.launcher.chats.last)
        try await world.until { firstMessage(cli) != nil }
        #expect(firstMessage(cli) == "/hephaestus-skills:implement-ticket ORD-142 ORD-B3")
        #expect(world.session.chats(ofBundle: "ORD-B3").map(\.id) == [bundleChat, id], "The bundle's chat, then the chats it started")

        // The stand-in git made no folder: the chat works in the project's until the worktree exists.
        #expect(world.session.root(ofChat: id) == world.repo.path)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        #expect(world.session.root(ofChat: id) == worktree.path)
        #expect(world.session.root(ofChat: bundleChat) == world.repo.path)
        world.launcher.chats.forEach { $0.finish(.exited(0)) }
    }

    @Test("An earlier worktree and branch of the ticket are removed first")
    func earlierWorktree() async throws {
        let listing = Listing()
        let git = GitRecorder { arguments in
            switch arguments.first {
            case "worktree" where arguments.dropFirst().first == "list":
                ProcessResult(termination: .exited(0), standardOutput: Data(listing.value.utf8))
            case "show-ref": ProcessResult(termination: .exited(0))
            default: nil
            }
        }
        let world = try await ChatWorld(runner: git, git: true)
        defer { Task { await world.close() } }
        let worktree = world.root.appendingPathComponent("Data/Worktrees/ORD/ORD-142")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        listing.value = "worktree \(world.repo.path)\nHEAD 1234\n\nworktree \(worktree.path)\nbranch refs/heads/ORD-B3/ORD-142\n"
        let orchestrator = ImplementChat.Orchestrator(chatID: "BUNDLE", bundleID: "ORD-B3")
        _ = try await world.session.startImplementChat(
            ImplementChat(.ticket("ORD-142", orchestrator: orchestrator), projectID: "ORD", itemTitle: "Retry storm", settings: ChatSettings())
        ) { _ throws(ChatError) in }
        #expect(git.commands == [
            ["worktree", "list", "--porcelain"],
            ["worktree", "remove", "--force", "--force", worktree.path],
            ["worktree", "prune"],
            ["show-ref", "--verify", "--quiet", "refs/heads/ORD-B3/ORD-142"],
            ["branch", "-D", "ORD-B3/ORD-142"],
            ["worktree", "add", "-b", "ORD-B3/ORD-142", worktree.path, "HEAD"],
        ])
        #expect(!FileManager.default.fileExists(atPath: worktree.path), "The folder left over is deleted")
        world.launcher.chats.forEach { $0.finish(.exited(0)) }
    }

    @Test("A git command that fails, or no git, makes nothing and says why")
    func worktreeFailures() async throws {
        let git = GitRecorder { arguments in
            arguments.first == "worktree" && arguments.dropFirst().first == "add"
                ? ProcessResult(termination: .exited(128), standardError: Data("fatal: a branch named 'ORD-B3/ORD-142' already exists\n".utf8))
                : nil
        }
        let world = try await ChatWorld(runner: git, git: true)
        defer { Task { await world.close() } }
        let request = ImplementChat(.ticket("ORD-142", orchestrator: ImplementChat.Orchestrator(chatID: "BUNDLE", bundleID: "ORD-B3")),
                                    projectID: "ORD", itemTitle: "Retry storm", settings: ChatSettings())
        await #expect(throws: ChatError.unavailable(
            "Cannot create the branch and worktree of ORD-142: fatal: a branch named 'ORD-B3/ORD-142' already exists")) {
            try await world.session.startImplementChat(request) { _ throws(ChatError) in Issue.record("Nothing is linked") }
        }
        #expect(world.session.chats.isEmpty && world.launcher.chats.isEmpty)

        let bare = try await ChatWorld()
        defer { Task { await bare.close() } }
        await #expect(throws: ChatError.unavailable("Cannot create the branch and worktree of ORD-142: git is not available")) {
            try await bare.session.startImplementChat(request) { _ throws(ChatError) in }
        }
    }

    @Test("With git itself: the worktree is made on its branch, then made again fresh; a sub project works in its subfolder")
    func realGit() async throws {
        let git = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: git) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImplementGit-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("Repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try Data("one\n".utf8).write(to: repo.appendingPathComponent("file.txt"))
        let environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                           "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
                           "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com"]
        let runner = SystemProcessRunner()
        @discardableResult
        func run(_ arguments: [String], in folder: URL) async throws -> String {
            let result = try await runner.run(ProcessRequest(executable: git, arguments: arguments, environment: environment,
                                                             currentDirectory: folder.path), timeout: .seconds(30))
            try #require(result.succeeded, "git \(arguments.joined(separator: " ")): \(result.standardErrorText)")
            return result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try await run(["init", "-q", "-b", "main"], in: repo)
        try await run(["add", "."], in: repo)
        try await run(["commit", "-q", "-m", "One"], in: repo)
        let head = try await run(["rev-parse", "HEAD"], in: repo)

        let worktree = root.appendingPathComponent("Data/Worktrees/ORD/ORD-142")
        func prepare() async throws {
            try await ChatWorktree.prepare(git: git, environment: environment, runner: runner, projectRoot: repo.path, worktree: worktree,
                                           branch: "ORD-B3/ORD-142", ticketID: "ORD-142")
        }
        try await prepare()
        #expect(try String(contentsOf: worktree.appendingPathComponent("file.txt"), encoding: .utf8) == "one\n")
        #expect(try await run(["rev-parse", "ORD-B3/ORD-142"], in: repo) == head)
        #expect(try await run(["branch", "--show-current"], in: worktree) == "ORD-B3/ORD-142")

        // The ticket's chat committed on its branch; a retry starts again from the project's commit.
        try Data("two\n".utf8).write(to: worktree.appendingPathComponent("file.txt"))
        try await run(["commit", "-q", "-am", "Two"], in: worktree)
        #expect(try await run(["rev-parse", "ORD-B3/ORD-142"], in: repo) != head)
        try await prepare()
        #expect(try String(contentsOf: worktree.appendingPathComponent("file.txt"), encoding: .utf8) == "one\n")
        #expect(try await run(["rev-parse", "ORD-B3/ORD-142"], in: repo) == head)

        #expect(ChatWorktree.workingFolder(worktree: worktree, projectRoot: repo.path) == worktree)
        #expect(ChatWorktree.workingFolder(worktree: worktree, projectRoot: repo.appendingPathComponent("Sub").path)
            == worktree.appendingPathComponent("Sub", isDirectory: true))
    }

    @Test("Each turn of a chat a bundle's chat started is reported to that chat, which posts no Finished for it")
    func reports() async throws {
        let world = try await ChatWorld(runner: GitRecorder(), git: true)
        defer { Task { await world.close() } }
        var events: [ChatEvent] = []
        world.session.onEvent = { events.append($0) }
        let bundleChat = try await world.session.startImplementChat(
            ImplementChat(.bundle("ORD-B3"), projectID: "ORD", itemTitle: "Checkout reliability", settings: ChatSettings())
        ) { _ throws(ChatError) in }
        let bundleCLI = try #require(world.launcher.chats.last)
        let id = try await world.session.startImplementChat(
            ImplementChat(.ticket("ORD-142", orchestrator: ImplementChat.Orchestrator(chatID: bundleChat, bundleID: "ORD-B3")),
                          projectID: "ORD", itemTitle: "Retry storm", settings: ChatSettings())
        ) { _ throws(ChatError) in }
        let cli = try #require(world.launcher.chats.last)
        #expect(world.session.isOrchestrating(bundleChat))
        cli.feed(try Fixture.lines("stream-bash-allowed.jsonl"))
        func reports() -> [String] {
            world.items(bundleChat).compactMap { if case .user(let message) = $0, message.text.hasPrefix("Chat of") { message.text } else { nil } }
        }
        try await world.until { world.session.state(of: id) == .idle && !reports().isEmpty }
        let reply = world.items(id).compactMap { if case .assistant(let text) = $0, text.parentToolUseID == nil { text.text } else { nil } }.last ?? ""
        #expect(reports() == ["Chat of ORD-142 finished its turn:\n\n\(reply)".trimmingCharacters(in: .whitespacesAndNewlines)])
        #expect(!events.contains { $0.chatID == id && $0.kind == .finished }, "Its turn is reported, not notified")
        try await world.until { bundleCLI.written.contains { $0["message"]?["content"]?.arrayValue?.last?["text"]?.stringValue?.hasPrefix("Chat of ORD-142") == true } }
        #expect(!world.session.isOrchestrating(bundleChat))
        world.session.backgroundWork.insert(id)
        #expect(world.session.isOrchestrating(bundleChat), "A chat with background work still counts as at work, as in V2")
        world.session.backgroundWork.remove(id)
        world.launcher.chats.forEach { $0.finish(.exited(0)) }
    }

    @Test("A report says the turn was stopped, ended in error with its reason, or finished with the final reply")
    func reportTexts() {
        let date = Date(timeIntervalSince1970: 0)
        let reply = ChatItem.assistant(AssistantItem(id: "a", created: date, text: "Done: ORD-142 is in review.", messageID: "m"))
        let agent = ChatItem.assistant(AssistantItem(id: "b", created: date, text: "An agent's text", messageID: "n", parentToolUseID: "t"))
        let ok = ChatItem.result(ResultItem(created: date, durationMs: 5, isError: false))
        #expect(ImplementChat.report(ticketID: "ORD-142", turn: [reply, agent, ok], stopped: false, failed: false)
            == "Chat of ORD-142 finished its turn:\n\nDone: ORD-142 is in review.")
        #expect(ImplementChat.report(ticketID: "ORD-142", turn: [ok], stopped: false, failed: false) == "Chat of ORD-142 finished its turn:")
        #expect(ImplementChat.report(ticketID: "ORD-142", turn: [reply], stopped: true, failed: false) == "Chat of ORD-142 was stopped.")
        let failure = ChatItem.result(ResultItem(created: date, durationMs: 5, isError: true, summary: "Credit balance is too low"))
        #expect(ImplementChat.report(ticketID: "ORD-142", turn: [reply, failure], stopped: false, failed: false)
            == "Chat of ORD-142 ended in error: Credit balance is too low")
        let exit = ChatItem.system(SystemItem(created: date, text: "Claude exited with code 1.", level: .error))
        #expect(ImplementChat.report(ticketID: "ORD-142", turn: [reply, failure, exit], stopped: false, failed: true)
            == "Chat of ORD-142 ended in error: Claude exited with code 1.")
    }

    @Test("A ticket's chat asks nothing until the user writes in it; Resume doesn't lift that")
    func questionsBlocked() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.startImplementChat(
            ImplementChat(.ticket("ORD-142"), projectID: "ORD", itemTitle: "Retry storm", settings: ChatSettings())
        ) { _ throws(ChatError) in }
        #expect(world.session.questionsRefusal(in: id) == ImplementChat.questionsRefusal)
        try await world.session.resume(id)
        #expect(world.session.questionsRefusal(in: id) != nil, "Resume is the app's call")
        _ = try await world.session.send("Use the second option", references: [], to: id, projectID: "ORD")
        #expect(world.session.questionsRefusal(in: id) == nil)
        let written = try YAMLFile.read(ChatFile.self, at: world.repo.appendingPathComponent(".hephaestus/chats/\(id).yml"))
        #expect(!written.questionsBlocked)
        world.launcher.chats.forEach { $0.finish(.exited(0)) }
    }

    @Test("A chat's own items: a ticket chat's ticket; a bundle chat's bundle and its tickets; no other chat's")
    func ownItems() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let ticketChat = try await world.session.startImplementChat(
            ImplementChat(.ticket("ORD-142"), projectID: "ORD", itemTitle: "Retry storm", settings: ChatSettings())
        ) { _ throws(ChatError) in }
        let bundleChat = try await world.session.startImplementChat(
            ImplementChat(.bundle("ORD-B3"), projectID: "ORD", itemTitle: "Checkout reliability", settings: ChatSettings())
        ) { _ throws(ChatError) in }
        let projectChat = try await world.session.send("Hi", references: [], to: nil, projectID: "ORD")
        let tickets: @MainActor (String) -> [String]? = { bundle in bundle == "ORD-B3" ? ["ORD-141", "ORD-142"] : nil }
        #expect(world.session.ownsItem("ORD-142", chat: ticketChat, bundleTickets: tickets))
        #expect(!world.session.ownsItem("ORD-141", chat: ticketChat, bundleTickets: tickets))
        #expect(!world.session.ownsItem("ORD-B3", chat: ticketChat, bundleTickets: tickets))
        #expect(world.session.ownsItem("ORD-B3", chat: bundleChat, bundleTickets: tickets))
        #expect(world.session.ownsItem("ORD-141", chat: bundleChat, bundleTickets: tickets))
        #expect(!world.session.ownsItem("ORD-9", chat: bundleChat, bundleTickets: tickets))
        #expect(!world.session.ownsItem("ORD-142", chat: projectChat, bundleTickets: tickets))
        world.launcher.chats.forEach { $0.finish(.exited(0)) }
    }
}
