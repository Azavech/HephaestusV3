import Darwin
import Foundation
import Testing
@testable import ExternalTools

/// Real processes, only `/bin/sh`, `echo` and `sleep`, with an empty environment.
@Suite("Child processes")
struct ChildProcessTests {
    private func shell(_ script: String) -> ProcessRequest {
        ProcessRequest(executable: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/bin:/usr/bin"])
    }

    @Test("Output, errors and the exit status are collected")
    func output() async throws {
        let result = try await ChildProcessRunner.run(shell("echo out; echo err >&2; exit 3"), timeout: .seconds(10))
        #expect(result.standardOutputText == "out\n")
        #expect(result.standardErrorText == "err\n")
        #expect(result.termination == .exited(3))
        #expect(!result.succeeded)
        #expect(result.termination.code == 3)
    }

    @Test("Input reaches standard input; the working folder and the environment are the request's")
    func inputFolderEnvironment() async throws {
        try await withTemporaryFolderAsync { folder in
            var request = shell("cat; pwd; echo \"$GREETING\"")
            request.currentDirectory = folder.path
            request.environment["GREETING"] = "hello"
            let result = try await ChildProcessRunner.run(request, input: Data("piped\n".utf8), timeout: .seconds(10))
            let lines = result.standardOutputText.split(separator: "\n").map(String.init)
            #expect(lines.first == "piped")
            #expect(lines[1].hasSuffix(folder.lastPathComponent))
            #expect(lines.last == "hello")
            #expect(result.succeeded)
        }
    }

    @Test("A process ended by a signal reports it")
    func signaled() async throws {
        let result = try await ChildProcessRunner.run(shell("kill -TERM $$"), timeout: .seconds(10))
        #expect(result.termination == .signaled(SIGTERM))
        #expect(result.termination.code == 128 + Int(SIGTERM))
    }

    @Test("A missing executable can't start")
    func missingExecutable() async {
        let request = ProcessRequest(executable: "/nonexistent/tool", environment: [:])
        await #expect(throws: ChildProcessError.self) { try await ChildProcessRunner.run(request, timeout: .seconds(5)) }
    }

    @Test("The timeout ends the whole process group, what the process started included")
    func timeoutEndsTheGroup() async throws {
        let start = ContinuousClock.now
        let result = try await ChildProcessRunner.run(shell("sleep 30 & echo $!; wait"), timeout: .milliseconds(300),
                                                      killGrace: .milliseconds(500))
        #expect(result.timedOut)
        #expect(ContinuousClock.now - start < .seconds(5))
        let grandchild = try #require(pid_t(result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(for: .milliseconds(200))
        #expect(kill(grandchild, 0) == -1 && errno == ESRCH)
    }

    @Test("The system runner keeps the running processes and ends them on request")
    func terminateAll() async throws {
        let runner = SystemProcessRunner()
        let run = Task { try await runner.run(shell("sleep 30"), timeout: .seconds(20)) }
        while runner.runningCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        runner.terminateAll()
        let result = try await run.value
        #expect(result.termination == .signaled(SIGTERM))
        #expect(runner.runningCount == 0)
    }
}

func withTemporaryFolderAsync<T>(_ body: (URL) async throws -> T) async throws -> T {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ExternalToolsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    return try await body(folder)
}
