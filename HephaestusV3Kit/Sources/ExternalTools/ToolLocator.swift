import Darwin
import Foundation

/// The command-line tools found, with the environment they run in.
public struct Tools: Sendable, Hashable {
    /// The login shell's environment, without `HEPHAESTUS_*` variables.
    public var environment: [String: String]
    public var git: String?
    public var ssh: String?
    public var kubectl: String?
    public var gh: String?

    public init(environment: [String: String], git: String? = nil, ssh: String? = nil, kubectl: String? = nil, gh: String? = nil) {
        self.environment = ShellEnvironment.forChildren(environment)
        self.git = git
        self.ssh = ssh
        self.kubectl = kubectl
        self.gh = gh
    }

    /// Before the lookup ends, no tool is known.
    public static let notLookedUp = Tools(environment: [:])
}

/// Finds the tools in the `PATH` of the login shell's environment (docs/architecture.md › Child
/// processes).
public enum ToolLocator {
    /// Time allowed to `xcode-select -p`.
    public static let lookupTimeout: Duration = .seconds(10)

    /// The first executable file of each name in the environment's `PATH`. `git` is not used when it is
    /// `/usr/bin/git` and `xcode-select -p` fails: that `git` is only a stub that asks to install the
    /// Command Line Tools.
    public static func lookUp(environment: [String: String], runner: any ProcessRunning,
                              xcodeSelect: String = "/usr/bin/xcode-select") async -> Tools {
        let path = environment["PATH"]
        var git = executable(named: "git", inPATH: path)
        if git == "/usr/bin/git" {
            let request = ProcessRequest(executable: xcodeSelect, arguments: ["-p"], environment: ShellEnvironment.forChildren(environment))
            let result = try? await runner.run(request, timeout: lookupTimeout)
            if result?.succeeded != true {
                git = nil
            }
        }
        return Tools(environment: environment, git: git, ssh: executable(named: "ssh", inPATH: path),
                     kubectl: executable(named: "kubectl", inPATH: path), gh: executable(named: "gh", inPATH: path))
    }

    /// The first executable file named `name` in the folders of a `PATH` value; relative and empty
    /// entries are skipped.
    public static func executable(named name: String, inPATH path: String?) -> String? {
        guard let path else { return nil }
        for folder in path.split(separator: ":", omittingEmptySubsequences: true) where folder.hasPrefix("/") {
            let candidate = (String(folder) as NSString).appendingPathComponent(name)
            if isExecutableFile(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// True for a regular file (links followed) that this process may run.
    public static func isExecutableFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }
}
