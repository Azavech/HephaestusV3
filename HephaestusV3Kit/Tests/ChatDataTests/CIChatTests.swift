import FileStorage
import Foundation
import MCPKit
import ProjectData
import Testing
@testable import ChatData

/// docs/data.md › CI chats: the chat `watch_ci` starts, its checks, its reports to the chat that pushed, the one
/// question set an implement chat may post after a CI failure, and where the item lists it. In temporary folders,
/// with a fake CLI.
@Suite("CI chats")
@MainActor
struct CIChatTests {
    private let commit = "8E7CCF3A0B1C2D3E4F5061728394A5B6C7D8E9F0"
    private let page = "https://github.com/acme/orders"

    /// The text of the first message the app wrote to a chat's CLI.
    private func firstMessage(_ connection: FakeConnection) -> String? {
        connection.written.first { $0["type"]?.stringValue == "user" }?["message"]?["content"]?.arrayValue?.last?["text"]?.stringValue
    }

    /// A ticket chat of ORD-142, as Implement starts it.
    private func ticketChat(_ world: ChatWorld, settings: ChatSettings = ChatSettings()) async throws -> String {
        try await world.session.startImplementChat(
            ImplementChat(.ticket("ORD-142"), projectID: "ORD", itemTitle: "Retry storm", settings: settings)
        ) { _ throws(ChatError) in }
    }

    @Test("watch_ci makes a ci chat of the caller's ticket, on its settings, linked before its first message calls watch-ci with the project")
    func ciChat() async throws {
        let world = try await ChatWorld(githubPage: page)
        defer { Task { await world.close() } }
        let caller = try await ticketChat(world, settings: ChatSettings(model: "opus", effort: .medium))
        var linked: [CIChat.Item] = []
        let id = try await world.session.startCIChat(commit: commit, caller: caller) { item, chatID throws(ChatError) in
            #expect(world.session.chats[chatID] != nil, "The file exists when the item is linked")
            linked.append(item)
        }
        #expect(linked == [.ticket("ORD-142")])
        let file = try #require(world.session.chats[id]?.file)
        #expect(file.kind == .ci && file.ticketID == "ORD-142" && file.bundleID == nil && file.orchestratorChatID == caller)
        #expect(file.title == "CI of ORD-142: 8e7ccf3" && file.settings.model == "opus" && file.settings.effort == .medium)
        #expect(!file.questionsBlocked && file.kindViolation == nil)
        let written = try YAMLFile.read(ChatFile.self, at: world.repo.appendingPathComponent(".hephaestus/chats/\(id).yml"))
        #expect(written.kind == .ci && written.orchestratorChatID == caller)
        let cli = try #require(world.launcher.chats.last)
        try await world.until { firstMessage(cli) != nil }
        #expect(firstMessage(cli) == "/hephaestus-skills:watch-ci \(commit.lowercased())\n\nAttached: project ORD")
        guard case .user(let message)? = world.items(id).first else { Issue.record("No first message"); return }
        #expect(message.text == "/hephaestus-skills:watch-ci \(commit.lowercased())" && message.references.map(\.tool) == ["project"])
        world.launcher.chats.forEach { $0.finish(.exited(0)) }
    }

    @Test("A bundle's chat gets a CI chat of its bundle, listed after it with the ticket chats it started")
    func bundleChat() async throws {
        let world = try await ChatWorld(githubPage: page)
        defer { Task { await world.close() } }
        let bundleChat = try await world.session.startImplementChat(
            ImplementChat(.bundle("ORD-B3"), projectID: "ORD", itemTitle: "Checkout reliability", settings: ChatSettings())
        ) { _ throws(ChatError) in }
        var linked: [CIChat.Item] = []
        let id = try await world.session.startCIChat(commit: commit.lowercased(), caller: bundleChat) { item, _ throws(ChatError) in linked.append(item) }
        #expect(linked == [.bundle("ORD-B3")])
        let file = try #require(world.session.chats[id]?.file)
        #expect(file.kind == .ci && file.bundleID == "ORD-B3" && file.ticketID == nil && file.title == "CI of ORD-B3: 8e7ccf3")
        #expect(world.session.chats(ofBundle: "ORD-B3").map(\.id) == [bundleChat, id])
        world.launcher.chats.forEach { $0.finish(.exited(0)) }
    }

    @Test("The checks refuse the external token, other chats, a commit that isn't a full hash and a project without a GitHub page")
    func checks() async throws {
        let world = try await ChatWorld(runner: GitRecorder(), git: true)
        defer { Task { await world.close() } }
        let ticket = try await ticketChat(world)
        func start(_ caller: String?, _ commit: String? = nil) async throws(ChatError) {
            _ = try await world.session.startCIChat(commit: commit ?? self.commit, caller: caller) { _, _ throws(ChatError) in }
        }
        await #expect(throws: ChatError.conflict("Project ORD has no GitHub page.")) { try await start(ticket) }
        await #expect(throws: ChatError.forbidden(CIChat.externalRefusal)) { try await start(nil) }
        await #expect(throws: ChatError.notFound("Chat NOPE not found.")) { try await start("NOPE") }
        let project = try await world.session.send("Hi", references: [], to: nil, projectID: "ORD")
        await #expect(throws: ChatError.forbidden(CIChat.callerRefusal)) { try await start(project) }
        let bundleChat = try await world.session.startImplementChat(
            ImplementChat(.bundle("ORD-B3"), projectID: "ORD", itemTitle: "Checkout reliability", settings: ChatSettings())
        ) { _ throws(ChatError) in }
        let orchestrated = try await world.session.startImplementChat(
            ImplementChat(.ticket("ORD-141", orchestrator: ImplementChat.Orchestrator(chatID: bundleChat, bundleID: "ORD-B3")),
                          projectID: "ORD", itemTitle: "Timeouts", settings: ChatSettings())
        ) { _ throws(ChatError) in }
        await #expect(throws: ChatError.forbidden(CIChat.callerRefusal)) { try await start(orchestrated) }
        await #expect(throws: ChatError.invalid(CIChat.commitRefusal)) { try await start(ticket, "8e7ccf3") }
        await #expect(throws: ChatError.invalid(CIChat.commitRefusal)) { try await start(ticket, String(repeating: "g", count: 40)) }
        #expect(!world.session.chats.values.contains { $0.file.kind == .ci }, "A refusal creates nothing")
        world.launcher.chats.forEach { $0.finish(.exited(0)) }
    }

    @Test("A link that fails deletes the CI chat's file and throws its error")
    func failedLink() async throws {
        let world = try await ChatWorld(githubPage: page)
        defer { Task { await world.close() } }
        let caller = try await ticketChat(world)
        let count = world.launcher.chats.count
        await #expect(throws: ChatError.notFound("Ticket ORD-142 not found.")) {
            _ = try await world.session.startCIChat(commit: commit, caller: caller) { _, _ throws(ChatError) in
                throw .notFound("Ticket ORD-142 not found.")
            }
        }
        #expect(!world.session.chats.values.contains { $0.file.kind == .ci })
        let files = try FileManager.default.contentsOfDirectory(atPath: world.repo.appendingPathComponent(".hephaestus/chats").path)
        #expect(files.filter { $0.hasSuffix(".yml") }.count == 1, "Only the ticket chat's file")
        #expect(world.launcher.chats.count == count, "No message was sent")
        world.launcher.chats.forEach { $0.finish(.exited(0)) }
    }

    @Test("Each turn of a CI chat is reported to its orchestrator; a failure lets an implement chat ask once, a pass takes it back")
    func reports() async throws {
        let world = try await ChatWorld(githubPage: page)
        defer { Task { await world.close() } }
        var events: [ChatEvent] = []
        world.session.onEvent = { events.append($0) }
        let caller = try await ticketChat(world)
        let id = try await world.session.startCIChat(commit: commit, caller: caller) { _, _ throws(ChatError) in }
        let cli = try #require(world.launcher.chats.last)
        #expect(world.session.isOrchestrating(caller))
        cli.feed(try Fixture.lines("stream-bash-allowed.jsonl"))
        func reports() -> [String] {
            world.items(caller).compactMap { if case .user(let message) = $0, message.text.hasPrefix("CI chat") { message.text } else { nil } }
        }
        try await world.until { world.session.state(of: id) == .idle && !reports().isEmpty }
        let reply = world.items(id).compactMap { if case .assistant(let text) = $0, text.parentToolUseID == nil { text.text } else { nil } }.last ?? ""
        #expect(reports() == ["CI chat finished its turn:\n\n\(reply)".trimmingCharacters(in: .whitespacesAndNewlines)])
        #expect(!events.contains { $0.chatID == id && $0.kind == .finished }, "Its turn is reported, not notified")

        // The fixture's reply isn't "CI passed.": a failure, so the implement chat may ask once, and only questions.
        #expect(CIChat.isFailure(reports()[0]))
        #expect(world.session.questionsRefusal(in: caller, questions: true) == nil)
        #expect(world.session.questionsRefusal(in: caller) == ImplementChat.questionsRefusal, "The picker requests stay refused")
        let questions = [ChatQuestion(label: "CI", question: "How do we go on?", options: [.init(label: "Fix"), .init(label: "Finish")],
                                      recommended: ["Fix"])]
        _ = try await world.session.postQuestions(caller, questions: questions)
        #expect(world.session.questionsRefusal(in: caller, questions: true) == ImplementChat.questionsRefusal, "The set used it up")

        // Another failure allows one again; a pass takes it back.
        let date = Date(timeIntervalSince1970: 0)
        func end(with text: String) {
            world.session.transcripts[id, default: []].append(.user(UserItem(created: date, text: "again", sender: "Studio")))
            world.session.transcripts[id, default: []].append(.assistant(AssistantItem(id: UUID().uuidString, created: date, text: text, messageID: "m")))
            world.session.reportToOrchestrator(id, from: .running, to: .idle)
        }
        end(with: "CI failed.\n\nThe Tests run failed: `testRetries`.")
        #expect(world.session.questionsRefusal(in: caller, questions: true) == nil)
        end(with: "**CI passed.**")
        #expect(world.session.questionsRefusal(in: caller, questions: true) == ImplementChat.questionsRefusal)
        world.launcher.chats.forEach { $0.finish(.exited(0)) }
    }

    @Test("A report is a failure unless its reply starts with CI passed. or CI not checked.; V2's texts")
    func reportTexts() {
        let date = Date(timeIntervalSince1970: 0)
        let reply = ChatItem.assistant(AssistantItem(id: "a", created: date, text: "CI passed.", messageID: "m"))
        let ok = ChatItem.result(ResultItem(created: date, durationMs: 5, isError: false))
        #expect(CIChat.report(turn: [reply, ok], stopped: false, failed: false) == "CI chat finished its turn:\n\nCI passed.")
        #expect(CIChat.report(turn: [reply], stopped: true, failed: false) == "CI chat was stopped.")
        let failure = ChatItem.result(ResultItem(created: date, durationMs: 5, isError: true, summary: "Credit balance is too low"))
        #expect(CIChat.report(turn: [reply, failure], stopped: false, failed: false) == "CI chat ended in error: Credit balance is too low")

        #expect(!CIChat.isFailure("CI chat finished its turn:\n\nCI passed."))
        #expect(!CIChat.isFailure("CI chat finished its turn:\n\n  **CI passed.**\nEvery run succeeded."))
        #expect(!CIChat.isFailure("CI chat finished its turn:\n\n## CI not checked. The commit has no workflow run."))
        #expect(CIChat.isFailure("CI chat finished its turn:\n\nCI failed.\n\nCI passed. on main, not here"))
        #expect(CIChat.isFailure("CI chat finished its turn:"))
        #expect(CIChat.isFailure("CI chat finished its turn:\n\nAll runs passed."))
        #expect(CIChat.isFailure("CI chat was stopped."))
        #expect(CIChat.isFailure("CI chat ended in error: Claude exited with code 1."))
    }

    @Test("A full hash is 40 or 64 hexadecimal characters, in any case")
    func fullHash() {
        #expect(CIChat.isFullHash(commit) && CIChat.isFullHash(commit.lowercased()))
        #expect(CIChat.isFullHash(String(repeating: "a", count: 64)))
        #expect(!CIChat.isFullHash(String(repeating: "a", count: 41)) && !CIChat.isFullHash("8e7ccf3"))
        #expect(!CIChat.isFullHash(String(repeating: "z", count: 40)) && !CIChat.isFullHash(""))
        #expect(CIChat(projectID: "ORD", orchestrator: "T", item: .ticket("ORD-1"), commit: commit, settings: ChatSettings()).commit == commit.lowercased())
    }

    @Test("A ticket's chats list each CI chat right after the chat that started it; one whose chat is gone stands on its own")
    func listing() {
        let session = ChatSession(projects: ProjectSession(dataFolder: nil), tokens: MCPTokens(), device: "Studio")
        func chat(_ id: String, _ kind: ChatFile.Kind, ticket: String? = nil, bundle: String? = nil, orchestrator: String? = nil,
                  created: TimeInterval, updated: TimeInterval) -> LoadedChat {
            var file = ChatFile(id: id, title: id, kind: kind, created: Date(timeIntervalSince1970: created))
            file.updated = Date(timeIntervalSince1970: updated)
            file.ticketID = ticket
            file.bundleID = bundle
            file.orchestratorChatID = orchestrator
            return LoadedChat(file: file, projectID: "ORD")
        }
        session.chats = Dictionary(uniqueKeysWithValues: [
            chat("T1", .ticket, ticket: "ORD-142", created: 0, updated: 10),
            chat("C1", .ci, ticket: "ORD-142", orchestrator: "T1", created: 5, updated: 20),
            chat("C2", .ci, ticket: "ORD-142", orchestrator: "T1", created: 6, updated: 6),
            chat("B", .bundle, bundle: "ORD-B3", created: 0, updated: 1),
            chat("T2", .ticket, ticket: "ORD-142", orchestrator: "B", created: 1, updated: 30),
            chat("CB", .ci, bundle: "ORD-B3", orchestrator: "B", created: 2, updated: 2),
            chat("C3", .ci, ticket: "ORD-142", orchestrator: "GONE", created: 7, updated: 7),
        ].map { ($0.id, $0) })
        #expect(session.chats(ofTicket: "ORD-142").map(\.id) == ["T2", "T1", "C1", "C2", "C3"])
        #expect(session.chats(ofBundle: "ORD-B3").map(\.id) == ["B", "T2", "CB"])
    }
}
