import Foundation
import Observation
import ToolsFoundation

/// The item a route's focus names in Builds: a run by its number, `1288`, or a release by its tag,
/// `release:v1.4.0`.
nonisolated enum BuildsFocus: Hashable, Sendable {
    case run(Int)
    case release(String)

    static let releasePrefix = "release:"

    /// Reads a focus; nil when it names neither a run nor a release.
    init?(_ focus: String) {
        if focus.hasPrefix(Self.releasePrefix) {
            let tag = focus.dropFirst(Self.releasePrefix.count)
            guard !tag.isEmpty else { return nil }
            self = .release(String(tag))
        } else if !focus.isEmpty, focus.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(focus) {
            self = .run(number)
        } else {
            return nil
        }
    }

    /// The focus as a route carries it.
    var focus: String {
        switch self {
        case .run(let number): String(number)
        case .release(let tag): Self.releasePrefix + tag
        }
    }
}

/// The Builds window of one project: its mode, the run, step and release it shows, what a route's focus
/// selects, and its actions.
@Observable
final class BuildsModel {
    enum Mode: Hashable {
        case runs
        case releases
    }

    /// A release file being saved, or saved.
    enum Download: Hashable {
        case running
        case saved(URL)
    }

    let project: Project
    let store: any BuildStore

    /// Runs or releases. Each keeps its own selection, so switching back returns to the same item.
    var mode: Mode = .runs

    /// The run picked in the table or the list. Picking another shows the log of its first step to
    /// read in the same change, so its details open on the job that holds that step.
    var selectedRunID: WorkflowRun.ID? {
        get { runID }
        set {
            guard newValue != runID else { return }
            runID = newValue
            selectedStep = currentRun?.defaultStep
        }
    }

    /// The release picked in the table or the list.
    var selectedReleaseID: Release.ID?

    /// The step whose log shows under the runs table, picked in the run's details.
    var selectedStep: StepReference?

    /// The mode whose list, at iPhone width, starts on its selected item's page: the mode of the item
    /// a route's focus picked. Nil for a window opened without a focus, whose lists start as lists.
    private(set) var pageOnOpen: Mode?
    /// A refresh runs: Refresh shows a spinner.
    private(set) var isRefreshing = false
    /// A re-run or a cancel runs: their buttons are disabled.
    private(set) var isActing = false
    /// The files of releases being saved or saved, by tag and file name, until the window closes.
    private(set) var downloads: [String: Download] = [:]
    /// The alert of an action that failed: its title and message.
    var failure: (title: String, message: String)?

    private var runID: WorkflowRun.ID?
    /// A route's focus that names nothing read yet: applied once the lists are read.
    private var pendingFocus: String?

    /// The builds of `project`, with the item `focus` names selected: a run (`1288`) or a release
    /// (`release:v1.4.0`). Without one, or with one that names nothing here, the newest run.
    init(project: Project, focus: String?, store: any BuildStore) {
        self.project = project
        self.store = store
        runID = runs.first?.id
        selectedStep = runs.first?.defaultStep
        selectedReleaseID = releases.first?.id
        if let focus {
            pendingFocus = focus
            select(focus: focus)
        }
    }

    var runsLoad: BuildLoad<[WorkflowRun]> { store.runs(of: project) }
    var releasesLoad: BuildLoad<[Release]> { store.releases(of: project) }
    /// The runs of the project's repository, newest first.
    var runs: [WorkflowRun] { runsLoad.value ?? [] }
    /// The releases of the project's repository, newest first.
    var releases: [Release] { releasesLoad.value ?? [] }

    /// The selected run, with its jobs once read.
    var currentRun: WorkflowRun? {
        runID.flatMap { store.run($0, of: project) }
    }

    var currentRelease: Release? {
        releases.first { $0.id == selectedReleaseID }
    }

    /// The selected step of the selected run, with its job, when both exist.
    var currentStep: (job: Job, step: Step)? {
        guard let selectedStep else { return nil }
        return currentRun?.step(selectedStep)
    }

    /// The selected step's log.
    var stepLog: BuildLoad<[String]> {
        guard let run = currentRun, let selectedStep else { return .loaded([]) }
        return store.log(of: selectedStep, in: run, of: project)
    }

    /// Selects what a route's focus names, in its mode: a run in **Runs**, a release in **Releases**.
    /// It selects the item again even when the user has picked another since. A focus that names
    /// nothing here changes nothing.
    func select(focus: String) {
        switch BuildsFocus(focus) {
        case .run(let number)? where runs.contains(where: { $0.id == number }):
            mode = .runs
            selectedRunID = number
            pageOnOpen = .runs
            pendingFocus = nil
        case .release(let tag)? where releases.contains(where: { $0.id == tag }):
            mode = .releases
            selectedReleaseID = tag
            pageOnOpen = .releases
            pendingFocus = nil
        case .release?:
            // A release of a list not read yet: read the releases.
            if case .loading = releasesLoad { mode = .releases }
            pendingFocus = focus
        default:
            pendingFocus = focus
        }
    }

    /// What the chat panel beside the window asks about: the selected run, or in **Releases** the
    /// selected release. Nil when the mode has nothing selected.
    var chatSubject: ChatReference? {
        switch mode {
        case .runs: currentRun.map { BuildsReader.reference($0, in: project) }
        case .releases: currentRelease.map { BuildsReader.reference($0, in: project) }
        }
    }

    // MARK: Reading

    /// Reads the shown mode's list again, then the selected run's jobs and its step's log. A focus waiting for
    /// the lists is applied; without a selection, the newest item is selected.
    func refresh() async {
        isRefreshing = true
        await store.refresh(project, releases: mode == .releases)
        isRefreshing = false
        if let pendingFocus { select(focus: pendingFocus) }
        if runID == nil || !runs.contains(where: { $0.id == runID }), let first = runs.first { selectedRunID = first.id }
        if selectedReleaseID == nil || !releases.contains(where: { $0.id == selectedReleaseID }) { selectedReleaseID = releases.first?.id }
        if mode == .runs { await loadSelectedRun() }
    }

    /// Reads the selected run's jobs when they aren't, then shows its first step to read, and that step's log.
    func loadSelectedRun() async {
        guard let id = runID else { return }
        if currentRun?.hasJobs != true || currentRun?.status == .running || currentRun?.status == .queued {
            await store.load(run: id, of: project)
        }
        if selectedStep == nil || currentStep == nil { selectedStep = currentRun?.defaultStep }
        await loadLog()
    }

    /// Reads the selected step's log.
    func loadLog() async {
        guard let run = currentRun, let selectedStep else { return }
        await store.loadLog(of: selectedStep, in: run, of: project)
    }

    // MARK: Actions

    /// Runs the selected run's jobs again: all of them, or only those that failed.
    func rerun(failedOnly: Bool) async {
        guard let run = currentRun, !isActing else { return }
        isActing = true
        defer { isActing = false }
        do throws(BuildActionError) {
            try await store.rerun(run, failedOnly: failedOnly, of: project)
        } catch {
            failure = (failedOnly ? String(localized: "Re-run Failed Jobs failed", bundle: #bundle)
                                  : String(localized: "Re-run All Jobs failed", bundle: #bundle), error.message)
        }
    }

    /// Cancels the selected run.
    func cancel() async {
        guard let run = currentRun, !isActing else { return }
        isActing = true
        defer { isActing = false }
        do throws(BuildActionError) {
            try await store.cancel(run, of: project)
        } catch {
            failure = (String(localized: "Cancel Run failed", bundle: #bundle), error.message)
        }
    }

    /// The selected run on GitHub.
    var webURL: URL? {
        currentRun.flatMap { store.webURL(of: $0, in: project) }
    }

    /// Saves a file of the release in the Downloads folder.
    func download(_ asset: String, of release: Release) async {
        let key = Self.downloadKey(asset, release)
        guard downloads[key] != .running else { return }
        downloads[key] = .running
        do throws(BuildActionError) {
            downloads[key] = .saved(try await store.download(asset, of: release, of: project))
        } catch {
            downloads[key] = nil
            failure = (String(localized: "Download failed", bundle: #bundle), error.message)
        }
    }

    func download(of asset: String, in release: Release) -> Download? {
        downloads[Self.downloadKey(asset, release)]
    }

    private static func downloadKey(_ asset: String, _ release: Release) -> String {
        "\(release.tag)/\(asset)"
    }
}
