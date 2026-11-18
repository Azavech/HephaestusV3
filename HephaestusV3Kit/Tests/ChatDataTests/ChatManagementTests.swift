import FileStorage
import Foundation
import MCPKit
import Testing
@testable import ChatData

/// docs/data.md › Context usage, Closing and deleting chats.
@Suite("Context usage")
struct ContextUsageTests {
    @Test("The CLI's answer gives the tokens used, the window and the autocompact buffer; a broken one gives nothing")
    func answer() throws {
        let answer: JSONValue = ["totalTokens": 18554, "maxTokens": 1_000_000, "categories": [["id": "system", "tokens": 3000], ["id": "autocompact_buffer", "tokens": 33000]]]
        let usage = try #require(ContextUsage.from(answer, received: Date(timeIntervalSince1970: 0)))
        #expect(usage.usedTokens == 18554 && usage.windowTokens == 1_000_000 && usage.bufferTokens == 33000)
        #expect(usage.left == 948_446 && usage.percentLeft == 98)
        #expect(ContextUsage.from(["totalTokens": 1, "maxTokens": 10], received: Date())?.bufferTokens == 0)
        #expect(ContextUsage.from(["totalTokens": -1, "maxTokens": 10], received: Date()) == nil)
        #expect(ContextUsage.from(["totalTokens": 1, "maxTokens": 10, "categories": [["id": "autocompact_buffer", "tokens": 10]]], received: Date()) == nil)
    }

    @Test("A chat file keeps its context usage where V2 wrote it, and reads it back")
    func file() throws {
        var file = ChatFile(id: "3F2504E0-4F89-11D3-9A0C-0305E82C3301", title: "T", created: ISODate.date(from: "2026-11-17T10:00:00Z")!)
        file.contextUsage = ContextUsage(usedTokens: 5, windowTokens: 100, bufferTokens: 10, received: ISODate.date(from: "2026-11-17T10:01:00Z")!)
        let text = try YAMLCoding.encode(file)
        #expect(text.contains("contextUsage:\n  usedTokens: 5\n  windowTokens: 100\n  bufferTokens: 10\n  received: 2026-11-17T10:01:00Z"))
        let read = try YAMLCoding.decode(ChatFile.self, from: text)
        #expect(read.contextUsage == file.contextUsage)
    }
}

@Suite("Managing chats")
@MainActor
struct ChatManagementTests {
    @Test("Close at once without a turn; during one, once it ends; Stop cancels it; a message or Reopen opens it again")
    func close() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("Hi", references: [], to: nil, projectID: "ORD")
        try world.session.close(id)
        #expect(world.session.chats[id]?.file.closed == false, "A turn runs: it closes once the turn ends")
        world.session.stop(id)
        #expect(world.session.runs[id]?.closesAfterTurn == false, "Stop cancels the close")
        world.launcher.chats.forEach { $0.finish(.exited(0)) }
        try await world.until { world.session.runs[id] == nil }
        try world.session.close(id)
        #expect(world.session.chats[id]?.file.closed == true)
        try world.session.reopen(id)
        #expect(world.session.chats[id]?.file.closed == false)
        #expect(throws: ChatError.notFound("Chat X not found.")) { try world.session.close("X") }
    }

    @Test("Delete moves the chat's file, transcript and folder to the Trash and forgets it")
    func delete() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let log = world.root.appendingPathComponent("a.log")
        try Data("x".utf8).write(to: log)
        let id = try await world.session.send("Hi", references: [], to: nil, projectID: "ORD", files: [log])
        world.launcher.chats.forEach { $0.finish(.exited(0)) }
        try await world.until { world.session.runs[id] == nil }
        try world.session.delete(id)
        #expect(world.session.chats[id] == nil)
        let chats = world.repo.appendingPathComponent(".hephaestus/chats")
        #expect(!FileManager.default.fileExists(atPath: chats.appendingPathComponent("\(id).yml").path))
        #expect(!FileManager.default.fileExists(atPath: chats.appendingPathComponent(id).path))
        let trashed = try FileManager.default.subpathsOfDirectory(atPath: world.root.appendingPathComponent("Trash").path)
        #expect(trashed.contains { $0.hasSuffix("\(id).yml") } && trashed.contains { $0.hasSuffix("\(id).jsonl") })
    }

    @Test("close_chat: the caller's chat closes, another of its project closes, an unknown one is refused")
    func closeChats() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let first = try await world.session.send("One", references: [], to: nil, projectID: "ORD")
        let second = try await world.session.send("Two", references: [], to: nil, projectID: "ORD")
        world.launcher.chats.forEach { $0.finish(.exited(0)) }
        try await world.until { world.session.runs.isEmpty }
        let result = world.session.closeChats([second, "NOPE"], caller: first)
        #expect(result.closed == [second] && result.refused.map(\.chatID) == ["NOPE"])
        #expect(world.session.closeChats(nil, caller: first).closed == [first])
        #expect(world.session.chats[first]?.file.closed == true && world.session.chats[second]?.file.closed == true)
    }

    @Test("An error result lets Resume go on: it sends the call of resume-chat")
    func resume() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("Hi", references: [], to: nil, projectID: "ORD")
        world.session.record(.result(ResultItem(created: Date(), durationMs: 5, isError: true, summary: "error_max_turns")), in: id)
        world.launcher.chats.forEach { $0.finish(.exited(0)) }
        try await world.until { world.session.runs[id] == nil }
        #expect(world.session.needsResume(id))
        try await world.session.resume(id)
        guard case .user(let message)? = world.items(id).last(where: { if case .user = $0 { true } else { false } }) else { Issue.record("No message"); return }
        #expect(message.text == "/hephaestus-skills:resume-chat")
        world.launcher.chats.forEach { $0.finish(.exited(0)) }
    }

    @Test("Claude's first text of a message asks the CLI for the context usage; the answer is kept in the chat's file")
    func askingUsage() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("Hi", references: [], to: nil, projectID: "ORD")
        let cli = try #require(world.launcher.chats.first)
        cli.feed(#"{"type":"assistant","message":{"id":"msg_1","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"Hello"}]},"parent_tool_use_id":null}"#)
        try await world.until { cli.written.contains { $0["request"]?["subtype"] == "get_context_usage" } }
        let request = try #require(cli.written.last { $0["request"]?["subtype"] == "get_context_usage" }?["request_id"]?.stringValue)
        cli.feed(#"{"type":"control_response","response":{"subtype":"success","request_id":"\#(request)","response":{"totalTokens":500,"maxTokens":1000,"categories":[{"id":"autocompact_buffer","tokens":100}]}}}"#)
        try await world.until { world.session.chats[id]?.file.contextUsage != nil }
        #expect(world.session.chats[id]?.file.contextUsage?.percentLeft == 44)
        cli.finish(.exited(0))
    }
}

@Suite("Chat settings and answers")
@MainActor
struct ChatModesTests {
    @Test("A launch passes the chat's mode, lets Allow All take later, and passes Ultracode and the window when set")
    func launch() {
        var launch = ChatLaunch(cliPath: "/c", chatID: "C", resume: false, model: "default", effort: .high, mcpConfig: URL(fileURLWithPath: "/m.json"),
                                tools: [], workingDirectory: "/", environment: [:])
        #expect(launch.arguments.contains("--allow-dangerously-skip-permissions") && !launch.arguments.contains("--autocompact"))
        launch.permissionMode = .acceptEdits
        launch.ultracode = true
        launch.contextWindow = .window200K
        let arguments = launch.arguments
        let mode = try? #require(arguments.firstIndex(of: "--permission-mode"))
        #expect(mode.map { arguments[$0 + 1] } == "acceptEdits")
        #expect(arguments.contains(#"{"ultracode":true}"#) && arguments.firstIndex(of: "--autocompact").map { arguments[$0 + 1] } == "200000")
        #expect(ChatPermissionMode.manual.cliValue == "default" && ChatPermissionMode(stored: "nonsense") == .manual)
    }

    @Test("Always Allow passes the CLI's suggestions back; Don't Allow passes the user's message; Allow All approves what waits")
    func answers() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("Run it", references: [], to: nil, projectID: "ORD")
        let cli = try #require(world.launcher.chats.first)
        func ask(_ request: String) {
            cli.feed(#"{"type":"control_request","request_id":"\#(request)","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash"}],"behavior":"allow","destination":"session"}]}}"#)
        }
        ask("r1")
        try await world.until { world.session.state(of: id) == .waitingPermission }
        world.session.answer(id, requestID: "r1", decision: .allowAlways)
        let always = try #require(cli.written.last { $0["response"]?["request_id"]?.stringValue == "r1" })
        #expect(always["response"]?["response"]?["updatedPermissions"]?.arrayValue?.count == 1)
        ask("r2")
        try await world.until { world.session.state(of: id) == .waitingPermission }
        world.session.answer(id, requestID: "r2", decision: .deny, message: "  Not now  ")
        let denied = try #require(cli.written.last { $0["response"]?["request_id"]?.stringValue == "r2" })
        #expect(denied["response"]?["response"]?["message"]?.stringValue == "Not now")

        ask("r3")
        try await world.until { world.session.state(of: id) == .waitingPermission }
        var settings = try #require(world.session.chats[id]?.file.settings)
        settings.permissionMode = ChatPermissionMode.bypassPermissions.rawValue
        try world.session.setSettings(id, settings)
        let change = try #require(cli.written.last { $0["request"]?["subtype"]?.stringValue == "set_permission_mode" })
        #expect(change["request"]?["mode"]?.stringValue == "bypassPermissions")
        cli.feed(#"{"type":"control_response","response":{"subtype":"success","request_id":"\#(change["request_id"]?.stringValue ?? "")","response":{}}}"#)
        try await world.until { cli.written.contains { $0["response"]?["request_id"]?.stringValue == "r3" } }
        guard case .permissionRequest(let approved)? = world.items(id).first(where: { $0.id == "perm-r3" }) else { Issue.record("no card"); return }
        #expect(approved.decision == .allow && approved.decidedBy == "Studio")
        cli.finish(.exited(0))
    }
}
