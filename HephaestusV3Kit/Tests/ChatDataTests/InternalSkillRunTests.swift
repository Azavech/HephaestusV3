import ExternalTools
import FileStorage
import Foundation
import MCPKit
import ProjectData
import Synchronization
import Testing
@testable import ChatData

/// Answers `claude --version`, and a skill run with `answer`; records every request and its input. Nothing real
/// starts.
private final class SkillRunner: ProcessRunning, Sendable {
    let answer: ProcessResult
    private let state = Mutex<[(request: ProcessRequest, input: Data?)]>([])
    /// The MCP configuration files of the runs, read while each ran.
    let configurations = Mutex<[Data]>([])

    init(answer: ProcessResult) {
        self.answer = answer
    }

    var runs: [(request: ProcessRequest, input: Data?)] {
        state.withLock { $0 }.filter { $0.request.arguments.first == "-p" }
    }

    func run(_ request: ProcessRequest, input: Data?, timeout: Duration?) async throws -> ProcessResult {
        state.withLock { $0.append((request, input)) }
        if request.arguments == ["--version"] {
            return ProcessResult(termination: .exited(0), standardOutput: Data("2.1.322 (Claude Code)\n".utf8))
        }
        if request.arguments.first == "-p", request.arguments.contains("json") {
            if let index = request.arguments.firstIndex(of: "--mcp-config"), request.arguments[index + 1].hasPrefix("/"),
               let data = FileManager.default.contents(atPath: request.arguments[index + 1]) {
                configurations.withLock { $0.append(data) }
            }
            return answer
        }
        return ProcessResult(termination: .exited(1))
    }
}

private func json(_ text: String, error: Bool = false) -> ProcessResult {
    let value: JSONValue = ["type": "result", "subtype": error ? "error_during_execution" : "success", "is_error": .bool(error), "result": .string(text)]
    return ProcessResult(termination: .exited(error ? 1 : 0), standardOutput: value.data)
}

/// Runs of internal skills without a chat: the CLI's arguments, its answer, and a run on a session in a temporary
/// folder. Tests never start Claude.
@MainActor
@Suite("Internal skill runs")
struct InternalSkillRunTests {
    @Test("Print mode, JSON, no saved session, the skill's model and effort, none of the CLI's tools, the app's MCP server alone with its tools allowed; the content as the system prompt when it isn't blank")
    func arguments() {
        let config = URL(fileURLWithPath: "/Data/Runtime/mcp/skill-1.json")
        let base = ["-p", "--output-format", "json", "--no-session-persistence", "--model", "haiku", "--effort", "low", "--tools", "",
                    "--strict-mcp-config", "--mcp-config", "/Data/Runtime/mcp/skill-1.json",
                    "--allowedTools", "mcp__hephaestus__get_ticket,mcp__hephaestus__list_tickets"]
        let tools = ["get_ticket", "list_tickets"]
        #expect(InternalSkillRun.arguments(InternalSkillValues(content: " \n", model: "haiku", effort: .low), mcpConfig: config, tools: tools)
            == base)
        #expect(InternalSkillRun.arguments(InternalSkillValues(content: "Title it.", model: "haiku", effort: .low), mcpConfig: config, tools: tools)
            == base + ["--system-prompt", "Title it."])
        // A comment answer reads the project's files too.
        let reading = InternalSkillRun.arguments(InternalSkillValues(content: "", model: "opus", effort: .high), mcpConfig: config, tools: tools,
                                                 cliTools: ["Read", "Grep", "Glob"])
        #expect(reading.contains("Read,Grep,Glob") && reading.last?.hasPrefix("Read,Grep,Glob,mcp__hephaestus__get_ticket") == true)
    }

    @Test("The message is the input, then an Attached line per linked item, as a chat's message carries them")
    func message() {
        let ticket = ChatItemReference(tool: "tickets", projectID: "HEPH", focus: "HEPH-3", title: "HEPH-3")
        #expect(InternalSkillRun.message("test", attaching: []) == "test")
        #expect(InternalSkillRun.message("test", attaching: [ticket]) == "test\n\nAttached: ticket HEPH-3 of project HEPH")
        #expect(InternalSkillRun.message(" \n", attaching: [ticket]) == "Attached: ticket HEPH-3 of project HEPH",
                "Without an input, the link alone")
    }

    @Test("The answer is the JSON's result; an error, a timeout, or no JSON throws the CLI's own words")
    func answers() throws {
        #expect(try InternalSkillRun.answer(from: json("Tabs close on click")) == "Tabs close on click")
        #expect(throws: ChatError.invalid("Credit balance is too low")) { try InternalSkillRun.answer(from: json("Credit balance is too low", error: true)) }
        #expect(throws: ChatError.unavailable("Claude didn't answer within 2 minutes.")) {
            try InternalSkillRun.answer(from: ProcessResult(termination: .signaled(15), timedOut: true))
        }
        #expect(throws: ChatError.unavailable("error: unknown option '--effort'")) {
            try InternalSkillRun.answer(from: ProcessResult(termination: .exited(1), standardError: Data("error: unknown option '--effort'\n".utf8)))
        }
        #expect(throws: ChatError.unavailable("The Claude CLI gave no answer.")) {
            try InternalSkillRun.answer(from: ProcessResult(termination: .exited(0)))
        }
    }

    @Test("A run reads the skill from the data folder and gives the CLI the input, in Runtime/claude-cwd; without a CLI it starts nothing")
    func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InternalSkillRunTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cli.path, contents: Data("#!/bin/sh\nexit 1\n".utf8), attributes: [.posixPermissions: 0o755])
        let data = DataFolder(url: root.appendingPathComponent("Data"))
        try data.createIfNeeded()
        try YAMLFile.write(RegistryFile(projects: []), to: data.registryFile)
        try data.writeSettings(SettingsFile(claudePath: cli.path))
        try data.writeSkill(InternalSkillValues(content: "Title it.", model: "sonnet", effort: .medium), of: .setTicketTitle)
        let runner = SkillRunner(answer: json("Tabs close on click"))
        let projects = ProjectSession(dataFolder: data, runner: runner, processEnvironment: [:])
        await projects.start()
        let session = ChatSession(projects: projects, tokens: MCPTokens(), launcher: FakeLauncher(), runner: runner, device: "Studio",
                                  processEnvironment: [:])
        // Before the CLI is checked, nothing starts.
        await #expect(throws: ChatError.self) { try await session.run(.setTicketTitle, input: "Tabs close") }
        #expect(runner.runs.isEmpty)
        await session.start(tools: [], port: 47_998)
        for _ in 0..<400 where !session.status.isAvailable {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await session.run(.setTicketTitle, input: "Tabs close when I click") == "Tabs close on click")
        let run = try #require(runner.runs.first)
        #expect(run.request.executable == cli.path)
        #expect(run.request.arguments.contains("sonnet") && run.request.arguments.contains("medium"))
        #expect(run.request.arguments.suffix(2) == ["--system-prompt", "Title it."])
        #expect(run.request.currentDirectory?.hasSuffix("/Data/Runtime/claude-cwd") == true)
        #expect(run.input.map { String(decoding: $0, as: UTF8.self) } == "Tabs close when I click")
        #expect(runner.configurations.withLock { $0 }.count == 1, "A run without a link has the app's server too")

        // A run that links the ticket: its Attached line. Each run has the app's server with a token of the
        // skill's own, ended with the run, its configuration file removed.
        let ticket = ChatItemReference(tool: "tickets", projectID: "HEPH", focus: "HEPH-3", title: "HEPH-3")
        #expect(try await session.run(.setTicketTitle, input: "test", attaching: [ticket]) == "Tabs close on click")
        let linked = try #require(runner.runs.last)
        #expect(linked.input.map { String(decoding: $0, as: UTF8.self) } == "test\n\nAttached: ticket HEPH-3 of project HEPH")
        let index = try #require(linked.request.arguments.firstIndex(of: "--mcp-config"))
        let config = linked.request.arguments[index + 1]
        #expect(config.hasPrefix(data.url.path + "/Runtime/mcp/skill-"))
        #expect(!FileManager.default.fileExists(atPath: config))
        let written = try #require(runner.configurations.withLock { $0 }.last)
        let server = try JSONValue.parse(written)["mcpServers"]?["hephaestus"]
        #expect(server?["url"]?.stringValue == "http://127.0.0.1:47998/mcp")
        let token = try #require(server?["headers"]?["Authorization"]?.stringValue?.replacing("Bearer ", with: ""))
        #expect(token.count == 64)
        #expect(session.tokens.caller(for: token) == nil, "The token ends with the run")

        // A notification that can no longer be posted runs no Claude: its fallback detail comes back.
        let before = runner.runs.count
        let event = ChatEvent(chatID: "C1", projectID: "HEPH", title: "T", kind: .finished, detail: "Claude finished replying",
                              summaryInput: "Claude's reply:\nDone.")
        #expect(await session.summary(of: event, stillWanted: { false }) == "Claude finished replying")
        #expect(runner.runs.count == before)
        await projects.stop()
    }
}
