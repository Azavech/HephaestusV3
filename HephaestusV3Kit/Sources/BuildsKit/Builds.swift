import AZDesign
import SwiftUI
import ToolsFoundation

/// The state of a run, a job or a step.
enum RunStatus: Sendable {
    case success
    case failure
    case running
    case queued
    case cancelled

    /// GitHub's `status` and `conclusion` (docs/ui/builds.md › Runs table): success; failure, timed out or
    /// startup failure; running; queued, requested, waiting or pending; anything else completed is cancelled.
    nonisolated init(status: String, conclusion: String?) {
        switch status {
        case "in_progress": self = .running
        case "queued", "requested", "waiting", "pending": self = .queued
        case "completed":
            switch conclusion {
            case "success": self = .success
            case "failure", "timed_out", "startup_failure": self = .failure
            default: self = .cancelled
            }
        default: self = .queued
        }
    }
}

/// A CI workflow run, read from GitHub with gh, or a sample.
struct WorkflowRun: Identifiable, Hashable, Sendable {
    /// GitHub's id of the run; a sample's number.
    let id: Int
    /// The head commit's message.
    let title: String
    let workflow: String
    let branch: String
    let commit: String
    let status: RunStatus
    let startedAt: Date
    /// In seconds.
    let duration: Int
    let jobs: [Job]
    /// Its number in its workflow, as GitHub shows it (`#641`); 0 for a sample, whose id is its number.
    var number = 0
    /// What started it: `push`, `pull_request`…; empty for a sample.
    var event = ""
    /// Whether its jobs are read: a run of the list has none until its details are read.
    var hasJobs = true

    /// The number shown: `641` of `#641`.
    var displayNumber: Int { number == 0 ? id : number }
}

struct Job: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let status: RunStatus
    let duration: Int
    let steps: [Step]
    /// GitHub's id of the job, which reads its log; 0 for a sample.
    var jobID = 0

    /// Numbers the steps of each name in order (`Step.occurrence`): GitHub names a step without a name after its
    /// action, so one job can have two of one name.
    init(name: String, status: RunStatus, duration: Int, steps: [Step], jobID: Int = 0) {
        self.name = name
        self.status = status
        self.duration = duration
        var seen: [String: Int] = [:]
        self.steps = steps.map { step in
            var step = step
            step.occurrence = seen[step.name, default: 0]
            seen[step.name] = step.occurrence + 1
            return step
        }
        self.jobID = jobID
    }
}

struct Step: Identifiable, Hashable, Sendable {
    /// Unique in its job: the name, and after the first of a name its occurrence too.
    var id: String { occurrence == 0 ? name : "\(name)#\(occurrence)" }
    let name: String
    let status: RunStatus
    let duration: Int
    /// The steps of its job with the same name before it; set by `Job`.
    var occurrence = 0

    init(name: String, status: RunStatus, duration: Int) {
        self.name = name
        self.status = status
        self.duration = duration
    }
}

struct Release: Identifiable, Hashable, Sendable {
    var id: String { tag }
    let tag: String
    let title: String
    let publishedAt: Date
    let assets: [String]
    let isPrerelease: Bool
    let isLatest: Bool
    var notes: String = ""
}

/// A step of a run, named by its job, its own name and, after the first step of that name in its job, its
/// occurrence.
struct StepReference: Hashable, Sendable {
    let job: String
    let step: String
    var occurrence = 0
}

extension RunStatus {
    var title: String {
        switch self {
        case .success: String(localized: "Passed", bundle: #bundle, comment: "The status of a run, a job or a step")
        case .failure: String(localized: "Failed", bundle: #bundle, comment: "The status of a run, a job or a step")
        case .running: String(localized: "Running", bundle: #bundle, comment: "The status of a run, a job or a step")
        case .queued: String(localized: "Queued", bundle: #bundle, comment: "The status of a run, a job or a step")
        case .cancelled: String(localized: "Cancelled", bundle: #bundle, comment: "The status of a run, a job or a step")
        }
    }

    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .running: "arrow.triangle.2.circlepath"
        case .queued: "clock"
        case .cancelled: "minus.circle"
        }
    }

    var color: Color {
        switch self {
        case .success: .success
        case .failure: .danger
        case .running: .info
        case .queued, .cancelled: .textSecondary
        }
    }
}

/// A duration in seconds, written the way CI shows it: `4m 12s`.
func elapsedText(_ seconds: Int) -> Text {
    let duration = Duration.seconds(seconds)
    return Text(duration, format: .units(allowed: [.hours, .minutes, .seconds], width: .narrow))
        .monospacedDigit()
}

extension Job {
    /// Whether the job starts open in a run's details: when it failed, when it is running, or when it
    /// holds `shownStep`, the step whose log shows.
    func opensInitially(showing shownStep: StepReference?) -> Bool {
        status == .failure || status == .running || shownStep?.job == name
    }
}

/// How a line of a log reads, which gives its color: an error, the detail under one, a test starting,
/// or plain output.
nonisolated enum LogLineKind: Equatable, Sendable {
    /// `FAIL`, `--- FAIL`, `Error` or `✘`.
    case error
    /// Indented by four spaces, or an expectation under a failed Swift test.
    case detail
    /// `=== RUN`: a Go test starting.
    case quiet
    case plain

    init(_ line: String) {
        if line.hasPrefix("FAIL") || line.hasPrefix("--- FAIL") || line.hasPrefix("Error") || line.hasPrefix("✘") {
            self = .error
        } else if line.hasPrefix("    ") || line.hasPrefix("  Expectation") {
            self = .detail
        } else if line.hasPrefix("=== RUN") {
            self = .quiet
        } else {
            self = .plain
        }
    }
}

// MARK: Samples

extension WorkflowRun {
    /// Runs of a sample project, newest first.
    static func samples(for projectID: Project.ID) -> [WorkflowRun] {
        let rows: [(Int, String, String, String, RunStatus, Int, Int)] = switch projectID {
        case "ORD": [
            (1288, "Add backoff to the payments client", "CI", "fix/payments-backoff", .running, -6, 0),
            (1287, "Document cursor pagination", "CI", "main", .success, -120, 254),
            (1286, "Index orders by customer", "CI", "perf/customer-index", .failure, -190, 131),
            (1285, "Release 1.4.0", "Release", "main", .success, -1_500, 512),
            (1284, "Cancel orders waiting for payment", "CI", "main", .success, -1_640, 247),
            (1283, "Bump the Go toolchain", "CI", "deps/go", .cancelled, -2_900, 38),
        ]
        case "PAY": [
            (641, "Verify webhook signatures with the new secret", "CI", "main", .failure, -300, 203),
            (640, "Poll the provider after a timeout", "CI", "fix/provider-timeout", .success, -420, 198),
            (639, "Release 2.1.0", "Release", "main", .success, -2_100, 466),
        ]
        case "GW": [
            (377, "Propagate traceparent", "CI", "fix/traceparent", .running, -4, 0),
            (376, "Route /charges to payments-api", "CI", "main", .success, -800, 96),
        ]
        case "SHOP": [
            (212, "Lint the Helm charts", "Charts", "main", .success, -540, 64),
            (211, "Shared chart 3.2", "Charts", "main", .success, -2_950, 88),
        ]
        case "TLS": [
            (58, "Project switcher in tool windows", "Build and Test", "main", .success, -1_260, 412),
            (57, "Service map inspector", "Build and Test", "feature/service-map", .success, -1_500, 398),
        ]
        case "AZD": [
            (12, "Readable colors and High Contrast values", "Test", "main", .success, -420, 188),
        ]
        default: []
        }
        return (rows + olderRows(after: rows)).map { number, title, workflow, branch, status, minutesAgo, seconds in
            WorkflowRun(
                id: number, title: title, workflow: workflow, branch: branch,
                commit: String(format: "%07x", number * 2_654_435_761 % 0xFFFFFFF),
                status: status, startedAt: SampleClock.date(minutes: minutesAgo), duration: seconds,
                jobs: jobs(for: status, workflow: workflow)
            )
        }
    }

    /// A few weeks of ordinary history under the runs above, as a real repository has.
    private static func olderRows(
        after rows: [(Int, String, String, String, RunStatus, Int, Int)]
    ) -> [(Int, String, String, String, RunStatus, Int, Int)] {
        guard let last = rows.last else { return [] }
        let history: [(title: String, branch: String)] = [
            ("Tidy up the request logging", "main"), ("Bump dependencies", "deps/weekly"),
            ("Add the request id to errors", "feat/error-ids"), ("Speed up the test suite", "main"),
            ("Fix a flaky timeout test", "fix/flaky-timeout"), ("Rename the configuration keys", "chore/config-keys"),
            ("Count retries in the metrics", "main"), ("Remove unused handlers", "chore/unused-handlers"),
            ("Validate inputs at the edge", "feat/edge-validation"), ("Update the README", "main"),
            ("Cache the parsed contract", "perf/contract-cache"), ("Split the store package", "refactor/store"),
            ("Parse webhook dates in UTC", "fix/webhook-dates"), ("Add readiness checks", "main"),
            ("Tune the connection pool", "perf/pool"), ("Log slow queries", "main"),
            ("Handle empty pages", "fix/empty-pages"), ("Test pagination edges", "test/pagination"),
            ("Pin the base image", "main"), ("Move CI to the new runners", "ci/runners"),
            ("Fix lint warnings", "main"), ("Retry the flaky upload", "ci/upload-retry"),
        ]
        let workflow = last.2 == "Release" ? "CI" : last.2
        return history.prefix(max(0, min(history.count, last.0 - 1))).enumerated().map { index, entry in
            let status: RunStatus = index % 9 == 4 ? .failure : (index % 13 == 7 ? .cancelled : .success)
            return (
                last.0 - index - 1, entry.title, workflow, entry.branch, status,
                last.5 - 180 - index * 330 - (index * 37) % 120,
                status == .cancelled ? 41 : 150 + (index * 53) % 240
            )
        }
    }

    /// The step to show first: the one that failed, else the one running, else the last that ran.
    var defaultStep: StepReference? {
        let steps = jobs.flatMap { job in job.steps.map { (job, $0) } }
        let pick = steps.first { $0.1.status == .failure }
            ?? steps.first { $0.1.status == .running }
            ?? steps.last { $0.1.status == .success }
        return pick.map { StepReference(job: $0.0.name, step: $0.1.name, occurrence: $0.1.occurrence) }
    }

    func step(_ reference: StepReference) -> (job: Job, step: Step)? {
        guard let job = jobs.first(where: { $0.name == reference.job }),
              let step = job.steps.first(where: { $0.name == reference.step && $0.occurrence == reference.occurrence }) else { return nil }
        return (job, step)
    }

    private static func jobs(for status: RunStatus, workflow: String) -> [Job] {
        let test: RunStatus = status == .failure ? .failure : (status == .running ? .running : status == .cancelled ? .cancelled : .success)
        let later: RunStatus = status == .success ? .success : (status == .running ? .queued : .cancelled)
        var jobs = [
            Job(name: "Lint", status: status == .cancelled ? .cancelled : .success, duration: 24, steps: [
                Step(name: "Check out", status: .success, duration: 2),
                Step(name: "Lint", status: status == .cancelled ? .cancelled : .success, duration: 21),
            ]),
            Job(name: "Test", status: test, duration: 141, steps: [
                Step(name: "Check out", status: .success, duration: 2),
                Step(name: "Set up toolchain", status: .success, duration: 18),
                Step(name: "Build", status: .success, duration: 63),
                Step(name: "Run tests", status: test, duration: 58),
            ]),
        ]
        if workflow == "Release" || workflow == "CI" {
            jobs.append(Job(name: "Image", status: later, duration: 74, steps: [
                Step(name: "Build image", status: later, duration: 61),
                Step(name: "Push image", status: later, duration: 13),
            ]))
        }
        return jobs
    }
}

extension Release {
    static func samples(for projectID: Project.ID) -> [Release] {
        switch projectID {
        case "ORD": [
            Release(tag: "v1.5.0-rc.1", title: "Cursor pagination", publishedAt: SampleClock.date(hours: -20), assets: ["orders-api-linux-arm64.tar.gz"], isPrerelease: true, isLatest: false, notes: "GET /orders now returns a cursor instead of page numbers.\n\nThe page parameter still works until 1.6.0 and logs a deprecation warning."),
            Release(tag: "v1.4.0", title: "Order cancellation", publishedAt: SampleClock.date(days: -1, hours: -1), assets: ["orders-api-linux-arm64.tar.gz", "orders-api-linux-amd64.tar.gz", "contract.yaml"], isPrerelease: false, isLatest: true, notes: "Orders can be cancelled until they are paid: DELETE /orders/{id}.\n\nUnpaid orders older than an hour are cancelled on their own.\n\nThe contract is attached as contract.yaml."),
            Release(tag: "v1.3.2", title: "Fix totals with discounts", publishedAt: SampleClock.date(days: -9), assets: ["orders-api-linux-arm64.tar.gz", "orders-api-linux-amd64.tar.gz"], isPrerelease: false, isLatest: false, notes: "Totals with a percentage discount were rounded per line instead of per order."),
        ]
        case "PAY": [
            Release(tag: "v2.1.0", title: "Refunds", publishedAt: SampleClock.date(days: -1, hours: -11), assets: ["payments-api-linux-arm64.tar.gz", "contract.yaml"], isPrerelease: false, isLatest: true, notes: "POST /charges/{id}/refunds refunds a charge, in full or in part.\n\nWebhooks report refunds as charge.refunded."),
        ]
        case "TLS": [
            Release(tag: "v0.3.0", title: "Service map", publishedAt: SampleClock.date(days: -1), assets: ["Tools.dmg"], isPrerelease: false, isLatest: true, notes: "A service map window: the services of a namespace, their calls, and the path of a request."),
        ]
        case "AZD": [
            Release(tag: "0.2.1", title: "Readable colors", publishedAt: SampleClock.date(hours: -7), assets: [], isPrerelease: false, isLatest: true, notes: "Secondary text meets 4.5:1 on every surface, and High Contrast has its own values."),
        ]
        default: []
        }
    }
}

// MARK: Logs

extension Step {
    /// What the step printed: sample lines in the shape of a CI log.
    func log(in run: WorkflowRun) -> [String] {
        switch status {
        case .queued:
            return ["Waiting for a runner."]
        case .cancelled:
            return ["The run was cancelled before this step started."]
        default:
            break
        }
        let swift = run.workflow == "Build and Test" || run.workflow == "Test"
        var lines: [String]
        switch name {
        case "Check out":
            lines = [
                "Syncing repository",
                "Fetching the head commit of \(run.branch)",
                "HEAD is now at \(run.commit) \(run.title)",
            ]
        case "Set up toolchain":
            lines = swift
                ? ["Selecting Xcode 27.1", "Swift 6.3 is ready", "Restored the package cache (318 MB)"]
                : ["Downloading go1.26.1 for linux-arm64", "Go 1.26.1 is ready", "Restored the module cache (412 MB)"]
        case "Lint":
            lines = swift ? ["swift format lint --strict --recursive Sources", "No issues."] : ["golangci-lint run ./...", "0 issues."]
        case "Build":
            lines = swift
                ? ["xcodebuild build -scheme Tools -destination platform=macOS", "Compiling 214 Swift files", "Linking Tools", "** BUILD SUCCEEDED **"]
                : ["go build -trimpath ./...", "github.com/azavech/service/api", "github.com/azavech/service/store", "github.com/azavech/service/events", "Built 3 packages in 61 s"]
        case "Run tests":
            lines = testLines(swift: swift)
        case "Build image":
            lines = ["docker buildx build --platform linux/arm64,linux/amd64 .", "#1 [internal] load build definition", "#8 exporting to image", "#8 naming to registry.example.com/service:\(run.commit)"]
        case "Push image":
            lines = ["docker push registry.example.com/service:\(run.commit)", "\(run.commit): digest: sha256:7d1c…e09a size: 1784"]
        default:
            lines = [name]
        }
        if status == .running {
            lines.append("…")
        }
        return lines
    }

    private func testLines(swift: Bool) -> [String] {
        if swift {
            return status == .failure ? [
                "swift test --parallel",
                "Test Suite 'All tests' started",
                "✔ Project switcher lists every project (0.012 seconds)",
                "✘ Service map keeps the selection when the environment changes (0.044 seconds)",
                "  Expectation failed: selection == .service(\"orders-api\")",
                "Test run with 48 tests failed after 3.112 seconds with 1 issue.",
            ] : [
                "swift test --parallel",
                "Test Suite 'All tests' started",
                "✔ Project switcher lists every project (0.012 seconds)",
                "✔ Service map keeps the selection when the environment changes (0.041 seconds)",
                "Test run with 48 tests passed after 3.084 seconds.",
            ]
        }
        var lines = ["go test -race -count=1 -v ./..."]
        let passing = [
            ("api", ["TestCreateOrder", "TestGetOrder", "TestListOrdersCursor", "TestCancelUnpaidOrder", "TestCheckoutDeadline"]),
            ("store", ["TestInsertOrder", "TestOrdersByCustomer", "TestStockReservation", "TestMigrationsApplyInOrder"]),
            ("events", ["TestPublishOrderCreated", "TestPublishOrderPaid", "TestConsumerLagMetric"]),
        ]
        for (package, tests) in passing {
            for (index, test) in tests.enumerated() {
                lines.append("=== RUN   \(test)")
                lines.append("--- PASS: \(test) (0.0\(index + 1)s)")
            }
            lines.append("ok   service/\(package)  \(package.count).\(package.count * 137 % 1000)s")
        }
        if status == .failure {
            lines += [
                "=== RUN   TestWebhookSignature",
                "--- FAIL: TestWebhookSignature (0.02s)",
                "    webhook_test.go:48: signature mismatch: got 9f1c…e2, want 3a7b…41",
                "    webhook_test.go:49: the test secret still reads WEBHOOK_SECRET_V1",
                "FAIL",
                "FAIL service/webhooks 0.214s",
                "FAIL",
                "Error: Process completed with exit code 1.",
            ]
        } else if status == .success {
            lines += ["=== RUN   TestWebhookSignature", "--- PASS: TestWebhookSignature (0.02s)", "ok   service/webhooks 0.198s"]
        }
        return lines
    }
}
