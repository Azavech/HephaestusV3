import Foundation

/// ssh, for what its configuration says about a host: a remote like `git@work:owner/name` names a host
/// alias of `~/.ssh/config`, which `ssh -G` resolves to the real host name.
public struct SSH: Sendable {
    /// Time allowed to `ssh -G`.
    public static let timeout: Duration = .seconds(5)

    public var executable: String
    public var environment: [String: String]
    public var runner: any ProcessRunning

    public init(executable: String, environment: [String: String], runner: any ProcessRunning) {
        self.executable = executable
        self.environment = ShellEnvironment.forChildren(environment)
        self.runner = runner
    }

    /// The tools' ssh, or nil when ssh wasn't found.
    public init?(_ tools: Tools, runner: any ProcessRunning) {
        guard let ssh = tools.ssh else { return nil }
        self.init(executable: ssh, environment: tools.environment, runner: runner)
    }

    /// The host name that `ssh -G <alias>`, run in `folder`, prints for a host alias. Nil for an alias
    /// that starts with `-`, when ssh prints none, fails, or times out.
    public func hostName(alias: String, in folder: String) async -> String? {
        guard !alias.isEmpty, !alias.hasPrefix("-") else { return nil }
        let request = ProcessRequest(executable: executable, arguments: ["-G", alias], environment: environment,
                                     currentDirectory: folder)
        guard let result = try? await runner.run(request, timeout: Self.timeout), result.succeeded else { return nil }
        return Self.hostName(inConfiguration: result.standardOutputText)
    }

    /// The value of the first `hostname` line of the output of `ssh -G`.
    public static func hostName(inConfiguration text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "hostname" {
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
