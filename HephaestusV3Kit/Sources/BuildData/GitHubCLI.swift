import ExternalTools
import Foundation

/// A repository on github.com, from a project's GitHub page `https://github.com/<owner>/<name>`.
public struct GitHubRepository: Sendable, Hashable, CustomStringConvertible {
    public let owner: String
    public let name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    /// The repository of a GitHub page: `https://github.com/<owner>/<name>`, with or without `.git`, a final
    /// `/` or more path; nil for another host or a page without owner and name.
    public init?(page: String) {
        guard let url = URL(string: page.trimmingCharacters(in: .whitespaces)), let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        var name = parts[1]
        if name.hasSuffix(".git") { name.removeLast(4) }
        guard !parts[0].isEmpty, !name.isEmpty else { return nil }
        self.init(owner: parts[0], name: name)
    }

    /// `owner/name`.
    public var description: String { "\(owner)/\(name)" }
    /// What `--repo` takes: `github.com/<owner>/<name>`, so that a `GH_HOST` of the user's never sends a call
    /// elsewhere.
    public var repoArgument: String { "github.com/\(owner)/\(name)" }
    public var webURL: URL { URL(string: "https://github.com/\(owner)/\(name)")! }
}

/// Why a Builds call failed, with the message the window and Claude read (docs/data.md › Builds).
public enum BuildError: Error, Sendable, Hashable, CustomStringConvertible {
    /// No GitHub page, no gh, no login, or gh failed.
    case unavailable(String)
    /// gh's output isn't what the call reads.
    case unexpected(String)
    /// A file couldn't be saved.
    case storage(String)

    public var description: String {
        switch self {
        case .unavailable(let message), .unexpected(let message), .storage(let message): message
        }
    }

    public static func noPage(_ projectID: String) -> BuildError { .unavailable("Project \(projectID) has no GitHub page.") }
    public static let noGH = BuildError.unavailable("Install the GitHub CLI (gh) to see runs and releases.")
    public static let noLogin = BuildError.unavailable("Run gh auth login in Terminal to see runs and releases.")
}

/// Runs gh (docs/data.md › Builds › gh calls): the login shell's environment without the variables that change
/// gh's output, never asking, with a timeout.
public struct GitHubCLI: Sendable {
    /// The gh found in the login shell's `PATH`; nil when it isn't there.
    public let gh: String?
    public let environment: [String: String]
    public let runner: any ProcessRunning

    /// The usual time limit of a call.
    public static let timeout: Duration = .seconds(30)
    /// The variables left out: colors in the JSON, debug lines, a terminal faked.
    static let removed: Set<String> = ["CLICOLOR_FORCE", "GH_FORCE_TTY", "GH_DEBUG", "DEBUG"]

    public init(gh: String?, environment: [String: String], runner: any ProcessRunning) {
        self.gh = gh
        self.environment = environment
        self.runner = runner
    }

    /// The environment gh runs with.
    public var childEnvironment: [String: String] {
        var values = ShellEnvironment.forChildren(environment).filter { !Self.removed.contains($0.key) }
        values["GH_PROMPT_DISABLED"] = "1"
        values["GH_NO_UPDATE_NOTIFIER"] = "1"
        return values
    }

    /// Runs `gh <arguments>`; `command` names it in messages (`run list`). Returns standard output.
    public func run(_ command: String, _ arguments: [String], timeout: Duration = GitHubCLI.timeout) async throws(BuildError) -> Data {
        guard let gh else { throw .noGH }
        let request = ProcessRequest(executable: gh, arguments: arguments, environment: childEnvironment)
        let result: ProcessResult
        do {
            result = try await runner.run(request, timeout: timeout)
        } catch {
            throw .unavailable("gh \(command) failed: \(error).")
        }
        if result.succeeded { return result.standardOutput }
        if result.termination == .exited(4), !result.timedOut { throw .noLogin }
        throw .unavailable("gh \(command) failed: \(Self.reason(result)).")
    }

    /// `timeout`; the first line of standard error without its final periods; else `exit code <n>`.
    static func reason(_ result: ProcessResult) -> String {
        if result.timedOut { return "timeout" }
        if let line = result.standardErrorText.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) {
            return String(line.reversed().drop { $0 == "." }.reversed())
        }
        return switch result.termination {
        case .exited(let code): "exit code \(code)"
        case .signaled(let signal): "exit code \(128 + signal)"
        }
    }
}
