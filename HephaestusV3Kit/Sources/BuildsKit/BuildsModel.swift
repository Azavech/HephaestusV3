import Foundation
import Observation
import ToolsFoundation

/// Where the runs and releases come from. The app and the previews use `SampleBuildStore`.
protocol BuildStore {
    /// The runs of `project`'s repository, newest first.
    func runs(of project: Project) -> [WorkflowRun]
    /// The releases of `project`'s repository, newest first.
    func releases(of project: Project) -> [Release]
}

/// The sample runs and releases. In the real suite they are read from GitHub.
///
/// A sub project kept in its parent's repository shows its parent's: ToolsKit, inside the Tools app's
/// repository, shows the runs and releases of Tools.
struct SampleBuildStore: BuildStore {
    func runs(of project: Project) -> [WorkflowRun] {
        WorkflowRun.samples(for: owner(of: project).id)
    }

    func releases(of project: Project) -> [Release] {
        Release.samples(for: owner(of: project).id)
    }

    /// The first project of the repository: the one whose runs and releases they are.
    private func owner(of project: Project) -> Project {
        Project.samples.first { $0.repository == project.repository } ?? project
    }
}

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

/// The Builds window of one project: its mode, the run, step and release it shows, and what a route's
/// focus selects.
@Observable
final class BuildsModel {
    enum Mode: Hashable {
        case runs
        case releases
    }

    let project: Project
    /// The runs of the project's repository, newest first.
    let runs: [WorkflowRun]
    /// The releases of the project's repository, newest first.
    let releases: [Release]

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

    private var runID: WorkflowRun.ID?

    /// The builds of `project`, with the item `focus` names selected: a run number (`1288`) or a
    /// release (`release:v1.4.0`). Without one, or with one that names nothing here, the newest run.
    init(project: Project, focus: String?, store: any BuildStore) {
        self.project = project
        runs = store.runs(of: project)
        releases = store.releases(of: project)
        runID = runs.first?.id
        selectedStep = runs.first?.defaultStep
        selectedReleaseID = releases.first?.id
        if let focus {
            select(focus: focus)
        }
    }

    var currentRun: WorkflowRun? {
        runs.first { $0.id == runID }
    }

    var currentRelease: Release? {
        releases.first { $0.id == selectedReleaseID }
    }

    /// The selected step of the selected run, with its job, when both exist.
    var currentStep: (job: Job, step: Step)? {
        guard let selectedStep else { return nil }
        return currentRun?.step(selectedStep)
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
        case .release(let tag)? where releases.contains(where: { $0.id == tag }):
            mode = .releases
            selectedReleaseID = tag
            pageOnOpen = .releases
        default:
            break
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
}
