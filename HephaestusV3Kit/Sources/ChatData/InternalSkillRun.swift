import ExternalTools
import FileStorage
import Foundation
import MCPKit
import ProjectData

/// One run of an internal skill without a chat (docs/data.md › Internal skills › Running a skill): the Claude CLI
/// in print mode, on the skill's model and effort, its content as the system prompt, the input as the message,
/// without the CLI's own tools or a saved session. Every run gets the app's MCP server, with a token of its own
/// that only reads; a run that links an item, as a chat's message does, carries the same `Attached:` line. The
/// app adds nothing else Claude reads: what Claude answers is the skill's to say.
public enum InternalSkillRun {
    /// How long a run may take before it is stopped.
    public static let timeout: Duration = .seconds(120)

    /// The CLI's arguments for a skill's values: the app's server from `mcpConfig` alone, its `tools`, which the
    /// CLI runs without asking (the server's gate only lets the run read), and `--system-prompt` only when the
    /// content isn't blank.
    public static func arguments(_ values: InternalSkillValues, mcpConfig: URL, tools: [String]) -> [String] {
        var arguments = [
            "-p", "--output-format", "json", "--no-session-persistence",
            "--model", values.model,
            "--effort", values.effort.rawValue,
            "--tools", "",
            "--strict-mcp-config", "--mcp-config", mcpConfig.path,
            "--allowedTools", tools.map { "mcp__\(MCPProtocol.serverName)__\($0)" }.joined(separator: ","),
        ]
        if !values.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--system-prompt", values.content]
        }
        return arguments
    }

    /// The process: the CLI at `cliPath`, in `folder` (an empty one, so that no project's `CLAUDE.md` is read),
    /// with the login shell's environment.
    public static func request(cliPath: String, values: InternalSkillValues, environment: [String: String], folder: URL,
                               mcpConfig: URL, tools: [String]) -> ProcessRequest {
        ProcessRequest(executable: cliPath, arguments: arguments(values, mcpConfig: mcpConfig, tools: tools),
                       environment: ShellEnvironment.forChildren(environment), currentDirectory: folder.path)
    }

    /// The message: the input, then the `Attached:` line of each linked item, as a chat's message carries them;
    /// the lines alone without an input.
    public static func message(_ input: String, attaching references: [ChatItemReference]) -> String {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return references.map(ClaudeInput.attachedLine).joined(separator: "\n")
        }
        return ClaudeInput.text(input, carrying: references)
    }

    /// Claude's answer: the `result` of the CLI's JSON when it succeeded. Throws with the CLI's own words
    /// otherwise.
    public static func answer(from result: ProcessResult) throws(ChatError) -> String {
        if result.timedOut {
            throw .unavailable("Claude didn't answer within 2 minutes.")
        }
        let errorText = String(decoding: result.standardError, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = try? JSONValue.parse(result.standardOutput) else {
            let output = String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw .unavailable(errorText.isEmpty ? (output.isEmpty ? "The Claude CLI gave no answer." : output) : errorText)
        }
        let text = value["result"]?.stringValue
        if value["is_error"]?.boolValue == true || value["subtype"]?.stringValue != "success" {
            throw .invalid(text ?? (errorText.isEmpty ? "The Claude CLI couldn't answer." : errorText))
        }
        return text ?? ""
    }
}

extension ChatSession {
    /// Runs an internal skill once, on `input`, with the model, effort and content System Prompts gives it, and
    /// returns Claude's answer. The run gets the app's MCP server with a token of its own, which only reads and
    /// ends with the run. `references` are the items the run links, such as the ticket a title is for: the
    /// message carries their `Attached:` lines. Throws when the CLI isn't there, can't run, or answers with an
    /// error.
    public func run(_ skill: InternalSkill, input: String, attaching references: [ChatItemReference] = []) async throws(ChatError) -> String {
        guard let path = status.path, status.isAvailable else {
            throw .unavailable(status.error ?? "The Claude CLI isn't checked yet. Try again in a moment.")
        }
        guard let dataFolder = projects.dataFolder else {
            throw .unavailable("The app has no data folder.")
        }
        let folder = dataFolder.url.appendingPathComponent("Runtime/claude-cwd", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let token = tokens.issue(forSkill: skill.name)
        let mcpConfig = dataFolder.url.appendingPathComponent("Runtime/mcp/skill-\(UUID().uuidString).json")
        defer {
            tokens.revoke(token)
            try? FileManager.default.removeItem(at: mcpConfig)
        }
        do {
            try FileManager.default.createDirectory(at: mcpConfig.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            _ = try AtomicFile.write(ChatLaunch.mcpConfiguration(port: port, token: token), to: mcpConfig, newFileMode: AtomicFile.privateMode)
        } catch {
            throw .unavailable(String(describing: error))
        }
        let request = InternalSkillRun.request(cliPath: path, values: dataFolder.readSkill(skill), environment: projects.tools.environment,
                                               folder: folder, mcpConfig: mcpConfig, tools: toolNames)
        let message = InternalSkillRun.message(input, attaching: references)
        let result: ProcessResult
        do {
            result = try await runner.run(request, input: Data(message.utf8), timeout: InternalSkillRun.timeout)
        } catch {
            throw .unavailable(String(describing: error))
        }
        return try InternalSkillRun.answer(from: result)
    }
}
