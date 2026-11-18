import ExternalTools
import Foundation
import MCPKit

/// Whether the Claude CLI can run chats, as Settings ▸ Chat shows it (docs/ui/chat.md › Settings ▸ Chat).
public struct ClaudeStatus: Sendable, Hashable {
    /// True until the CLI is found and has given its version.
    public var checking: Bool
    public var path: String?
    public var version: String?
    /// Why the CLI can't be used; nil while checking and when it can.
    public var error: String?

    public var isAvailable: Bool { version != nil && path != nil }

    public static let checking = ClaudeStatus(checking: true)

    public init(checking: Bool = false, path: String? = nil, version: String? = nil, error: String? = nil) {
        self.checking = checking
        self.path = path
        self.version = version
        self.error = error
    }
}

/// A model the CLI offers (docs/ui/chat.md › Models).
public struct ClaudeModel: Sendable, Hashable, Identifiable {
    /// What `--model` takes: `default`, `opus`…
    public var value: String
    public var displayName: String
    public var description: String
    public var efforts: [Effort]
    /// The CLI model id the value stands for, such as `claude-opus-5-5`.
    public var resolvedModel: String?

    public var id: String { value }

    public init(value: String, displayName: String, description: String, efforts: [Effort] = Effort.allCases, resolvedModel: String? = nil) {
        self.value = value
        self.displayName = displayName
        self.description = description
        self.efforts = efforts
        self.resolvedModel = resolvedModel
    }

    /// The list until a CLI has answered `initialize`.
    public static let fallback: [ClaudeModel] = [
        ClaudeModel(value: "default", displayName: "Default", description: "Recommended model"),
        ClaudeModel(value: "opus", displayName: "Opus", description: "Best for everyday, complex tasks"),
        ClaudeModel(value: "fable", displayName: "Fable", description: "Most capable for your hardest and longest-running tasks"),
        ClaudeModel(value: "sonnet", displayName: "Sonnet", description: "Efficient for routine tasks"),
        ClaudeModel(value: "haiku", displayName: "Haiku", description: "Fastest for quick answers"),
    ]

    /// The models of an `initialize` answer's `models`, in order; an entry without a string `value` is skipped.
    public static func list(_ models: JSONValue?) -> [ClaudeModel]? {
        guard let entries = models?.arrayValue else { return nil }
        let list = entries.compactMap { entry -> ClaudeModel? in
            guard let value = entry["value"]?.stringValue else { return nil }
            return ClaudeModel(value: value, displayName: entry["displayName"]?.stringValue ?? value,
                               description: entry["description"]?.stringValue ?? "",
                               efforts: (entry["supportedEffortLevels"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(Effort.init(rawValue:)) },
                               resolvedModel: entry["resolvedModel"]?.stringValue)
        }
        return list.isEmpty ? nil : list
    }

    /// The name of a CLI model id (`claude-opus-5-5` gives `Opus 5.5`): the first model other than `default`
    /// that resolves to it, else the model whose value it is, else the id itself.
    public static func name(of id: String, in models: [ClaudeModel]) -> String {
        models.first { $0.value != "default" && $0.resolvedModel == id }?.displayName
            ?? models.first { $0.value == id }?.displayName
            ?? id
    }
}

/// Finding the Claude CLI and its version (docs/architecture.md › ChatData).
public enum ClaudeCLI {
    /// The variable that names the CLI for development.
    public static let pathVariable = "HEPHAESTUS_CLAUDE_PATH"
    /// Where the installers put it, in this order, `~` the user's home.
    public static let usualPaths = ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    /// Time allowed to `claude --version`.
    public static let versionTimeout: Duration = .seconds(30)

    /// The CLI to use: the path set in Settings, else `HEPHAESTUS_CLAUDE_PATH`, else the first usual path that
    /// is an executable file, else `claude` in the login shell's `PATH`. A set path that isn't an executable file
    /// is an error, and nothing else is tried.
    public static func locate(setting: String?, processEnvironment: [String: String], shellPATH: String?,
                              home: String = NSHomeDirectory()) -> Result<String, LocateError> {
        for chosen in [setting, processEnvironment[pathVariable]].compactMap({ $0 }) where !chosen.isEmpty {
            let path = expand(chosen, home: home)
            return ToolLocator.isExecutableFile(path) ? .success(path) : .failure(.notExecutable(path))
        }
        for candidate in usualPaths.map({ expand($0, home: home) }) where ToolLocator.isExecutableFile(candidate) {
            return .success(candidate)
        }
        if let found = ToolLocator.executable(named: "claude", inPATH: shellPATH) {
            return .success(found)
        }
        return .failure(.notFound)
    }

    public enum LocateError: Error, Sendable, Hashable {
        case notFound
        case notExecutable(String)
    }

    /// Locates the CLI and runs `<path> --version`: the version is the first `[0-9]+(\.[0-9]+)+` of its output.
    public static func status(setting: String?, processEnvironment: [String: String], environment: [String: String],
                              runner: any ProcessRunning, home: String = NSHomeDirectory()) async -> ClaudeStatus {
        let path: String
        switch locate(setting: setting, processEnvironment: processEnvironment, shellPATH: environment["PATH"], home: home) {
        case .success(let found):
            path = found
        case .failure(.notFound):
            return ClaudeStatus(error: "Claude CLI not found. Install Claude Code, or set its path in Settings ▸ Chat.")
        case .failure(.notExecutable(let chosen)):
            return ClaudeStatus(path: chosen, error: "\(chosen) is not an executable file.")
        }
        let request = ProcessRequest(executable: path, arguments: ["--version"], environment: ShellEnvironment.forChildren(environment))
        let reason: String
        do {
            let result = try await runner.run(request, timeout: versionTimeout)
            if result.succeeded, let match = result.standardOutputText.firstMatch(of: /[0-9]+(\.[0-9]+)+/) {
                return ClaudeStatus(path: path, version: String(match.output.0))
            }
            if result.timedOut {
                reason = "timeout"
            } else if let line = result.standardErrorText.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty }) {
                reason = String(line.reversed().drop { $0 == "." }.reversed())
            } else {
                reason = switch result.termination {
                case .exited(let code): "exit code \(code)"
                case .signaled(let signal): "exit code \(128 + signal)"
                }
            }
        } catch {
            reason = String(describing: error)
        }
        return ClaudeStatus(path: path, error: "\(path) --version failed: \(reason).")
    }

    static func expand(_ path: String, home: String) -> String {
        path.hasPrefix("~/") ? home + path.dropFirst(1) : path
    }
}

/// A slash command the CLI runs, from its `initialize` answer's `commands` (docs/data.md › The CLI): a skill (the
/// user's, a plugin's, the app's own `hephaestus-skills:…`) or one of the CLI's built-in commands.
public struct ClaudeCommand: Sendable, Hashable, Identifiable {
    /// Typed after `/`: `hephaestus-skills:report-feedback`.
    public var name: String
    public var description: String
    /// What follows the name, such as `[what to design]`; empty for nothing.
    public var argumentHint: String
    /// One of the CLI's own commands (`builtin`), rather than a skill.
    public var isBuiltIn: Bool
    /// A skill the CLI syncs from the user's claude.ai account, for Claude's desktop app: its description ends
    /// with `(claude.ai sync)`, or it belongs to a plugin synced the same way. A chat lacks the tools such a
    /// skill needs (the browser, computer use, the desktop's connectors).
    public var isSynced: Bool

    public var id: String { name }

    public init(name: String, description: String = "", argumentHint: String = "", isBuiltIn: Bool = false, isSynced: Bool = false) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.isBuiltIn = isBuiltIn
        self.isSynced = isSynced
    }

    /// The CLI's mark at the end of a synced skill's description.
    public static let syncedMark = "(claude.ai sync)"

    /// The plugin a skill's name starts with, `hexago` for `hexago:create-service`; nil without one.
    public var plugin: String? {
        name.firstIndex(of: ":").map { String(name[..<$0]) }
    }

    /// The commands, those of the synced `plugins` marked synced too.
    public static func marking(_ commands: [ClaudeCommand], syncedPlugins plugins: Set<String>) -> [ClaudeCommand] {
        commands.map { command in
            var command = command
            if let plugin = command.plugin, plugins.contains(plugin) { command.isSynced = true }
            return command
        }
    }

    /// The plugins the CLI syncs from claude.ai: the folders of `<Claude folder>/plugins/synced/<account>/` that
    /// hold a `.claude-plugin/plugin.json`, by the `name` it gives, else the folder's. None when the folder is
    /// missing.
    public static func syncedPlugins(claudeFolder: URL) -> Set<String> {
        let synced = claudeFolder.appendingPathComponent("plugins/synced", isDirectory: true)
        let manager = FileManager.default
        var names: Set<String> = []
        for account in (try? manager.contentsOfDirectory(at: synced, includingPropertiesForKeys: nil)) ?? [] {
            for folder in (try? manager.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                let manifest = folder.appendingPathComponent(".claude-plugin/plugin.json")
                guard let data = try? Data(contentsOf: manifest) else { continue }
                names.insert((try? JSONValue.parse(data))?["name"]?.stringValue ?? folder.lastPathComponent)
            }
        }
        return names
    }

    /// The commands of an `initialize` answer, in its order; nil when it has none, or an entry without a name.
    public static func list(_ commands: JSONValue?) -> [ClaudeCommand]? {
        guard let entries = commands?.arrayValue else { return nil }
        let list = entries.compactMap { entry -> ClaudeCommand? in
            guard let name = entry["name"]?.stringValue, !name.isEmpty else { return nil }
            let description = entry["description"]?.stringValue ?? ""
            return ClaudeCommand(name: name, description: description, argumentHint: entry["argumentHint"]?.stringValue ?? "",
                                 isBuiltIn: entry["builtin"]?.boolValue ?? false,
                                 isSynced: description.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(syncedMark))
        }
        return list.isEmpty ? nil : list
    }
}
