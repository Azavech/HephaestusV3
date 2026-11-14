import Foundation

/// kubectl, always with the current context of its kubeconfig file: a project's environment names the
/// file and the namespace, never a context (docs/data.md › Project environment).
public struct Kubectl: Sendable {
    /// Time allowed to one kubectl command.
    public static let timeout: Duration = .seconds(15)

    public var executable: String
    public var environment: [String: String]
    public var runner: any ProcessRunning
    /// The home folder that a kubeconfig path starting with `~/` names.
    public var homeDirectory: String

    public init(executable: String, environment: [String: String], runner: any ProcessRunning,
                homeDirectory: String = NSHomeDirectory()) {
        self.executable = executable
        self.environment = ShellEnvironment.forChildren(environment)
        self.runner = runner
        self.homeDirectory = homeDirectory
    }

    /// The tools' kubectl, or nil when kubectl wasn't found.
    public init?(_ tools: Tools, runner: any ProcessRunning, homeDirectory: String = NSHomeDirectory()) {
        guard let kubectl = tools.kubectl else { return nil }
        self.init(executable: kubectl, environment: tools.environment, runner: runner, homeDirectory: homeDirectory)
    }

    /// The namespaces of the cluster: `kubectl get namespaces -o json`, in kubectl's order.
    public func namespaces(kubeconfig: String?) async throws(KubectlError) -> [String] {
        try await itemNames(["get", "namespaces", "-o", "json"], kubeconfig: kubeconfig, namespace: nil)
    }

    /// The deployments of a namespace (nil: the context's): `kubectl get deployments -o json`.
    public func deployments(namespace: String?, kubeconfig: String?) async throws(KubectlError) -> [String] {
        try await itemNames(["get", "deployments", "-o", "json"], kubeconfig: kubeconfig, namespace: namespace)
    }

    /// The name of the current context: `kubectl config current-context`.
    public func currentContext(kubeconfig: String?) async throws(KubectlError) -> String {
        let arguments = Self.prefix(kubeconfig: kubeconfig, namespace: nil, homeDirectory: homeDirectory) + ["config", "current-context"]
        let output = try await run(arguments)
        let context = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !context.isEmpty else { throw .unexpectedOutput(command: Self.command(arguments)) }
        return context
    }

    // MARK: Arguments

    /// `--kubeconfig=<file>` and `--namespace=<namespace>`, each only when set, in this order, each one
    /// argument so that no value is read as an option; never `--context`. `<file>` has a leading `~/`
    /// replaced by the home folder.
    public static func prefix(kubeconfig: String?, namespace: String?, homeDirectory: String) -> [String] {
        var arguments: [String] = []
        if let kubeconfig {
            arguments.append("--kubeconfig=" + expandingHome(kubeconfig, homeDirectory: homeDirectory))
        }
        if let namespace {
            arguments.append("--namespace=" + namespace)
        }
        return arguments
    }

    /// `path` with a leading `~/` replaced by the home folder.
    public static func expandingHome(_ path: String, homeDirectory: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        var home = homeDirectory
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        return (home == "/" ? "" : home) + path.dropFirst()
    }

    /// `kubectl` and its arguments joined with spaces, an argument that is empty or holds a character
    /// other than letters, digits and `-_./:=,@+%` in single quotes: the command an error names.
    public static func command(_ arguments: [String]) -> String {
        (["kubectl"] + arguments).map(quoted).joined(separator: " ")
    }

    static func quoted(_ argument: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=,@+%"))
        guard argument.isEmpty || argument.unicodeScalars.contains(where: { !plain.contains($0) }) else { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Runs

    private func itemNames(_ command: [String], kubeconfig: String?, namespace: String?) async throws(KubectlError) -> [String] {
        let arguments = Self.prefix(kubeconfig: kubeconfig, namespace: namespace, homeDirectory: homeDirectory) + command
        let output = try await run(arguments)
        guard let list = try? JSONDecoder().decode(ItemList.self, from: output) else {
            throw .unexpectedOutput(command: Self.command(arguments))
        }
        return list.items.compactMap(\.metadata?.name)
    }

    private struct ItemList: Decodable {
        struct Item: Decodable {
            struct Metadata: Decodable { var name: String? }
            var metadata: Metadata?
        }
        var items: [Item]
    }

    /// Runs kubectl with `arguments` and returns its standard output.
    private func run(_ arguments: [String]) async throws(KubectlError) -> Data {
        let request = ProcessRequest(executable: executable, arguments: arguments, environment: environment)
        let result: ProcessResult
        do {
            result = try await runner.run(request, timeout: Self.timeout)
        } catch {
            throw .couldNotStart(reason: String(describing: error))
        }
        if result.timedOut {
            throw .timedOut(command: Self.command(arguments))
        }
        guard result.termination.isSuccess else {
            throw .failed(command: Self.command(arguments), code: result.termination.code,
                          message: result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.standardOutput
    }
}

/// Why a kubectl command gave no answer. The messages are kubectl's own, in English.
public enum KubectlError: Error, Sendable, Hashable, CustomStringConvertible {
    /// kubectl exited with `code` (the status, or 128 + the signal); `message` is its standard error.
    case failed(command: String, code: Int, message: String)
    case timedOut(command: String)
    case unexpectedOutput(command: String)
    case couldNotStart(reason: String)

    public var description: String {
        switch self {
        case let .failed(command, code, message):
            message.isEmpty ? "\(command) exited with code \(code)." : "\(command) exited with code \(code): \(message)"
        case let .timedOut(command):
            "\(command) did not finish within \(Kubectl.timeout.components.seconds) seconds."
        case let .unexpectedOutput(command):
            "Unexpected output from \(command)."
        case let .couldNotStart(reason):
            "kubectl could not start: \(reason)"
        }
    }
}

extension ProcessTermination {
    /// The status of an exit, or 128 + the signal that ended the process, as a shell reports it.
    public var code: Int {
        switch self {
        case .exited(let status): Int(status)
        case .signaled(let signal): 128 + Int(signal)
        }
    }
}
