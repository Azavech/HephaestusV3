import Foundation

/// The environment of the user's login shell, which every child process gets, so that the tools
/// installed with Homebrew or in `~/.local/bin` are found as in Terminal (docs/architecture.md › Child
/// processes). It is captured once, when the app starts, and again with Look Again in Settings.
public enum ShellEnvironment {
    /// The capture command: `/bin/zsh -lic 'env -0'`.
    public static let shell = "/bin/zsh"
    public static let arguments = ["-lic", "env -0"]
    /// Time allowed to the capture.
    public static let timeout: Duration = .seconds(10)
    /// Prefix of the variables that never reach a child process: the app's own settings.
    public static let reservedPrefix = "HEPHAESTUS_"

    /// What a capture gave.
    public struct Capture: Sendable, Hashable {
        /// The variables children get, without `HEPHAESTUS_*` ones.
        public var environment: [String: String]
        public var outcome: Outcome

        public init(environment: [String: String], outcome: Outcome) {
            self.environment = ShellEnvironment.forChildren(environment)
            self.outcome = outcome
        }
    }

    /// How a capture ended. Every outcome other than `captured` falls back to the app's own
    /// environment, which has a minimal `PATH`.
    public enum Outcome: Sendable, Hashable {
        /// The login shell gave this many variables.
        case captured(count: Int)
        /// The shell didn't finish within `timeout`.
        case timedOut
        /// The shell exited with an error, or was ended by a signal.
        case failed(ProcessTermination)
        /// The shell printed no variable.
        case empty
        /// The shell couldn't start.
        case couldNotStart(reason: String)
    }

    /// Runs the capture shell, which starts from `processEnvironment` without any `HEPHAESTUS_*`
    /// variable, and splits its output on NUL characters; every part of the form `NAME=VALUE` becomes a
    /// variable. When the shell fails, times out or prints no variable, the result is
    /// `processEnvironment` itself.
    public static func capture(processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                               runner: any ProcessRunning, shell: String = ShellEnvironment.shell,
                               arguments: [String] = ShellEnvironment.arguments,
                               timeout: Duration = ShellEnvironment.timeout) async -> Capture {
        let request = ProcessRequest(executable: shell, arguments: arguments, environment: forChildren(processEnvironment))
        do {
            let result = try await runner.run(request, timeout: timeout)
            guard !result.timedOut else { return Capture(environment: processEnvironment, outcome: .timedOut) }
            guard result.termination.isSuccess else {
                return Capture(environment: processEnvironment, outcome: .failed(result.termination))
            }
            let captured = parseNULSeparated(result.standardOutput)
            // No variable at all counts as a failure, so that no child starts without PATH.
            guard !captured.isEmpty else { return Capture(environment: processEnvironment, outcome: .empty) }
            return Capture(environment: captured, outcome: .captured(count: captured.count))
        } catch {
            return Capture(environment: processEnvironment, outcome: .couldNotStart(reason: String(describing: error)))
        }
    }

    /// The environment without any `HEPHAESTUS_*` variable.
    public static func forChildren(_ environment: [String: String]) -> [String: String] {
        environment.filter { !$0.key.hasPrefix(reservedPrefix) }
    }

    /// Splits the output of `env -0` on NUL characters; every part of the form `NAME=VALUE` becomes a
    /// variable, and other parts are skipped.
    public static func parseNULSeparated(_ data: Data) -> [String: String] {
        var environment: [String: String] = [:]
        for part in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard let text = String(data: Data(part), encoding: .utf8),
                  let equals = text.firstIndex(of: "="),
                  equals != text.startIndex
            else { continue }
            environment[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return environment
    }
}
