import Foundation
import Testing
import ToolsFoundation
@testable import BuildsKit

/// Runs and releases set by each test, for every project; the actions record what they were asked.
final class MockBuildStore: BuildStore {
    var runs: [WorkflowRun]
    var releases: [Release]
    var listedRuns: BuildLoad<[WorkflowRun]>?
    private(set) var actions: [String] = []

    init(runs: [WorkflowRun] = [], releases: [Release] = [], listedRuns: BuildLoad<[WorkflowRun]>? = nil) {
        self.runs = runs
        self.releases = releases
        self.listedRuns = listedRuns
    }

    func runs(of project: Project) -> BuildLoad<[WorkflowRun]> { listedRuns ?? .loaded(runs) }
    func releases(of project: Project) -> BuildLoad<[Release]> { .loaded(releases) }
    func run(_ id: WorkflowRun.ID, of project: Project) -> WorkflowRun? { runs.first { $0.id == id } }
    func log(of step: StepReference, in run: WorkflowRun, of project: Project) -> BuildLoad<[String]> { .loaded(["\(step.job) \(step.step)"]) }
    func refresh(_ project: Project, releases: Bool) async { actions.append(releases ? "refresh releases" : "refresh runs") }
    func load(run id: WorkflowRun.ID, of project: Project) async { actions.append("load \(id)") }
    func loadLog(of step: StepReference, in run: WorkflowRun, of project: Project) async { actions.append("log \(step.step)") }
    func rerun(_ run: WorkflowRun, failedOnly: Bool, of project: Project) async throws(BuildActionError) {
        actions.append("rerun \(run.id) \(failedOnly)")
        throw BuildActionError(message: "HTTP 403")
    }
    func cancel(_ run: WorkflowRun, of project: Project) async throws(BuildActionError) { actions.append("cancel \(run.id)") }
    func download(_ asset: String, of release: Release, of project: Project) async throws(BuildActionError) -> URL {
        actions.append("download \(asset)")
        return URL(fileURLWithPath: "/tmp/\(asset)")
    }
    func webURL(of run: WorkflowRun, in project: Project) -> URL? { nil }
}

private let project = Project.samples[0]

private func run(_ number: Int, _ status: RunStatus = .success, jobs: [Job]? = nil) -> WorkflowRun {
    WorkflowRun(
        id: number, title: "Run \(number)'s commit", workflow: "CI", branch: "main", commit: "abc\(number)",
        status: status, startedAt: SampleClock.date(minutes: -number), duration: 60,
        jobs: jobs ?? [
            Job(name: "Lint", status: .success, duration: 10, steps: [Step(name: "Lint", status: .success, duration: 10)]),
            Job(name: "Test", status: status, duration: 50, steps: [
                Step(name: "Build", status: .success, duration: 20),
                Step(name: "Run tests", status: status, duration: 30),
            ]),
        ]
    )
}

private func release(_ tag: String, latest: Bool = false, prerelease: Bool = false) -> Release {
    Release(tag: tag, title: "Release \(tag)", publishedAt: SampleClock.date(days: -1), assets: [], isPrerelease: prerelease, isLatest: latest)
}

private let store = MockBuildStore(
    runs: [run(3, .failure), run(2), run(1, .running)],
    releases: [release("v2.0.0-rc.1", prerelease: true), release("v1.0.0", latest: true)]
)

@Suite("Focus")
struct FocusTests {
    @Test("A number is a run", arguments: ["1288", "7"])
    func run(_ focus: String) {
        #expect(BuildsFocus(focus) == .run(Int(focus)!))
    }

    @Test("release: and a tag is a release")
    func release() {
        #expect(BuildsFocus("release:v1.4.0") == .release("v1.4.0"))
        #expect(BuildsFocus("release:0.2.1") == .release("0.2.1"))
    }

    @Test("Anything else is no focus", arguments: ["", "release:", "run", "#1288", "-3", "+3", "12a", "v1.4.0", "service:payments-api"])
    func invalid(_ focus: String) {
        #expect(BuildsFocus(focus) == nil)
    }

    @Test("A focus reads back as it was written", arguments: ["1288", "release:v1.5.0-rc.1"])
    func roundTrip(_ focus: String) {
        #expect(BuildsFocus(focus)?.focus == focus)
    }
}

@Suite("Model")
struct ModelTests {
    @Test("Without a focus: the newest run, its first step to read, and the newest release")
    func opensWithoutFocus() {
        let model = BuildsModel(project: project, focus: nil, store: store)
        #expect(model.mode == .runs)
        #expect(model.selectedRunID == 3)
        #expect(model.selectedStep == StepReference(job: "Test", step: "Run tests"))
        #expect(model.selectedReleaseID == "v2.0.0-rc.1")
        #expect(model.pageOnOpen == nil)
    }

    @Test("A run's focus selects it in Runs, and an iPhone starts on its page")
    func opensOnRun() {
        let model = BuildsModel(project: project, focus: "2", store: store)
        #expect(model.mode == .runs)
        #expect(model.selectedRunID == 2)
        #expect(model.selectedStep == StepReference(job: "Test", step: "Run tests"))
        #expect(model.pageOnOpen == .runs)
    }

    @Test("A release's focus selects it in Releases")
    func opensOnRelease() {
        let model = BuildsModel(project: project, focus: "release:v1.0.0", store: store)
        #expect(model.mode == .releases)
        #expect(model.selectedReleaseID == "v1.0.0")
        #expect(model.selectedRunID == 3)
        #expect(model.pageOnOpen == .releases)
    }

    @Test("A focus that names nothing here opens on the newest run", arguments: ["99", "release:v9", "nonsense"])
    func opensOnUnknownFocus(_ focus: String) {
        let model = BuildsModel(project: project, focus: focus, store: store)
        #expect(model.mode == .runs)
        #expect(model.selectedRunID == 3)
        #expect(model.pageOnOpen == nil)
    }

    @Test("A second route to the same run selects it again after the user picked another")
    func routeToSameRun() {
        let model = BuildsModel(project: project, focus: "3", store: store)
        model.selectedRunID = 2
        model.select(focus: "3")
        #expect(model.selectedRunID == 3)
        #expect(model.selectedStep == StepReference(job: "Test", step: "Run tests"))
    }

    @Test("A route to a run leaves Releases for Runs, and one to a release goes back")
    func routeSwitchesMode() {
        let model = BuildsModel(project: project, focus: nil, store: store)
        model.select(focus: "release:v1.0.0")
        #expect(model.mode == .releases)
        #expect(model.selectedReleaseID == "v1.0.0")
        model.select(focus: "1")
        #expect(model.mode == .runs)
        #expect(model.selectedRunID == 1)
        #expect(model.selectedReleaseID == "v1.0.0")
    }

    @Test("A route that names nothing here changes nothing")
    func routeToUnknown() {
        let model = BuildsModel(project: project, focus: "2", store: store)
        model.selectedStep = StepReference(job: "Lint", step: "Lint")
        model.select(focus: "99")
        model.select(focus: "release:v9")
        #expect(model.mode == .runs)
        #expect(model.selectedRunID == 2)
        #expect(model.selectedStep == StepReference(job: "Lint", step: "Lint"))
    }

    @Test("Picking a run shows its first step to read at once, so its details open on that step's job")
    func pickingRunResetsStep() throws {
        let image = Job(name: "Image", status: .success, duration: 10, steps: [Step(name: "Push image", status: .success, duration: 10)])
        let passed = run(4, .success, jobs: run(4).jobs + [image])
        let model = BuildsModel(project: project, focus: nil, store: MockBuildStore(runs: [run(5, .failure), passed]))
        #expect(model.selectedStep == StepReference(job: "Test", step: "Run tests"))
        model.selectedRunID = 4
        // In the same change: the details built for run 4 see its own step, not run 5's.
        #expect(model.selectedStep == StepReference(job: "Image", step: "Push image"))
        let jobs = try #require(model.currentRun?.jobs)
        #expect(jobs.filter { $0.opensInitially(showing: model.selectedStep) }.map(\.name) == ["Image"])
    }

    @Test("Picking the same run again keeps the step the user picked")
    func pickingSameRunKeepsStep() {
        let model = BuildsModel(project: project, focus: nil, store: store)
        model.selectedStep = StepReference(job: "Lint", step: "Lint")
        model.selectedRunID = 3
        #expect(model.selectedStep == StepReference(job: "Lint", step: "Lint"))
        #expect(model.currentStep?.step.name == "Lint")
    }

    @Test("Going back on an iPhone clears the run and its step")
    func clearingRun() {
        let model = BuildsModel(project: project, focus: nil, store: store)
        model.selectedRunID = nil
        #expect(model.selectedStep == nil)
        #expect(model.currentStep == nil)
        #expect(model.chatSubject == nil)
    }

    @Test("Each mode keeps its own selection")
    func modesKeepSelection() {
        let model = BuildsModel(project: project, focus: nil, store: store)
        model.selectedRunID = 2
        model.mode = .releases
        model.selectedReleaseID = "v1.0.0"
        model.mode = .runs
        #expect(model.selectedRunID == 2)
        model.mode = .releases
        #expect(model.selectedReleaseID == "v1.0.0")
    }

    @Test("The chat's subject is the run in Runs and the release in Releases")
    func chatSubject() throws {
        let model = BuildsModel(project: project, focus: "2", store: store)
        let run = try #require(model.chatSubject)
        #expect(run.tool == .builds)
        #expect(run.projectID == project.id)
        #expect(run.focus == "2")
        #expect(run.title == "Run 2")
        model.mode = .releases
        let release = try #require(model.chatSubject)
        #expect(release.focus == "release:v2.0.0-rc.1")
        #expect(release.title == "Release v2.0.0-rc.1")
        model.selectedReleaseID = nil
        #expect(model.chatSubject == nil)
    }

    @Test("A repository without runs or releases selects nothing")
    func empty() {
        let model = BuildsModel(project: project, focus: "1", store: MockBuildStore())
        #expect(model.selectedRunID == nil)
        #expect(model.selectedStep == nil)
        #expect(model.selectedReleaseID == nil)
        #expect(model.chatSubject == nil)
    }
}

@Suite("Reader")
struct ReaderTests {
    @Test("A run reads as its title, status, workflow and branch")
    func readsRun() throws {
        let reading = try #require(BuildsReader.read("3", project: project, store: store))
        #expect(reading.action == "Read run 3")
        #expect(reading.detail == "Run 3's commit · Failed · CI on main")
    }

    @Test("Why a run failed is asked only of a run that failed")
    func runSuggestions() throws {
        let failed = try #require(BuildsReader.read("3", project: project, store: store))
        #expect(failed.suggestions == ["Why did run 3 fail?", "What changed in run 3?"])
        let passed = try #require(BuildsReader.read("2", project: project, store: store))
        #expect(passed.suggestions == ["What changed in run 2?", "Was run 2 slower than usual?"])
        let running = try #require(BuildsReader.read("1", project: project, store: store))
        #expect(running.suggestions == ["Which step is run 1 on?", "What changed in run 1?"])
        for reading in [passed, running] {
            #expect(!reading.suggestions.contains { $0.contains("fail") })
        }
    }

    @Test("A run number keeps its digits together", arguments: [1288, 12_345])
    func runNumber(_ number: Int) throws {
        let reading = try #require(BuildsReader.read(String(number), project: project, store: MockBuildStore(runs: [run(number, .failure)])))
        #expect(reading.action == "Read run \(number)")
        #expect(reading.suggestions.first == "Why did run \(number) fail?")
    }

    @Test("A release reads as its title, kind and date, with its own questions")
    func readsRelease() throws {
        let latest = try #require(BuildsReader.read("release:v1.0.0", project: project, store: store))
        #expect(latest.action == "Read release v1.0.0")
        #expect(latest.detail.hasPrefix("Release v1.0.0 · Latest · Published "))
        #expect(latest.suggestions == ["What's new in release v1.0.0?", "Which runs went into release v1.0.0?"])
        let candidate = try #require(BuildsReader.read("release:v2.0.0-rc.1", project: project, store: store))
        #expect(candidate.detail.hasPrefix("Release v2.0.0-rc.1 · Pre-release · Published "))
        #expect(candidate.suggestions.last == "What's left before release v2.0.0-rc.1 is final?")
    }

    @Test("What isn't there reads as nothing", arguments: ["99", "release:v9", "nonsense"])
    func readsNothing(_ focus: String) {
        #expect(BuildsReader.read(focus, project: project, store: store) == nil)
    }

    @Test("A sub project reads the runs of its repository's owner")
    func subProject() throws {
        let toolsKit = try #require(Project.sample("TKIT"))
        let reading = try #require(BuildsReader.read("58", project: toolsKit, store: nil))
        #expect(reading.detail == "Project switcher in tool windows · Passed · Build and Test on main")
        #expect(BuildsReader.read("release:v0.3.0", project: toolsKit, store: nil) != nil)
    }
}

@Suite("Samples and logs")
struct SampleTests {
    @Test("The step shown first: the failed one, else the running one, else the last that passed")
    func defaultStep() throws {
        let orders = try #require(Project.sample("ORD"))
        let runs = try #require(SampleBuildStore().runs(of: orders).value)
        let failed = try #require(runs.first { $0.id == 1286 })
        #expect(failed.defaultStep == StepReference(job: "Test", step: "Run tests"))
        let running = try #require(runs.first { $0.id == 1288 })
        #expect(running.defaultStep == StepReference(job: "Test", step: "Run tests"))
        let passed = try #require(runs.first { $0.id == 1287 })
        #expect(passed.defaultStep == StepReference(job: "Image", step: "Push image"))
    }

    @Test("A job starts open when it failed, runs, or holds the step shown")
    func jobOpensInitially() {
        let failed = Job(name: "Test", status: .failure, duration: 1, steps: [])
        let running = Job(name: "Test", status: .running, duration: 1, steps: [])
        let passed = Job(name: "Lint", status: .success, duration: 1, steps: [])
        #expect(failed.opensInitially(showing: nil))
        #expect(running.opensInitially(showing: nil))
        #expect(!passed.opensInitially(showing: nil))
        #expect(!passed.opensInitially(showing: StepReference(job: "Test", step: "Lint")))
        #expect(passed.opensInitially(showing: StepReference(job: "Lint", step: "Lint")))
    }

    @Test("Log lines are colored by how they start", arguments: [
        ("FAIL service/webhooks 0.214s", LogLineKind.error),
        ("--- FAIL: TestWebhookSignature (0.02s)", .error),
        ("Error: Process completed with exit code 1.", .error),
        ("✘ Service map keeps the selection", .error),
        ("    webhook_test.go:48: signature mismatch", .detail),
        ("  Expectation failed: selection == .service(\"orders-api\")", .detail),
        ("=== RUN   TestCreateOrder", .quiet),
        ("--- PASS: TestCreateOrder (0.01s)", .plain),
        ("go test -race -count=1 -v ./...", .plain),
    ])
    func logLineKind(_ line: String, _ kind: LogLineKind) {
        #expect(LogLineKind(line) == kind)
    }

    @Test("Edge Gateway and Shop have no releases; ToolsKit shares Tools'")
    func releases() throws {
        let store = SampleBuildStore()
        #expect(store.releases(of: try #require(Project.sample("GW"))).value?.isEmpty == true)
        #expect(store.releases(of: try #require(Project.sample("SHOP"))).value?.isEmpty == true)
        #expect(store.releases(of: try #require(Project.sample("TKIT"))).value?.map(\.tag) == ["v0.3.0"])
        #expect(store.runs(of: try #require(Project.sample("TKIT"))).value?.first?.id == 58)
    }
}

@Suite("Recent Builds widget")
struct WidgetTests {
    @Test("It lists the newest runs, as many as its Number, kept within 1 to 20", arguments: [
        (0, 1), (2, 2), (5, 5), (40, 20),
    ])
    func recentRuns(_ count: Int, _ listed: Int) throws {
        let orders = try #require(Project.sample("ORD"))
        let runs = BuildsDashboardWidget.recentRuns(of: orders, count: count, store: SampleBuildStore())
        #expect(runs.count == listed)
        #expect(runs.first?.id == 1288)
    }

    @Test("A repository without runs lists none")
    func noRuns() {
        #expect(BuildsDashboardWidget.recentRuns(of: project, count: 5, store: MockBuildStore()).isEmpty)
    }
}


@Suite("Builds on gh")
@MainActor
struct LiveBuildsTests {
    @Test("GitHub's statuses and conclusions map to the five statuses")
    func statuses() {
        #expect(RunStatus(status: "completed", conclusion: "success") == .success)
        #expect(RunStatus(status: "completed", conclusion: "timed_out") == .failure)
        #expect(RunStatus(status: "completed", conclusion: "skipped") == .cancelled)
        #expect(RunStatus(status: "completed", conclusion: nil) == .cancelled)
        #expect(RunStatus(status: "in_progress", conclusion: nil) == .running)
        #expect(RunStatus(status: "waiting", conclusion: nil) == .queued)
    }

    @Test("Refresh reads the mode's list, then the selected run's jobs and its step's log")
    func refresh() async {
        let failed = run(5, .failure)
        let store = MockBuildStore(runs: [failed])
        let model = BuildsModel(project: project, focus: nil, store: store)
        await model.refresh()
        #expect(store.actions == ["refresh runs", "log Run tests"], "A run with jobs read isn't read again")
        #expect(model.stepLog == .loaded(["Test Run tests"]))
        model.mode = .releases
        await model.refresh()
        #expect(store.actions.last == "refresh releases")
    }

    @Test("A failed action shows its alert with the button's title and gh's reason")
    func actions() async {
        let store = MockBuildStore(runs: [run(5, .failure)])
        let model = BuildsModel(project: project, focus: nil, store: store)
        await model.rerun(failedOnly: true)
        #expect(store.actions == ["rerun 5 true"])
        #expect(model.failure?.title == "Re-run Failed Jobs failed" && model.failure?.message == "HTTP 403")
        let release = Release(tag: "v1", title: "One", publishedAt: Date(), assets: ["a.zip"], isPrerelease: false, isLatest: true)
        await model.download("a.zip", of: release)
        #expect(model.download(of: "a.zip", in: release) == .saved(URL(fileURLWithPath: "/tmp/a.zip")))
    }

    @Test("A focus that names a run not read yet is applied once the runs are read")
    func pendingFocus() async {
        let store = MockBuildStore(runs: [], listedRuns: .loading)
        let model = BuildsModel(project: project, focus: "7", store: store)
        #expect(model.selectedRunID == nil)
        store.runs = [run(9), run(7)]
        store.listedRuns = nil
        await model.refresh()
        #expect(model.selectedRunID == 7)
    }

    @Test("gh's runs map to the window's: GitHub's id, the number shown, durations")
    func mapping() throws {
        let json = #"{"conclusion":"success","createdAt":"2026-11-07T21:27:00Z","databaseId":99,"displayTitle":"T","event":"push","headBranch":"main","headSha":"0123456789","number":7,"startedAt":"2026-11-07T21:27:00Z","status":"completed","updatedAt":"2026-11-07T21:28:05Z","workflowName":"CI","jobs":[]}"#
        let run = LiveBuildStore.run(try JSONDecoder().decode(GitHubRunForTests.self, from: Data(json.utf8)).run)
        #expect(run.id == 99 && run.displayNumber == 7 && run.commit == "0123456" && run.duration == 65 && run.hasJobs)
    }
}

import BuildData

/// Decodes a run through BuildData's own type.
private struct GitHubRunForTests: Decodable {
    let run: GitHubRun
    init(from decoder: any Decoder) throws { run = try GitHubRun(from: decoder) }
}
