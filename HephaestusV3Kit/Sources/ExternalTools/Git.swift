import Foundation

/// git, run in a folder with the login shell's environment.
public struct Git: Sendable {
    /// Time allowed to one git command.
    public static let timeout: Duration = .seconds(5)

    public var executable: String
    public var environment: [String: String]
    public var runner: any ProcessRunning

    public init(executable: String, environment: [String: String], runner: any ProcessRunning) {
        self.executable = executable
        self.environment = ShellEnvironment.forChildren(environment)
        self.runner = runner
    }

    /// The tools' git, or nil when git wasn't found.
    public init?(_ tools: Tools, runner: any ProcessRunning) {
        guard let git = tools.git else { return nil }
        self.init(executable: git, environment: tools.environment, runner: runner)
    }

    /// The URL of the `origin` remote of the repository holding `folder`: `git config --get
    /// remote.origin.url`, run in the folder. Nil outside a git work tree, without an `origin` remote,
    /// or when git fails or times out.
    public func originURL(in folder: String) async -> String? {
        let request = ProcessRequest(executable: executable, arguments: ["config", "--get", "remote.origin.url"],
                                     environment: environment, currentDirectory: folder)
        guard let result = try? await runner.run(request, timeout: Self.timeout), result.succeeded else { return nil }
        let url = result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }
}
