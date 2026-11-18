import FileStorage
import Foundation
import MCPKit
import Testing
@testable import ChatData

/// The fixtures: captures of Claude Code 2.1.309, with paths set to `/tmp/example`.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func lines(_ name: String) throws -> [Data] {
        try data(name).split(separator: UInt8(ascii: "\n")).map { Data($0) }
    }
}

/// docs/data.md › Chat file: the metadata files, read and written in their layout.
@Suite("Chat files")
struct ChatFileTests {
    /// An example of a project chat.
    static let v2Chat = """
        schema: 1
        id: 3F2504E0-4F89-11D3-9A0C-0305E82C3301
        title: Plan the sprint
        kind: project
        ticket: null
        bundle: null
        created: 2026-10-31T13:00:00Z
        updated: 2026-10-31T13:02:10Z
        settings:
          model: opus
          effort: high
          permissionMode: manual
          ultracode: false
          contextWindow: auto
        sessionStarted: true
        closed: false
        contextUsage:
          usedTokens: 18554
          windowTokens: 1000000
          bufferTokens: 33000
          received: 2026-10-31T13:02:10Z

        """

    @Test("A chat file is read, and written back byte for byte, its context usage kept")
    func roundTrip() throws {
        let file = try YAMLCoding.decode(ChatFile.self, from: Data(Self.v2Chat.utf8))
        #expect(file.kind == .project && file.settings.model == "opus" && file.sessionStarted)
        #expect(file.unknownKeys.keys == ["contextUsage"])
        #expect(try YAMLCoding.encode(file) == Self.v2Chat)
    }

    @Test("The origin is written after the other keys, only when set")
    func origin() throws {
        var file = ChatFile(id: "3F2504E0-4F89-11D3-9A0C-0305E82C3301", title: "Why?", created: ISODate.date(from: "2026-11-14T10:00:00Z")!)
        file.origin = "tickets"
        let text = try YAMLCoding.encode(file)
        #expect(text.hasSuffix("sessionStarted: false\nclosed: false\norigin: tickets\n"))
        #expect(try YAMLCoding.decode(ChatFile.self, from: Data(text.utf8)) == file)
    }

    @Test("A file that breaks the rules of the kinds is invalid")
    func kinds() {
        let ticketChat = Self.v2Chat.replacing("kind: project", with: "kind: ticket")
        #expect(throws: (any Error).self) { try YAMLCoding.decode(ChatFile.self, from: Data(ticketChat.utf8)) }
        let lowercase = Self.v2Chat.replacing("id: 3F2504E0-4F89-11D3-9A0C-0305E82C3301", with: "id: 3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        #expect(throws: (any Error).self) { try YAMLCoding.decode(ChatFile.self, from: Data(lowercase.utf8)) }
    }
}

/// docs/data.md › Chat transcript file.
@Suite("Transcripts")
struct TranscriptTests {
    /// Part of an example transcript: a message with linked items, a session line, thinking, a call, a
    /// permission request then its answer, a question set, a result.
    static let v2Lines = """
        {"op":"add","item":{"type":"user","id":"E1D2C3B4-A596-4877-8695-A4B3C2D1E0F9","created":"2026-10-31T13:00:00Z","text":"Plan this sprint.","attachments":[],"sender":"MacBook","linkedItems":[{"kind":"ticket","name":"HEPH-13","text":"ticket HEPH-13","added":false}]}}
        {"op":"add","item":{"type":"system","id":"8C1D2E3F-4A5B-4C6D-8E7F-9A0B1C2D3E4F","created":"2026-10-31T13:00:02Z","text":"Session started · Opus 5.5 · effort high · Ask every time","level":"info"}}
        {"op":"add","item":{"type":"toolUse","id":"msg_01#1","created":"2026-10-31T13:00:06Z","toolUseID":"toolu_01","name":"list_tickets","server":"hephaestus","input":{"projectID":"HEPH","status":"todo"},"parentToolUseID":null}}
        {"op":"add","item":{"type":"permissionRequest","id":"perm-5b1f","created":"2026-10-31T13:00:09Z","requestID":"5b1f","toolName":"Bash","input":{"command":"git log"},"reason":null,"decision":null,"decidedBy":null}}
        {"op":"update","item":{"type":"permissionRequest","id":"perm-5b1f","created":"2026-10-31T13:00:09Z","requestID":"5b1f","toolName":"Bash","input":{"command":"git log"},"reason":null,"decision":"allow","decidedBy":"Studio"}}
        {"op":"add","item":{"type":"questions","id":"4D3C","created":"2026-10-31T13:00:32Z","questionSetID":"4D3C","questions":[],"answers":{},"completed":false}}
        not json
        {"op":"add","item":{"type":"result","id":"9E8D","created":"2026-10-31T13:00:34Z","durationMs":34120,"costUSD":0.2875,"isError":false,"summary":null}}

        """

    @Test("Replay: an update replaces its item in place; lines that aren't items are skipped")
    func replay() throws {
        let items = Transcript.replay(Data(Self.v2Lines.utf8))
        #expect(items.map(\.id) == ["E1D2C3B4-A596-4877-8695-A4B3C2D1E0F9", "8C1D2E3F-4A5B-4C6D-8E7F-9A0B1C2D3E4F", "msg_01#1", "perm-5b1f", "4D3C", "9E8D"])
        guard case .permissionRequest(let request) = items[3] else { Issue.record("not a request"); return }
        #expect(request.decision == .allow && request.decidedBy == "Studio")
        guard case .user(let user) = items[0] else { Issue.record("not a message"); return }
        #expect(user.linkedItems.arrayValue?.count == 1, "Linked items are kept")
    }

    @Test("A line written by V3 reads back as the same item; references are V3's")
    func lines() throws {
        let item = ChatItem.user(UserItem(id: "A", created: ISODate.date(from: "2026-11-14T10:00:00Z")!, text: "Why?\nReally.", sender: "Studio",
                                          references: [ChatItemReference(tool: "tickets", projectID: "ORD", focus: "ORD-142", title: "ORD-142")]))
        let line = Transcript.line(.add, item)
        #expect(line.last == UInt8(ascii: "\n") && line.filter { $0 == UInt8(ascii: "\n") }.count == 1)
        #expect(Transcript.replay(line) == [item])
    }

    @Test("An append after a line cut short starts on a line of its own")
    func append() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TranscriptTests-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"op":"add","item":{"type":"sys"#.utf8).write(to: url)
        let item = ChatItem.system(SystemItem(id: "S", created: ISODate.date(from: "2026-11-14T10:00:00Z")!, text: "Hello"))
        try Transcript.append(Transcript.line(.add, item), to: url, endingLine: true)
        try Transcript.append(Transcript.line(.update, item), to: url, endingLine: false)
        #expect(Transcript.replay(try Data(contentsOf: url)) == [item])
        #expect(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count == 3)
    }
}

/// docs/data.md › Stream mapping, on the captures.
@Suite("Stream mapping")
struct StreamMapperTests {
    private func run(_ name: String) throws -> [StreamOutput] {
        var mapper = StreamMapper(effort: .high, now: { ISODate.date(from: "2026-11-14T10:00:00Z")! })
        return try Fixture.lines(name).flatMap { mapper.map($0) }
    }

    private func items(_ outputs: [StreamOutput]) -> [ChatItem] {
        outputs.compactMap { if case .item(let item) = $0 { item } else if case .result(let result) = $0 { .result(result) } else { nil } }
    }

    @Test("A call, its result and the reply: items with their ids; the text streams first")
    func bashAllowed() throws {
        let outputs = try run("stream-bash-allowed.jsonl")
        #expect(outputs.first == .cliTurnOpened(first: true, mcpProblem: "missing"), "The capture has no MCP server")
        let items = items(outputs)
        #expect(items.map(\.id) == ["msg_011CgbN99ugMwKEYBQfCEoiP#0", "toolu_01JGkKXVVCvtBiysD3rhiEXj#result", "msg_011CgbN9DUEEzm4yYRLnxmCV#0", items[3].id])
        guard case .toolUse(let call) = items[0], case .toolResult(let result) = items[1], case .assistant(let reply) = items[2],
              case .result(let end) = items[3] else { Issue.record("unexpected items"); return }
        #expect(call.name == "Bash" && call.server == nil && call.input["command"] == "echo probe-ok")
        #expect(result.text == "probe-ok" && !result.isError)
        #expect(reply.text == "done" && reply.model == "claude-haiku-5-5" && reply.effort == .high)
        #expect(!end.isError && end.durationMs == 3523 && end.summary == nil)
        #expect(outputs.contains(.delta(itemID: "msg_011CgbN9DUEEzm4yYRLnxmCV#0", text: "done")))
    }

    @Test("The CLI's permission request becomes an item; thinking without text makes none")
    func writeDenied() throws {
        let outputs = try run("stream-write-denied.jsonl")
        let requests = outputs.compactMap { if case .permissionRequest(let request, _) = $0 { request } else { nil } }
        let suggestions = outputs.compactMap { if case .permissionRequest(_, let suggestions) = $0 { suggestions } else { nil } }
        #expect(suggestions.count == 1, "The CLI's suggestions come with the request, for Always Allow")
        #expect(requests.count == 1)
        #expect(requests[0].id == "perm-1967e0c0-4eab-4e9a-8c9e-67ec5e2cb4a0" && requests[0].toolName == "Write")
        #expect(requests[0].reason == "Path is outside allowed working directories" && requests[0].isPending)
        let items = items(outputs)
        #expect(!items.contains { if case .thinking = $0 { true } else { false } })
        guard case .toolResult(let denied) = items[1] else { Issue.record("no result"); return }
        #expect(denied.isError && denied.text == "User denied in probe")
    }

    @Test("A compaction: its status lines, then its line with the tokens before")
    func compaction() throws {
        let outputs = try run("stream-compact.jsonl")
        #expect(outputs.contains(.compactionStarted) && outputs.contains(.compactionEnded))
        #expect(outputs.contains(.commandState(uuid: "CDFBF483-6ADB-4F6A-A105-43859027C289", state: "started")))
        let lines = items(outputs).compactMap { if case .system(let line) = $0 { line.text } else { nil } }
        #expect(lines == ["Conversation compacted (manual, 24.6K tokens before)"])
        #expect(StreamMapper.tokens(967_000) == "967K" && StreamMapper.tokens(999) == "999" && StreamMapper.tokens(1_200_000) == "1.2M")
    }

    @Test("A result after Stop says so; another error says the CLI's reason")
    func results() {
        var mapper = StreamMapper()
        mapper.stopping = true
        let stopped = mapper.map(Data(#"{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":5,"errors":["[ede_diagnostic] x"]}"#.utf8))
        #expect(stopped.contains { if case .result(let result) = $0 { result.summary == "Stopped by the user." } else { false } })
        let failed = mapper.map(Data(#"{"type":"result","subtype":"error_max_turns","is_error":true,"duration_ms":5}"#.utf8))
        #expect(failed.contains { if case .result(let result) = $0 { result.summary == "error_max_turns" } else { false } })
        #expect(mapper.map(Data("[]".utf8)) == [.invalid])
    }

    @Test("Names: mcp__<server>__<tool> splits after the server; the app's server is found in init")
    func names() {
        let mcp = ToolUseItem.split("mcp__hephaestus__create_ticket")
        #expect(mcp.name == "create_ticket" && mcp.server == "hephaestus")
        let bash = ToolUseItem.split("Bash")
        #expect(bash.name == "Bash" && bash.server == nil)
        #expect(StreamMapper.mcpProblem([["name": "hephaestus", "status": "connected"]]) == nil)
        #expect(StreamMapper.mcpProblem([["name": "hephaestus", "status": "failed"]]) == "failed")
    }
}
