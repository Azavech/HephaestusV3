import Foundation
import Testing
@testable import ExternalTools

@Suite("The login shell's environment")
struct ShellEnvironmentTests {
    @Test("env -0 output is split on NUL characters; other parts are skipped")
    func parsing() {
        let data = Data("PATH=/opt/bin:/usr/bin\0EMPTY=\0=nameless\0garbage\0MULTI=a=b\nc\0".utf8)
        #expect(ShellEnvironment.parseNULSeparated(data) == ["PATH": "/opt/bin:/usr/bin", "EMPTY": "", "MULTI": "a=b\nc"])
    }

    @Test("A capture runs zsh -lic 'env -0' without the app's own variables")
    func capture() async throws {
        let runner = FakeRunner(output: "PATH=/opt/homebrew/bin:/usr/bin\0HOME=/Users/someone\0HEPHAESTUS_DATA_DIR=/x\0")
        let capture = await ShellEnvironment.capture(processEnvironment: ["PATH": "/usr/bin", "HEPHAESTUS_DATA_DIR": "/tmp/x"],
                                                     runner: runner)
        #expect(capture.outcome == .captured(count: 3))
        #expect(capture.environment == ["PATH": "/opt/homebrew/bin:/usr/bin", "HOME": "/Users/someone"])
        let request = try #require(runner.requests.first)
        #expect(request.executable == "/bin/zsh")
        #expect(request.arguments == ["-lic", "env -0"])
        #expect(request.environment == ["PATH": "/usr/bin"])
    }

    @Test("A capture that fails, times out, prints nothing or can't start keeps the app's environment")
    func fallbacks() async {
        let app = ["PATH": "/usr/bin:/bin"]
        #expect(await ShellEnvironment.capture(processEnvironment: app, runner: FakeRunner(status: 1)).outcome == .failed(.exited(1)))
        #expect(await ShellEnvironment.capture(processEnvironment: app, runner: FakeRunner(timedOut: true)).outcome == .timedOut)
        let empty = await ShellEnvironment.capture(processEnvironment: app, runner: FakeRunner(output: "garbage"))
        #expect(empty.outcome == .empty)
        #expect(empty.environment == app)
        let failing = FakeRunner { _, _ in throw ChildProcessError.spawnFailed(executable: "/bin/zsh", errno: ENOENT) }
        guard case .couldNotStart = await ShellEnvironment.capture(processEnvironment: app, runner: failing).outcome else {
            Issue.record("expected couldNotStart")
            return
        }
    }
}

@Suite("Finding the tools")
struct ToolLocatorTests {
    @Test("The first executable file of each name in PATH; relative entries and other files are skipped")
    func lookup() throws {
        try withTemporaryFolder { folder in
            let first = folder.appendingPathComponent("first", isDirectory: true)
            let second = folder.appendingPathComponent("second", isDirectory: true)
            for directory in [first, second] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try Data().write(to: first.appendingPathComponent("kubectl"))
            for directory in [first, second] {
                let tool = directory.appendingPathComponent("gh")
                try Data("#!/bin/sh\n".utf8).write(to: tool)
                chmod(tool.path, 0o755)
            }
            let kubectl = second.appendingPathComponent("kubectl")
            try Data("#!/bin/sh\n".utf8).write(to: kubectl)
            chmod(kubectl.path, 0o755)
            let path = "relative/bin::\(first.path):\(second.path)"
            #expect(ToolLocator.executable(named: "gh", inPATH: path) == first.appendingPathComponent("gh").path)
            #expect(ToolLocator.executable(named: "kubectl", inPATH: path) == kubectl.path)
            #expect(ToolLocator.executable(named: "missing", inPATH: path) == nil)
            #expect(ToolLocator.executable(named: "gh", inPATH: nil) == nil)
        }
    }

    @Test("/usr/bin/git counts only when the Command Line Tools are installed")
    func gitStub() async {
        let environment = ["PATH": "/usr/bin"]
        let without = await ToolLocator.lookUp(environment: environment, runner: FakeRunner(status: 2), xcodeSelect: "/fake/xcode-select")
        #expect(without.git == nil)
        let with = FakeRunner(output: "/Library/Developer/CommandLineTools\n")
        let tools = await ToolLocator.lookUp(environment: environment, runner: with, xcodeSelect: "/fake/xcode-select")
        #expect(tools.git == "/usr/bin/git")
        #expect(with.requests.map(\.executable) == ["/fake/xcode-select"])
        #expect(tools.ssh == "/usr/bin/ssh")
    }
}

@Suite("git, ssh and kubectl")
struct RunnerTests {
    @Test("git reads the origin's URL in the project's folder")
    func gitOrigin() async throws {
        let runner = FakeRunner(output: "git@github.com:example/orders.git\n")
        let git = Git(executable: "/usr/bin/git", environment: ["PATH": "/usr/bin", "HEPHAESTUS_X": "1"], runner: runner)
        #expect(await git.originURL(in: "/projects/orders") == "git@github.com:example/orders.git")
        let request = try #require(runner.requests.first)
        #expect(request.arguments == ["config", "--get", "remote.origin.url"])
        #expect(request.currentDirectory == "/projects/orders")
        #expect(request.environment == ["PATH": "/usr/bin"])
        #expect(await Git(executable: "/g", environment: [:], runner: FakeRunner(status: 1)).originURL(in: "/") == nil)
        #expect(await Git(executable: "/g", environment: [:], runner: FakeRunner(output: "  \n")).originURL(in: "/") == nil)
        #expect(Git(Tools(environment: [:]), runner: runner) == nil)
    }

    @Test("ssh -G gives an alias's host name")
    func sshHostName() async throws {
        let runner = FakeRunner(output: "user git\nhostname github.com\nport 22\n")
        let ssh = SSH(executable: "/usr/bin/ssh", environment: [:], runner: runner)
        #expect(await ssh.hostName(alias: "work", in: "/projects/orders") == "github.com")
        #expect(runner.requests.first?.arguments == ["-G", "work"])
        #expect(await ssh.hostName(alias: "-oProxyCommand=x", in: "/") == nil)
        #expect(runner.requests.count == 1)
        #expect(SSH.hostName(inConfiguration: "HostName  example.com \n") == "example.com")
        #expect(SSH.hostName(inConfiguration: "user git\n") == nil)
    }

    @Test("kubectl names the kubeconfig and the namespace, never a context, and reads names from JSON")
    func kubectl() async throws {
        let runner = FakeRunner(output: #"{"items":[{"metadata":{"name":"orders"}},{"metadata":{}},{"metadata":{"name":"tracing"}}]}"#)
        let kubectl = Kubectl(executable: "/opt/bin/kubectl", environment: [:], runner: runner, homeDirectory: "/Users/someone/")
        #expect(try await kubectl.namespaces(kubeconfig: "~/.kube/staging.yaml") == ["orders", "tracing"])
        #expect(runner.requests.last?.arguments == ["--kubeconfig=/Users/someone/.kube/staging.yaml", "get", "namespaces", "-o", "json"])
        _ = try await kubectl.deployments(namespace: "orders", kubeconfig: nil)
        #expect(runner.requests.last?.arguments == ["--namespace=orders", "get", "deployments", "-o", "json"])
        #expect(Kubectl.expandingHome("~/x", homeDirectory: "/") == "/x")
        #expect(Kubectl.expandingHome("/abs/x", homeDirectory: "/Users/someone") == "/abs/x")
    }

    @Test("kubectl failures say the command and kubectl's message")
    func kubectlFailures() async {
        let failing = Kubectl(executable: "/k", environment: [:], runner: FakeRunner(status: 1, error: "error: no context\n"))
        await #expect(throws: KubectlError.failed(command: "kubectl config current-context", code: 1, message: "error: no context")) {
            try await failing.currentContext(kubeconfig: nil)
        }
        let slow = Kubectl(executable: "/k", environment: [:], runner: FakeRunner(timedOut: true))
        await #expect(throws: KubectlError.timedOut(command: "kubectl get namespaces -o json")) {
            try await slow.namespaces(kubeconfig: nil)
        }
        let garbled = Kubectl(executable: "/k", environment: [:], runner: FakeRunner(output: "not json"))
        await #expect(throws: KubectlError.unexpectedOutput(command: "kubectl '--namespace=a b' get deployments -o json")) {
            try await garbled.deployments(namespace: "a b", kubeconfig: nil)
        }
        #expect(KubectlError.failed(command: "kubectl x", code: 1, message: "").description == "kubectl x exited with code 1.")
    }
}
