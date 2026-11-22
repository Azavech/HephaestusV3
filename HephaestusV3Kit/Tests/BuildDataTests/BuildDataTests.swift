import ExternalTools
import Foundation
import Synchronization
import Testing
@testable import BuildData

/// Answers gh calls from a script and records them; nothing reaches GitHub.
final class FakeGH: ProcessRunning {
    private let calls = Mutex<[ProcessRequest]>([])
    let answer: @Sendable ([String]) -> ProcessResult

    init(_ answer: @escaping @Sendable ([String]) -> ProcessResult) {
        self.answer = answer
    }

    var requests: [ProcessRequest] { calls.withLock { $0 } }

    func run(_ request: ProcessRequest, input: Data?, timeout: Duration?) async throws -> ProcessResult {
        calls.withLock { $0.append(request) }
        return answer(request.arguments)
    }
}

private func ok(_ json: String) -> ProcessResult {
    ProcessResult(termination: .exited(0), standardOutput: Data(json.utf8))
}

private let runJSON = """
    [{"conclusion":"failure","createdAt":"2026-11-07T21:27:00Z","databaseId":11873246123,"displayTitle":"Verify webhook signatures","event":"push",
      "headBranch":"main","headSha":"8e7ccf3a1b2c","number":641,"startedAt":"2026-11-07T21:27:01Z","status":"completed",
      "updatedAt":"2026-11-07T21:30:24Z","workflowName":"CI"},
     {"conclusion":"","createdAt":"2026-11-07T22:00:00Z","databaseId":11873246200,"displayTitle":"Backoff","event":"pull_request",
      "headBranch":"fix/backoff","headSha":"aaaaaaa","number":642,"startedAt":"0001-01-01T00:00:00Z","status":"queued",
      "updatedAt":"2026-11-07T22:00:00Z","workflowName":"CI"}]
    """

private let viewJSON = """
    {"conclusion":"failure","createdAt":"2026-11-07T21:27:00Z","databaseId":11873246123,"displayTitle":"Verify webhook signatures","event":"push",
     "headBranch":"main","headSha":"8e7ccf3a1b2c","number":641,"startedAt":"2026-11-07T21:27:01Z","status":"completed","updatedAt":"2026-11-07T21:30:24Z",
     "workflowName":"CI","jobs":[{"databaseId":33,"name":"Test","status":"completed","conclusion":"failure","startedAt":"2026-11-07T21:27:05Z",
     "completedAt":"2026-11-07T21:30:20Z","steps":[{"number":1,"name":"Set up job","status":"completed","conclusion":"success",
     "startedAt":"2026-11-07T21:27:05Z","completedAt":"2026-11-07T21:27:07Z"},{"number":2,"name":"Run tests","status":"completed",
     "conclusion":"failure","startedAt":"2026-11-07T21:27:07.5Z","completedAt":"2026-11-07T21:30:19Z"}]}]}
    """

@Suite("gh")
struct GitHubCLITests {
    @Test("A GitHub page gives its repository; other hosts give none")
    func repository() {
        #expect(GitHubRepository(page: "https://github.com/azavech/orders.git/")?.description == "azavech/orders")
        #expect(GitHubRepository(page: "https://github.com/azavech/orders/tree/main")?.repoArgument == "github.com/azavech/orders")
        #expect(GitHubRepository(page: "https://gitlab.com/a/b") == nil)
        #expect(GitHubRepository(page: "https://github.com/azavech") == nil)
    }

    @Test("gh never asks and writes no colors; the failures have their messages")
    func failures() async throws {
        let cli = GitHubCLI(gh: "/opt/homebrew/bin/gh", environment: ["PATH": "/bin", "GH_DEBUG": "1", "CLICOLOR_FORCE": "1", "HEPHAESTUS_X": "1"],
                            runner: FakeGH { _ in ProcessResult(termination: .exited(4)) })
        #expect(cli.childEnvironment == ["PATH": "/bin", "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1"])
        await #expect(throws: BuildError.noLogin) { try await cli.run("run list", []) }
        let missing = GitHubCLI(gh: nil, environment: [:], runner: FakeGH { _ in ok("") })
        await #expect(throws: BuildError.noGH) { try await missing.run("run list", []) }
        let failing = GitHubCLI(gh: "/gh", environment: [:], runner: FakeGH { _ in
            ProcessResult(termination: .exited(1), standardError: Data("\nfailed to get run: HTTP 404: Not Found.\n".utf8))
        })
        await #expect(throws: BuildError.unavailable("gh run view failed: failed to get run: HTTP 404: Not Found.")) {
            try await failing.run("run view", [])
        }
        let slow = GitHubCLI(gh: "/gh", environment: [:], runner: FakeGH { _ in ProcessResult(termination: .signaled(15), timedOut: true) })
        await #expect(throws: BuildError.unavailable("gh api failed: timeout.")) { try await slow.run("api", []) }
    }
}

@Suite("Builds from gh")
struct GitHubBuildsTests {
    private func builds(_ runner: FakeGH) -> GitHubBuilds {
        GitHubBuilds(cli: GitHubCLI(gh: "/gh", environment: [:], runner: runner), repository: GitHubRepository(owner: "azavech", name: "orders"))
    }

    @Test("Runs: the call with the run number; unset dates and empty conclusions are none")
    func runs() async throws {
        let runner = FakeGH { _ in ok(runJSON) }
        let runs = try await builds(runner).runs()
        #expect(runner.requests[0].arguments == ["run", "list", "--repo=github.com/azavech/orders", "--limit=50",
                                                 "--json=conclusion,createdAt,databaseId,displayTitle,event,headBranch,headSha,number,startedAt,status,updatedAt,workflowName"])
        #expect(runs.map(\.id) == [11873246123, 11873246200] && runs[0].number == 641 && runs[0].workflow == "CI")
        #expect(runs[0].duration() == 203, "A completed run lasts to its last update")
        #expect(runs[1].startedAt == nil && runs[1].conclusion == nil && runs[1].start == runs[1].createdAt)
    }

    @Test("A run's jobs and steps, the job's log by step, and the run's actions after --")
    func run() async throws {
        let runner = FakeGH { arguments in
            if arguments.contains("--log") {
                return ok("Test\tRun tests\t2026-11-07T21:27:08.1234567Z go test ./...\nTest\tRun tests\t2026-11-07T21:30:18.0Z --- FAIL: TestSign\r\nTest\tSet up job\t2026-11-07T21:27:05.0Z Runner\n")
            }
            return ok(arguments.contains("view") ? viewJSON : "")
        }
        let builds = builds(runner)
        let run = try await builds.run(11873246123)
        #expect(runner.requests[0].arguments.suffix(2) == ["--", "11873246123"])
        let job = try #require(run.jobs?.first)
        #expect(job.id == 33 && job.steps.map(\.name) == ["Set up job", "Run tests"])
        #expect(gitHubDuration(start: job.steps[1].startedAt, end: job.steps[1].completedAt) == 191, "Fractional seconds are read")
        let log = try await builds.log(job: 33)
        #expect(log["Run tests"] == ["go test ./...", "--- FAIL: TestSign"] && log["Set up job"] == ["Runner"])
        try await builds.rerun(5, failedOnly: true)
        try await builds.cancel(6)
        #expect(runner.requests.suffix(2).map(\.arguments) == [
            ["run", "rerun", "--repo=github.com/azavech/orders", "--failed", "--", "5"],
            ["run", "cancel", "--repo=github.com/azavech/orders", "--", "6"],
        ])
    }

    @Test("Releases: drafts left out, the latest marked from gh release list, notes and files kept")
    func releases() async throws {
        let runner = FakeGH { arguments in
            if arguments.first == "api" {
                return ok("""
                    [{"tag_name":"v1.5.0-beta","name":"","body":"","draft":true,"prerelease":true,"created_at":"2026-11-10T09:00:00Z","published_at":null,"assets":[]},
                     {"tag_name":"v1.4.0","name":"Retries","body":"## Fixed","draft":false,"prerelease":false,"created_at":"2026-11-09T09:00:00Z",
                      "published_at":"2026-11-09T10:00:00Z","assets":[{"name":"orders.zip","size":19000000}]}]
                    """)
            }
            return ok(#"[{"tagName":"v1.4.0","isLatest":true}]"#)
        }
        let releases = try await builds(runner).releases()
        #expect(releases.map(\.tag) == ["v1.4.0"] && releases[0].isLatest && releases[0].body == "## Fixed")
        #expect(releases[0].assets == [GitHubAsset(name: "orders.zip", size: 19_000_000)])
        #expect(runner.requests[0].arguments == ["api", "repos/azavech/orders/releases?per_page=50"])
    }

    @Test("A download matches its file only, moves under a free name and leaves no folder behind")
    func download() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BuildDataTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads")
        let temporary = root.appendingPathComponent("Runtime")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data().write(to: downloads.appendingPathComponent("orders [1].zip"))
        let runner = FakeGH { arguments in
            let folder = arguments.first { $0.hasPrefix("--dir=") }.map { String($0.dropFirst(6)) } ?? ""
            FileManager.default.createFile(atPath: folder + "/orders [1].zip", contents: Data("zip".utf8))
            return ok("")
        }
        let file = try await builds(runner).download(asset: "orders [1].zip", tag: "v1.4.0", into: downloads, temporary: temporary)
        #expect(file.lastPathComponent == "orders [1] (1).zip")
        #expect(runner.requests[0].arguments.contains("--pattern=orders \\[1].zip"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
        #expect(GitHubBuilds.pattern(forAsset: #"a\b*?[c].zip"#) == #"a\\b\*\?\[c].zip"#)
    }
}

@Suite("Step logs")
struct StepLogTests {
    @Test("A job whose log gh prints under UNKNOWN STEP gives its whole log for each of its steps")
    func unknownStep() {
        let steps = StepLogs.parse(Data("Test\tUNKNOWN STEP\t2026-11-07T21:27:01.1234567Z go test ./...\nTest\tUNKNOWN STEP\tok\n".utf8))
        #expect(StepLogs.lines(of: "Run tests", in: steps) == ["go test ./...", "ok"])
        #expect(StepLogs.lines(of: "Run tests", in: ["Run tests": ["own"], StepLogs.unknownStep: ["all"]]) == ["own"])
        #expect(StepLogs.lines(of: "Run tests", in: [:]).isEmpty)
    }
}
