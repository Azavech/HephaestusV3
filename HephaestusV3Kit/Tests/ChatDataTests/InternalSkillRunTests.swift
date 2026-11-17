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
    @Test("Print mode, JSON, no saved session, the skill's model and effort, no tools or MCP; the content as the system prompt when it isn't blank")
    func arguments() {
        let base = ["-p", "--output-format", "json", "--no-session-persistence", "--model", "haiku", "--effort", "low", "--tools", "",
                    "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
        #expect(InternalSkillRun.arguments(InternalSkillValues(content: " \n", model: "haiku", effort: .low)) == base)
        #expect(InternalSkillRun.arguments(InternalSkillValues(content: "Title it.", model: "haiku", effort: .low))
            == base + ["--system-prompt", "Title it."])
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
        await projects.stop()
    }
}
