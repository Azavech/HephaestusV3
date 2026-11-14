import AppKit
import BuildData
import Foundation
import Observation
import SwiftUI
import ToolsFoundation

/// A list or a log as Builds reads it: on its way, read, or failed with the reason the window shows.
enum BuildLoad<Value: Hashable>: Hashable {
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { value } else { nil }
    }

    var failure: String? {
        if case .failed(let message) = self { message } else { nil }
    }
}

/// Where the runs and releases come from: `LiveBuildStore` in the app, on gh; `SampleBuildStore` in previews.
protocol BuildStore: AnyObject {
    /// The runs of `project`'s repository, newest first.
    func runs(of project: Project) -> BuildLoad<[WorkflowRun]>
    /// The releases of `project`'s repository, newest first.
    func releases(of project: Project) -> BuildLoad<[Release]>
    /// The run with its jobs once they are read; the run of the list until then.
    func run(_ id: WorkflowRun.ID, of project: Project) -> WorkflowRun?
    /// The lines of a step's log.
    func log(of step: StepReference, in run: WorkflowRun, of project: Project) -> BuildLoad<[String]>
    /// Reads the runs, or the releases, again.
    func refresh(_ project: Project, releases: Bool) async
    /// Reads a run's jobs and steps.
    func load(run id: WorkflowRun.ID, of project: Project) async
    /// Reads the log of the job that holds the step.
    func loadLog(of step: StepReference, in run: WorkflowRun, of project: Project) async
    func rerun(_ run: WorkflowRun, failedOnly: Bool, of project: Project) async throws(BuildActionError)
    func cancel(_ run: WorkflowRun, of project: Project) async throws(BuildActionError)
    /// Saves a release's file in the Downloads folder and returns it.
    func download(_ asset: String, of release: Release, of project: Project) async throws(BuildActionError) -> URL
    /// The run on GitHub; nil for a sample.
    func webURL(of run: WorkflowRun, in project: Project) -> URL?
}

/// Why a Builds action failed: the message of its alert.
struct BuildActionError: Error, Hashable {
    let message: String
}

/// The sample runs and releases.
///
/// A sub project kept in its parent's repository shows its parent's: ToolsKit, inside the Tools app's
/// repository, shows the runs and releases of Tools.
final class SampleBuildStore: BuildStore {
    func runs(of project: Project) -> BuildLoad<[WorkflowRun]> {
        .loaded(WorkflowRun.samples(for: owner(of: project).id))
    }

    func releases(of project: Project) -> BuildLoad<[Release]> {
        .loaded(Release.samples(for: owner(of: project).id))
    }

    func run(_ id: WorkflowRun.ID, of project: Project) -> WorkflowRun? {
        runs(of: project).value?.first { $0.id == id }
    }

    func log(of step: StepReference, in run: WorkflowRun, of project: Project) -> BuildLoad<[String]> {
        guard let found = run.step(step) else { return .loaded([]) }
        return .loaded(found.step.log(in: run))
    }

    func refresh(_ project: Project, releases: Bool) async {}
    func load(run id: WorkflowRun.ID, of project: Project) async {}
    func loadLog(of step: StepReference, in run: WorkflowRun, of project: Project) async {}

    func rerun(_ run: WorkflowRun, failedOnly: Bool, of project: Project) async throws(BuildActionError) {
        throw BuildActionError(message: String(localized: "Sample runs can't run again.", bundle: #bundle))
    }

    func cancel(_ run: WorkflowRun, of project: Project) async throws(BuildActionError) {
        throw BuildActionError(message: String(localized: "Sample runs can't be cancelled.", bundle: #bundle))
    }

    func download(_ asset: String, of release: Release, of project: Project) async throws(BuildActionError) -> URL {
        throw BuildActionError(message: String(localized: "Sample releases have no files to download.", bundle: #bundle))
    }

    func webURL(of run: WorkflowRun, in project: Project) -> URL? { nil }

    /// The first project of the repository: the one whose runs and releases they are.
    private func owner(of project: Project) -> Project {
        Project.samples.first { $0.repository == project.repository } ?? project
    }
}

/// The app's runs and releases, read with gh from each project's GitHub repository (docs/ui/builds.md, docs/data.md
/// › Builds). Nothing is stored: the lists are read when a window shows them, and again every 30 s.
@Observable
public final class LiveBuildStore: BuildStore {
    /// What one repository's windows read, by `owner/name`.
    struct Repository: Hashable {
        var runs: BuildLoad<[WorkflowRun]> = .loading
        var releases: BuildLoad<[Release]> = .loading
        /// Runs with their jobs, by id.
        var details: [WorkflowRun.ID: WorkflowRun] = [:]
        /// Jobs' logs by job id: each step's lines by step name.
        var logs: [Int: BuildLoad<[String: [String]]>] = [:]
    }

    private(set) var repositories: [String: Repository] = [:]
    /// gh, with the login shell's environment, as the projects' session has found it.
    @ObservationIgnored private let cli: @MainActor () -> GitHubCLI
    /// Where gh downloads a file before it moves into the Downloads folder.
    @ObservationIgnored private let temporary: URL
    @ObservationIgnored private let downloads: URL
    @ObservationIgnored private var refreshing: Set<String> = []
    /// Returns once gh can be looked for: the projects' session's first lookup of the tools.
    @ObservationIgnored private let toolsReady: @MainActor () async -> Void

    public init(cli: @escaping @MainActor () -> GitHubCLI, temporary: URL,
                downloads: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
                toolsReady: @escaping @MainActor () async -> Void = {}) {
        self.cli = cli
        self.toolsReady = toolsReady
        self.temporary = temporary
        self.downloads = downloads
    }

    /// The project's repository, from its GitHub page.
    func repository(of project: Project) -> GitHubRepository? {
        project.githubPage.flatMap(GitHubRepository.init(page:))
    }

    private func builds(_ project: Project) throws(BuildError) -> GitHubBuilds {
        guard let repository = repository(of: project) else { throw .noPage(project.id) }
        return GitHubBuilds(cli: cli(), repository: repository)
    }

    private func key(_ project: Project) -> String {
        repository(of: project)?.description ?? "-\(project.id)"
    }

    func runs(of project: Project) -> BuildLoad<[WorkflowRun]> {
        guard repository(of: project) != nil else { return .failed(BuildError.noPage(project.id).description) }
        return repositories[key(project)]?.runs ?? .loading
    }

    func releases(of project: Project) -> BuildLoad<[Release]> {
        guard repository(of: project) != nil else { return .failed(BuildError.noPage(project.id).description) }
        return repositories[key(project)]?.releases ?? .loading
    }

    func run(_ id: WorkflowRun.ID, of project: Project) -> WorkflowRun? {
        let repository = repositories[key(project)]
        return repository?.details[id] ?? repository?.runs.value?.first { $0.id == id }
    }

    func log(of step: StepReference, in run: WorkflowRun, of project: Project) -> BuildLoad<[String]> {
        guard let job = run.jobs.first(where: { $0.name == step.job }) else { return .loaded([]) }
        switch repositories[key(project)]?.logs[job.jobID] ?? .loading {
        case .loading: return .loading
        case .failed(let message): return .failed(message)
        case .loaded(let steps): return .loaded(steps[step.step] ?? [])
        }
    }

    func refresh(_ project: Project, releases: Bool) async {
        let key = key(project) + (releases ? "#releases" : "#runs")
        guard refreshing.insert(key).inserted else { return }
        defer { refreshing.remove(key) }
        // Runs read as the app opens wait for the first lookup of the tools rather than finding gh missing.
        await toolsReady()
        do throws(BuildError) {
            let builds = try builds(project)
            if releases {
                let list = try await builds.releases().map(Self.release)
                update(project) { $0.releases = .loaded(list) }
            } else {
                let list = try await builds.runs().map { Self.run($0) }
                update(project) { repository in
                    repository.runs = .loaded(list)
                    // A run whose status changed is read again with its details.
                    for run in list where repository.details[run.id].map({ $0.status != run.status || $0.duration != run.duration && run.status == .running }) == true {
                        repository.details[run.id] = nil
                    }
                }
            }
        } catch {
            update(project) { releases ? ($0.releases = .failed(error.description)) : ($0.runs = .failed(error.description)) }
        }
    }

    func load(run id: WorkflowRun.ID, of project: Project) async {
        guard let builds = try? builds(project), let read = try? await builds.run(id) else { return }
        update(project) { $0.details[id] = Self.run(read) }
    }

    func loadLog(of step: StepReference, in run: WorkflowRun, of project: Project) async {
        guard let job = run.jobs.first(where: { $0.name == step.job }), job.jobID != 0 else { return }
        if case .loaded? = repositories[key(project)]?.logs[job.jobID] { return }
        guard job.status != .running, job.status != .queued else {
            update(project) { $0.logs[job.jobID] = .failed(String(localized: "The log shows once the job has finished.", bundle: #bundle)) }
            return
        }
        do throws(BuildError) {
            let steps = try await builds(project).log(job: job.jobID)
            update(project) { $0.logs[job.jobID] = .loaded(steps) }
        } catch {
            update(project) { $0.logs[job.jobID] = .failed(error.description) }
        }
    }

    func rerun(_ run: WorkflowRun, failedOnly: Bool, of project: Project) async throws(BuildActionError) {
        do throws(BuildError) {
            try await builds(project).rerun(run.id, failedOnly: failedOnly)
        } catch {
            throw BuildActionError(message: error.description)
        }
        update(project) { $0.details[run.id] = nil }
        await refresh(project, releases: false)
    }

    func cancel(_ run: WorkflowRun, of project: Project) async throws(BuildActionError) {
        do throws(BuildError) {
            try await builds(project).cancel(run.id)
        } catch {
            throw BuildActionError(message: error.description)
        }
        update(project) { $0.details[run.id] = nil }
        await refresh(project, releases: false)
    }

    func download(_ asset: String, of release: Release, of project: Project) async throws(BuildActionError) -> URL {
        do throws(BuildError) {
            return try await builds(project).download(asset: asset, tag: release.tag, into: downloads, temporary: temporary)
        } catch {
            throw BuildActionError(message: error.description)
        }
    }

    func webURL(of run: WorkflowRun, in project: Project) -> URL? {
        repository(of: project).map { $0.webURL.appendingPathComponent("actions/runs/\(run.id)") }
    }

    /// The runs read, for the readers and widgets: those of the list, nil until read.
    func readRuns(of project: Project) -> [WorkflowRun]? {
        repositories[key(project)]?.runs.value
    }

    private func update(_ project: Project, _ change: (inout Repository) -> Void) {
        var repository = repositories[key(project)] ?? Repository()
        change(&repository)
        if repositories[key(project)] != repository { repositories[key(project)] = repository }
    }

    // MARK: Mapping

    static func run(_ run: GitHubRun, now: Date = Date()) -> WorkflowRun {
        let jobs = (run.jobs ?? []).map { job in
            Job(name: job.name, status: RunStatus(status: job.status, conclusion: job.conclusion),
                duration: gitHubDuration(start: job.startedAt, end: job.completedAt, now: now) ?? 0,
                steps: job.steps.map { step in
                    Step(name: step.name, status: RunStatus(status: step.status, conclusion: step.conclusion),
                         duration: gitHubDuration(start: step.startedAt, end: step.completedAt, now: now) ?? 0)
                },
                jobID: job.id)
        }
        return WorkflowRun(id: run.id, title: run.title, workflow: run.workflow, branch: run.branch, commit: String(run.commit.prefix(7)),
                           status: RunStatus(status: run.status, conclusion: run.conclusion), startedAt: run.start ?? .distantPast,
                           duration: run.duration(now: now), jobs: jobs, number: run.number, event: run.event, hasJobs: run.jobs != nil)
    }

    static func release(_ release: GitHubRelease) -> Release {
        Release(tag: release.tag, title: release.name.isEmpty ? release.tag : release.name,
                publishedAt: release.publishedAt ?? release.createdAt ?? .distantPast, assets: release.assets.map(\.name),
                isPrerelease: release.isPrerelease, isLatest: release.isLatest, notes: release.body)
    }
}

extension EnvironmentValues {
    /// The app's builds, for the Builds windows, their widgets and the chat; nil in previews.
    @Entry public var buildStore: LiveBuildStore?
}
