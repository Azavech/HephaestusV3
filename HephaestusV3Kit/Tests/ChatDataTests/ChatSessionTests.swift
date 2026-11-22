import Darwin
import ExternalTools
import FileStorage
import Foundation
import MemoryData
import MCPKit
import ProjectData
import Synchronization
import Testing
@testable import ChatData

/// Answers `claude --version`; every other process fails. Nothing real starts.
struct ChatRunner: ProcessRunning {
    func run(_ request: ProcessRequest, input: Data?, timeout: Duration?) async throws -> ProcessResult {
        if request.arguments == ["--version"] {
            return ProcessResult(termination: .exited(0), standardOutput: Data("2.1.322 (Claude Code)\n".utf8))
        }
        return ProcessResult(termination: .exited(1))
    }
}

/// A CLI that writes what the test feeds it, and records what the app writes.
final class FakeConnection: ClaudeConnection, @unchecked Sendable {
    let lines: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let state = Mutex<(written: [Data], signals: [Int32], termination: ProcessTermination?, inputClosed: Bool)>(([], [], nil, false))
    private let exit = Mutex<[CheckedContinuation<ProcessTermination, Never>]>([])
    let request: ProcessRequest
    var errorLines: [String] = []
    private let logLines = Mutex<[String]>([])
    /// The lines the app added to the chat's log.
    var logged: [String] { logLines.withLock { $0 } }

    func log(_ line: String) { logLines.withLock { $0.append(line) } }

    init(_ request: ProcessRequest) {
        self.request = request
        (lines, continuation) = AsyncStream.makeStream(of: Data.self)
    }

    /// The JSON objects the app wrote, one per line.
    var written: [JSONValue] {
        state.withLock { $0.written }.flatMap { $0.split(separator: UInt8(ascii: "\n")) }.compactMap { try? JSONValue.parse(Data($0)) }
    }

    var signals: [Int32] { state.withLock { $0.signals } }
    var inputClosed: Bool { state.withLock { $0.inputClosed } }

    func feed(_ lines: [Data]) { lines.forEach { continuation.yield($0) } }
    func feed(_ line: String) { continuation.yield(Data(line.utf8)) }

    /// Ends the output, then the process.
    func finish(_ termination: ProcessTermination) {
        continuation.finish()
        state.withLock { $0.termination = termination }
        exit.withLock { waiting in
            waiting.forEach { $0.resume(returning: termination) }
            waiting = []
        }
    }

    func write(_ data: Data) { state.withLock { $0.written.append(data) } }
    func closeInput() { state.withLock { $0.inputClosed = true } }
    func signal(_ signal: Int32) { state.withLock { $0.signals.append(signal) } }
    var hasExited: Bool { state.withLock { $0.termination != nil } }

    func waitForExit() async -> ProcessTermination {
        await withCheckedContinuation { continuation in
            let done = state.withLock { $0.termination }
            if let done { continuation.resume(returning: done) } else { exit.withLock { $0.append(continuation) } }
        }
    }
}

/// Hands out fake connections. The models probe answers `initialize` with a capture of the model list.
final class FakeLauncher: ClaudeLaunching, @unchecked Sendable {
    private let launched = Mutex<[FakeConnection]>([])
    var chats: [FakeConnection] { launched.withLock { $0 }.filter { $0.request.arguments.contains("--include-partial-messages") } }
    /// The models probes.
    var probes: [FakeConnection] { launched.withLock { $0 }.filter { $0.request.arguments.contains("--no-session-persistence") } }

    func launch(_ request: ProcessRequest, log: URL?, logLine: String) throws -> any ClaudeConnection {
        let connection = FakeConnection(request)
        launched.withLock { $0.append(connection) }
        if request.arguments.contains("--no-session-persistence"), let answer = try? Fixture.data("initialize-response.json"),
           let value = try? JSONValue.parse(answer) {
            var response = value
            if case .object(var object) = value, case .object(var inner)? = object["response"] {
                inner["request_id"] = "hephaestus-models"
                // The capture lists no command: two stand in, a skill and one of the CLI's own.
                if case .object(var answer)? = inner["response"] {
                    answer["commands"] = [["name": "hephaestus-skills:report-feedback", "description": "Turns feedback into tickets.", "argumentHint": ""],
                                          ["name": "compact", "description": "Free up context", "argumentHint": "<instructions>", "builtin": true]]
                    inner["response"] = .object(answer)
                }
                object["response"] = .object(inner)
                response = .object(object)
            }
            connection.feed([response.data])
        }
        return connection
    }
}

/// A temporary world: a data folder whose settings name a stand-in CLI, and one project `ORD`, all deleted
/// afterwards. Tests never touch the user's projects, data folder or Claude.
@MainActor
final class ChatWorld {
    let root: URL
    let repo: URL
    let projects: ProjectSession
    let tokens = MCPTokens()
    let launcher = FakeLauncher()
    let session: ChatSession

    /// `projectType` is the `type` of the project file, such as `swiftApplication`; none when nil. The picker
    /// catalogues read fixtures of the world's folder (`PickerCatalogs.Sources.fixtures`). `runner` runs the
    /// processes, `ChatRunner` by default; `git` puts a stand-in git in the tools' `PATH`, which `runner` answers.
    /// `githubPage` is the project file's GitHub page.
    init(projectType: String? = nil, githubPage: String? = nil, runner: any ProcessRunning = ChatRunner(), git: Bool = false) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatSessionTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        repo = root.appendingPathComponent("Repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".hephaestus"), withIntermediateDirectories: true)
        let type = projectType.map { "type: \($0)\n" } ?? ""
        let page = githubPage.map { "githubPage: \($0)\n" } ?? ""
        try Data("schema: 1\nid: ORD\nname: Orders\ncreated: 2026-10-31T09:30:00Z\n\(type)\(page)".utf8)
            .write(to: repo.appendingPathComponent(".hephaestus/project.yml"))
        let cli = root.appendingPathComponent("claude")
        FileManager.default.createFile(atPath: cli.path, contents: Data("#!/bin/sh\nexit 1\n".utf8), attributes: [.posixPermissions: 0o755])
        let data = DataFolder(url: root.appendingPathComponent("Data"))
        try data.createIfNeeded()
        try YAMLFile.write(RegistryFile(projects: [repo.path]), to: data.registryFile)
        try data.writeSettings(SettingsFile(claudePath: cli.path))
        var environment: [String: String] = [:]
        if git {
            let bin = root.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: bin.appendingPathComponent("git").path, contents: Data("#!/bin/sh\nexit 1\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
            environment["PATH"] = bin.path
        }
        projects = ProjectSession(dataFolder: data, runner: runner, processEnvironment: environment)
        await projects.start()
        session = ChatSession(projects: projects, tokens: tokens, launcher: launcher, runner: runner, device: "Studio",
                              processEnvironment: [:], trash: .folder(root.appendingPathComponent("Trash")),
                              catalogs: try .fixtures(in: root.appendingPathComponent("Catalogs")))
        // The memories of a temporary home, never the user's.
        let home = root.appendingPathComponent("home").path
        let managed = root.appendingPathComponent("managed").path
        session.memoryLocations = { MemoryLocations(home: home, environment: $0, managedFolder: managed) }
        await session.start(tools: ["list_tickets", "add_comment"], port: 47999)
        try await until { !self.session.status.checking && self.session.models != ClaudeModel.fallback }
    }

    func close() async {
        await projects.stop()
        try? FileManager.default.removeItem(at: root)
    }

    /// Waits, at most 2 s, for the session to process what the fake wrote.
    func until(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }

    func items(_ chatID: String) -> [ChatItem] { session.transcripts[chatID] ?? [] }
}

@Suite("Chats on the Claude CLI")
@MainActor
struct ChatSessionTests {
    @Test("The CLI is found from Settings, its version read, and its models taken from initialize")
    func cli() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        #expect(world.session.status.version == "2.1.322")
        #expect(world.session.models.first?.value == "default")
        #expect(ClaudeModel.name(of: "claude-opus-5-5", in: world.session.models) == "Opus 5.5")
    }

    @Test("The probe lists the CLI's commands with the chats' plugin; a chat's answer gives its project's own")
    func commands() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        try await world.until { !world.session.commands.isEmpty }
        #expect(world.session.commands.map(\.name) == ["hephaestus-skills:report-feedback", "compact"])
        #expect(world.session.commands.map(\.isBuiltIn) == [false, true] && world.session.commands[1].argumentHint == "<instructions>")
        #expect(world.session.commands(forProject: "ORD") == world.session.commands, "The probe's until a chat of the project answers")
        let probe = try #require(world.launcher.probes.first?.request.arguments)
        let plugins = try #require(probe.firstIndex(of: "--plugin-dir"))
        #expect(probe[plugins + 1] == world.root.appendingPathComponent("Data/Runtime/plugins").path)

        let id = try await world.session.send("Hi", references: [], to: nil, projectID: "ORD")
        let cli = try #require(world.launcher.chats.first)
        let initialize = try #require(cli.written.first?["request_id"]?.stringValue)
        cli.feed(#"{"type":"control_response","response":{"subtype":"success","request_id":"\#(initialize)","response":{"commands":[{"name":"release-notes","description":"Writes notes","argumentHint":""}]}}}"#)
        try await world.until { world.session.projectCommands["ORD"] != nil }
        #expect(world.session.commands(forProject: "ORD").map(\.name) == ["release-notes"])
        #expect(world.session.chats[id] != nil)
        cli.finish(.exited(0))
    }

    @Test("A skill is synced when its description ends with the CLI's mark, or its plugin is in the CLI's synced folder")
    func syncedCommands() throws {
        let list = try #require(ClaudeCommand.list([
            ["name": "computer-use", "description": "Controls the screen. (claude.ai sync)"],
            ["name": "cowork:make", "description": "Makes plugins"],
            ["name": "hexago:create-service", "description": "Creates a service"],
        ]))
        #expect(list.map(\.isSynced) == [true, false, false])
        let claude = FileManager.default.temporaryDirectory.appendingPathComponent("SyncedPlugins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: claude) }
        let manifest = claude.appendingPathComponent("plugins/synced/account-1/cowork-folder/.claude-plugin")
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
        try Data(#"{"name":"cowork"}"#.utf8).write(to: manifest.appendingPathComponent("plugin.json"))
        try FileManager.default.createDirectory(at: claude.appendingPathComponent("plugins/synced/account-1/empty"), withIntermediateDirectories: true)
        #expect(ClaudeCommand.syncedPlugins(claudeFolder: claude) == ["cowork"])
        #expect(ClaudeCommand.marking(list, syncedPlugins: ["cowork"]).map(\.isSynced) == [true, true, false])
        #expect(ClaudeCommand.syncedPlugins(claudeFolder: claude.appendingPathComponent("missing")).isEmpty)
    }

    @Test("The lines the app doesn't use are noted in the chat's log, as V2's were, but the stream's own events")
    func ignoredLinesLogged() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        _ = try await world.session.send("Hi", references: [], to: nil, projectID: "ORD")
        let cli = try #require(world.launcher.chats.first)
        cli.feed(#"{"type":"something_new"}"#)
        cli.feed(#"{"type":"system","subtype":"status"}"#)
        cli.feed("not json")
        try await world.until { cli.logged.count == 3 }
        #expect(cli.logged == ["ignored something_new", "ignored system/status", "invalid line: not a JSON object"])
        world.launcher.chats.forEach { $0.finish(.exited(0)) }
    }

    @Test("New chats' defaults hold the mode, Ultracode and context window too, as V2's did; settings.yml keeps them")
    func defaultsOfNewChats() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        var settings = world.session.defaults
        settings.permissionMode = ChatPermissionMode.plan.rawValue
        settings.ultracode = true
        settings.contextWindow = ChatContextWindow.window1M.rawValue
        try world.session.setDefaults(settings)
        let file = try #require(world.projects.dataFolder).readSettings()
        #expect(file.chatPermissionMode == "plan" && file.chatUltracode == true && file.chatContextWindow == "1m")
        #expect(ChatSession.defaults(of: file) == world.session.defaults)
        let id = try await world.session.send("Hi", references: [], to: nil, projectID: "ORD")
        let chat = try #require(world.session.chats[id]?.file.settings)
        #expect(chat.permissionMode == "plan" && chat.ultracode && chat.contextWindow == "1m")
        settings.permissionMode = "nonsense"
        #expect(throws: ChatError.self) { try world.session.setDefaults(settings) }
        world.launcher.chats.forEach { $0.finish(.exited(0)) }
    }

    @Test("A chat whose Claude starts while the app's MCP server isn't listening says why, as V2's did")
    func mcpUnavailable() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        world.session.mcpUnavailable = "Port 7457 is in use."
        let id = try await world.session.send("Hi", references: [], to: nil, projectID: "ORD")
        let warnings = world.items(id).compactMap { if case .system(let line) = $0, line.level == .warning { line.text } else { nil } }
        #expect(warnings == ["Hephaestus MCP server unavailable: Port 7457 is in use."])
        world.session.mcpUnavailable = nil
        let other = try await world.session.send("Hi", references: [], to: nil, projectID: "ORD")
        #expect(!world.items(other).contains { if case .system = $0 { true } else { false } })
        world.launcher.chats.forEach { $0.finish(.exited(0)) }
    }

    @Test("A first message makes the chat and starts the CLI: no prompt, every CLI tool but its question tool, the app's tools allowed, the skills chats call")
    func firstMessage() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("Why did it fail?\nThanks", references: [
            ChatItemReference(tool: "tickets", projectID: "ORD", focus: "ORD-142", title: "ORD-142"),
        ], to: nil, projectID: "ORD", origin: "tickets")
        let chat = try #require(world.session.chats[id])
        #expect(chat.file.title == "Why did it fail?" && chat.file.origin == "tickets" && chat.projectID == "ORD")
        #expect(world.session.state(of: id) == .starting)
        let cli = try #require(world.launcher.chats.first)
        let arguments = cli.request.arguments
        #expect(arguments.contains("--session-id") && arguments.contains(id) && !arguments.contains("--resume"))
        #expect(!arguments.contains("--settings"))
        // The memories: the global folder to read and write, and the skill chat-memories, filled, as the system prompt's end.
        let global = world.root.appendingPathComponent("home/.claude/memory").path
        let added = try #require(arguments.firstIndex(of: "--add-dir"))
        #expect(arguments[added + 1] == global && FileManager.default.fileExists(atPath: global))
        let appended = try #require(arguments.firstIndex(of: "--append-system-prompt"))
        #expect(arguments[appended + 1].contains("Their folder is \(global)."))
        let plugins = try #require(arguments.firstIndex(of: "--plugin-dir"))
        #expect(arguments[plugins + 1] == world.root.appendingPathComponent("Data/Runtime/plugins").path)
        #expect(!arguments.contains("--tools"))
        let disallowed = try #require(arguments.firstIndex(of: "--disallowedTools"))
        #expect(arguments[disallowed + 1] == "AskUserQuestion")
        let allowed = try #require(arguments.firstIndex(of: "--allowedTools"))
        #expect(arguments[allowed + 1] == "mcp__hephaestus__list_tickets,mcp__hephaestus__add_comment")
        #expect(cli.request.currentDirectory == world.repo.path && cli.request.environment["MCP_TOOL_TIMEOUT"] == "1800000")
        #expect(cli.written.first?["request"]?["subtype"] == "initialize")
        let message = try #require(cli.written.last)
        #expect(message["message"]?["content"]?.arrayValue?.first?["text"] == "Why did it fail?\nThanks\n\nAttached: ticket ORD-142 of project ORD")
        let config = try #require(arguments.firstIndex(of: "--mcp-config")).advanced(by: 1)
        let token = try #require(try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: arguments[config])))["mcpServers"]?["hephaestus"]?["headers"]?["Authorization"]?.stringValue)
        #expect(world.tokens.caller(for: String(token.dropFirst("Bearer ".count))) == .chat(id))
        guard case .user(let user)? = world.items(id).first else { Issue.record("no message"); return }
        #expect(user.text == "Why did it fail?\nThanks" && user.sender == "Studio" && user.references.count == 1)
        #expect(try String(contentsOf: world.repo.appendingPathComponent(".hephaestus/.gitignore"), encoding: .utf8).contains("chats/"))
        cli.finish(.exited(0))
    }

    @Test("A turn replayed from a capture: items written, the session started, the chat idle at the end")
    func turn() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("Run it", references: [], to: nil, projectID: "ORD")
        let cli = try #require(world.launcher.chats.first)
        cli.feed(try Fixture.lines("stream-bash-allowed.jsonl"))
        try await world.until { world.session.state(of: id) == .idle && world.items(id).count == 7 }
        #expect(world.session.chats[id]?.file.sessionStarted == true)
        let kinds = world.items(id).map { item -> String in
            switch item {
            case .user: "user"
            case .system: "system"
            case .toolUse: "toolUse"
            case .toolResult: "toolResult"
            case .assistant: "assistant"
            case .result: "result"
            default: "other"
            }
        }
        #expect(kinds == ["user", "system", "system", "toolUse", "toolResult", "assistant", "result"],
                "The session start line, then a warning: the capture has no MCP server")
        if case .system(let start) = world.items(id)[1] {
            #expect(start.level == .info && start.text == "Session started · Haiku 5.5 · effort high · Ask every time", "The CLI's model id by its name")
        }
        let file = try String(contentsOf: world.repo.appendingPathComponent(".hephaestus/chats/\(id).jsonl"), encoding: .utf8)
        #expect(Transcript.replay(Data(file.utf8)) == world.items(id))
        #expect(world.session.streaming[id] == nil)
        let config = try #require(cli.request.arguments.firstIndex(of: "--mcp-config")).advanced(by: 1)
        #expect(FileManager.default.fileExists(atPath: cli.request.arguments[config]))
        cli.finish(.exited(0))
        try await world.until { world.session.runs[id] == nil }
        #expect(!FileManager.default.fileExists(atPath: cli.request.arguments[config]), "The configuration goes with the process")
    }

    @Test("The app's approval: a card waits, Allow lets the call run and records who answered")
    func approval() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("Comment", references: [], to: nil, projectID: "ORD")
        let answer = Task { await world.session.requestApproval(id, tool: "add_comment", input: ["ticketID": "ORD-1", "text": "Done"]) }
        try await world.until { world.session.state(of: id) == .waitingPermission }
        guard case .permissionRequest(let request)? = world.items(id).last else { Issue.record("no card"); return }
        #expect(request.toolName == "mcp__hephaestus__add_comment" && request.isPending)
        world.session.answer(id, requestID: request.requestID, allow: true)
        #expect(await answer.value == .allowed)
        guard case .permissionRequest(let answered)? = world.items(id).last else { Issue.record("no card"); return }
        #expect(answered.decision == .allow && answered.decidedBy == "Studio")
        #expect(world.session.state(of: id) == .starting)
        world.launcher.chats.first?.finish(.exited(0))
    }

    @Test("A card no one answers is withdrawn before the CLI gives up: the call doesn't run, a late answer does nothing")
    func approvalExpires() async throws {
        #expect(ChatSession.approvalTimeout < .milliseconds(ChatLaunch.toolTimeoutMilliseconds))
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        world.session.approvalLimit = .milliseconds(50)
        let id = try await world.session.send("Comment", references: [], to: nil, projectID: "ORD")
        let answer = Task { await world.session.requestApproval(id, tool: "add_comment", input: ["ticketID": "ORD-1", "text": "Done"]) }
        #expect(await answer.value == .expired)
        guard case .permissionRequest(let request)? = world.items(id).last else { Issue.record("no card"); return }
        #expect(request.decision == .deny && request.decidedBy == nil)
        #expect(world.session.state(of: id) == .starting)
        world.session.answer(id, requestID: request.requestID, allow: true)
        guard case .permissionRequest(let late)? = world.items(id).last else { Issue.record("no card"); return }
        #expect(late.decision == .deny, "A late answer changes nothing")
        world.launcher.chats.first?.finish(.exited(0))
    }

    @Test("The chat follows a mode the CLI takes itself, Ask Every Time for default, and tells the CLI nothing back")
    func followsCLIMode() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("Plan it", references: [], to: nil, projectID: "ORD")
        let cli = try #require(world.launcher.chats.first)
        let written = cli.written.count
        cli.feed(#"{"type":"system","subtype":"status","permissionMode":"acceptEdits"}"#)
        try await world.until { world.session.chats[id]?.file.settings.permissionMode == "acceptEdits" }
        cli.feed(#"{"type":"system","subtype":"status","permissionMode":"default"}"#)
        try await world.until { world.session.chats[id]?.file.settings.permissionMode == "manual" }
        cli.feed(#"{"type":"system","subtype":"status","permissionMode":"someday"}"#)
        #expect(world.session.chats[id]?.file.settings.permissionMode == "manual")
        #expect(cli.written.count == written, "Nothing is written back to the CLI")
        cli.finish(.exited(0))
    }

    @Test("Removing a chat's project ends its Claude; a new MCP port ends an idle one, so the next message uses the port")
    func projectRemovedAndPortMoved() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("First", references: [], to: nil, projectID: "ORD")
        let cli = try #require(world.launcher.chats.first)
        cli.feed(try Fixture.lines("stream-bash-allowed.jsonl"))
        try await world.until { world.session.state(of: id) == .idle }
        #expect(!cli.inputClosed)
        world.session.setPort(world.session.port + 1)
        #expect(cli.inputClosed, "An idle process launched with the old port ends at once")
        cli.finish(.exited(0))
        try await world.until { world.session.runs[id] == nil }

        let other = try await world.session.send("Second", references: [], to: nil, projectID: "ORD")
        let second = try #require(world.launcher.chats.last)
        #expect(world.session.runs[other] != nil)
        try await world.session.projects.remove("ORD")
        try await world.until { world.session.runs[other] == nil && second.signals.contains(SIGTERM) }
        second.finish(.exited(0))
    }

    @Test("The CLI's own request is answered on its stdin; Stop refuses what waits and interrupts")
    func cliRequestAndStop() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("Write it", references: [], to: nil, projectID: "ORD")
        let cli = try #require(world.launcher.chats.first)
        cli.feed(Array(try Fixture.lines("stream-write-denied.jsonl").prefix(26)))
        try await world.until { world.session.state(of: id) == .waitingPermission }
        let pending = Task { await world.session.requestApproval(id, tool: "add_comment", input: [:]) }
        try await world.until { world.items(id).filter { if case .permissionRequest(let request) = $0 { request.isPending } else { false } }.count == 2 }
        world.session.stop(id)
        #expect(await pending.value == .refused)
        let answers = cli.written.filter { $0["type"] == "control_response" }
        #expect(answers.first?["response"]?["response"]?["behavior"] == "deny")
        #expect(answers.first?["response"]?["response"]?["message"] == "The user stopped Claude.")
        #expect(cli.written.last?["request"]?["subtype"] == "interrupt")
        let requests = world.items(id).compactMap { if case .permissionRequest(let request) = $0 { request } else { nil } }
        #expect(requests.allSatisfy { $0.decision == .deny && $0.decidedBy == "Studio" })
        cli.feed(#"{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":5,"errors":["[ede_diagnostic] x"]}"#)
        try await world.until { world.session.state(of: id) == .idle }
        guard case .result(let result)? = world.items(id).last else { Issue.record("no result"); return }
        #expect(result.summary == "Stopped by the user.")
        cli.finish(.exited(0))
    }

    @Test("A CLI that exits during a turn leaves the chat in error, with its last stderr line")
    func exitDuringTurn() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("Hello", references: [], to: nil, projectID: "ORD")
        let cli = try #require(world.launcher.chats.first)
        cli.errorLines = ["", "Error: invalid model", ""]
        cli.finish(.exited(1))
        try await world.until { world.session.state(of: id) == .error }
        guard case .system(let line)? = world.items(id).last else { Issue.record("no line"); return }
        #expect(line.level == .error && line.text == "Claude exited with code 1: Error: invalid model")
    }

    @Test("A session the CLI can't find starts again, with the same message")
    func missingSession() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("First", references: [], to: nil, projectID: "ORD")
        let first = try #require(world.launcher.chats.first)
        first.feed(try Fixture.lines("stream-bash-allowed.jsonl"))
        try await world.until { world.session.state(of: id) == .idle }
        first.finish(.exited(0))
        try await world.until { world.session.runs[id] == nil }
        try await world.session.send("Second", references: [], to: id, projectID: "ORD")
        let resumed = try #require(world.launcher.chats.last)
        #expect(resumed.request.arguments.contains("--resume"))
        resumed.errorLines = ["No conversation found with session ID: \(id)"]
        resumed.finish(.exited(1))
        try await world.until { world.launcher.chats.count == 3 }
        let again = try #require(world.launcher.chats.last)
        #expect(again.request.arguments.contains("--session-id"))
        #expect(again.written.last?["message"]?["content"]?.arrayValue?.first?["text"] == "Second")
        #expect(world.items(id).contains { if case .system(let line) = $0 { line.level == .warning } else { false } })
        again.finish(.exited(0))
    }

    @Test("Model and effort: stored, and sent to a running CLI")
    func settings() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("Hi", references: [], to: nil, projectID: "ORD")
        try world.session.setSettings(id, model: "sonnet", effort: .low)
        let cli = try #require(world.launcher.chats.first)
        #expect(cli.written.contains { $0["request"]?["subtype"] == "set_model" && $0["request"]?["model"] == "sonnet" })
        #expect(cli.written.contains { $0["request"]?["settings"]?["effortLevel"] == "low" })
        #expect(world.session.chats[id]?.file.settings == ChatSettings(model: "sonnet", effort: .low))
        #expect(throws: ChatError.self) { try world.session.rename(id, to: "Two\nlines") }
        try world.session.rename(id, to: "Renamed")
        #expect(world.session.chats[id]?.file.title == "Renamed")
        cli.finish(.exited(0))
    }
}

extension ChatSessionTests {
    @Test("A settings request the CLI doesn't answer in time is forgotten with a warning; a late answer changes nothing")
    func unansweredSettings() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        world.session.controlAnswerLimit = .milliseconds(50)
        let id = try await world.session.send("Hi", references: [], to: nil, projectID: "ORD")
        try world.session.setSettings(id, model: "sonnet", effort: .high)
        let cli = try #require(world.launcher.chats.first)
        let request = try #require(cli.written.last { $0["request"]?["subtype"] == "set_model" })
        try await world.until {
            world.items(id).contains { if case .system(let line) = $0 { line.text == "Claude did not accept the new model now: no answer. It applies the next time Claude starts." } else { false } }
        }
        #expect(world.session.runs[id]?.settingsRequests.isEmpty == true)
        let warnings = world.items(id).count
        let late = request["request_id"]?.stringValue ?? ""
        cli.feed(#"{"type":"control_response","response":{"subtype":"error","request_id":"\#(late)","error":"late"}}"#)
        try await Task.sleep(for: .milliseconds(100))
        #expect(world.items(id).count == warnings, "A late answer adds nothing")
        cli.finish(.exited(0))
    }
}

@Suite("Launching the CLI")
struct ChatLaunchTests {
    @Test("Each item a message carries is one line Claude reads after it")
    func attached() {
        func line(_ tool: String, _ focus: String, environment: String? = nil) -> String {
            ClaudeInput.attachedLine(ChatItemReference(tool: tool, projectID: "ORD", focus: focus, title: "", environment: environment))
        }
        #expect(line("project", "") == "Attached: project ORD")
        #expect(line("serviceMap", "service:payments-api", environment: "Staging") == "Attached: service payments-api of project ORD, as seen in Staging")
        #expect(line("serviceMap", "request:req-8f3a") == "Attached: request req-8f3a of project ORD")
        #expect(line("builds", "release:v1.4.0") == "Attached: release v1.4.0 of project ORD")
        #expect(line("builds", "1288") == "Attached: run 1288 of project ORD")
        #expect(line("contracts", "createOrder") == "Attached: operation createOrder of project ORD")
        #expect(ClaudeInput.text("Hi", carrying: []) == "Hi")
    }

    @Test("The CLI is found in this order: Settings, the variable, the usual places, the login shell's PATH")
    func locate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ChatLaunchTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".local/bin"), withIntermediateDirectories: true)
        let usual = folder.appendingPathComponent(".local/bin/claude").path
        FileManager.default.createFile(atPath: usual, contents: Data(), attributes: [.posixPermissions: 0o755])
        #expect(ClaudeCLI.locate(setting: nil, processEnvironment: [:], shellPATH: nil, home: folder.path) == .success(usual))
        #expect(ClaudeCLI.locate(setting: "/nowhere/claude", processEnvironment: [:], shellPATH: nil, home: folder.path)
            == .failure(.notExecutable("/nowhere/claude")))
        #expect(ClaudeCLI.locate(setting: nil, processEnvironment: ["HEPHAESTUS_CLAUDE_PATH": "~/.local/bin/claude"], shellPATH: nil, home: folder.path)
            == .success(usual))
        #expect(ClaudeCLI.locate(setting: nil, processEnvironment: [:], shellPATH: folder.appendingPathComponent(".local/bin").path, home: "/nowhere")
            == .success(usual))
        #expect(ClaudeCLI.locate(setting: nil, processEnvironment: [:], shellPATH: "/nowhere", home: "/nowhere") == .failure(.notFound))
    }

    @Test("The MCP configuration names the app's server with the chat's token, and its 30-minute limit")
    func configuration() throws {
        let value = try JSONValue.parse(ChatLaunch.mcpConfiguration(port: 47830, token: "abc"))
        #expect(value == ["mcpServers": ["hephaestus": ["type": "http", "url": "http://127.0.0.1:47830/mcp", "headers": ["Authorization": "Bearer abc"],
                                                        "timeout": 1_800_000]]])
    }
}
