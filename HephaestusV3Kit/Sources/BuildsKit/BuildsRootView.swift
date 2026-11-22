import AppKit
import AZDesign
import AZDesignCode
import SwiftUI
import ToolsFoundation

/// The Builds window for one project: its CI runs and its releases, with the jobs and steps of a
/// run in its details.
///
/// Under the table, the log of the step picked in the details (or a release's notes) takes the
/// height the window has; the divider between them moves. The details are always open: at the right
/// of the window on a Mac, beside the log under the table on an iPad (the user's choice).
/// What a tab keeps of Builds while another tab is in front: its model, so that its selection, filters
/// and drafts are still there when the tab comes back. The app's window makes one per tab and project.
@MainActor
public final class BuildsTabState {
    let model: BuildsModel

    public init(project: Project, focus: String? = nil, store: LiveBuildStore) {
        model = BuildsModel(project: project, focus: focus, store: store)
    }
}

public struct BuildsRootView: View {
    @State private var model: BuildsModel

    @Environment(\.reportChatSubject) private var reportChatSubject
    @Environment(\.windowLayout) private var layout

    /// The builds of `project`, with the item `focus` names selected when it opens: a run number
    /// (`1288`) or a release (`release:v1.4.0`).
    ///
    /// The runs are those of the project's repository: a sub project in its parent's repository, as
    /// ToolsKit in the Tools app's, shows the same runs as its parent.
    public init(project: Project, focus: String? = nil, store: LiveBuildStore) {
        self.init(model: BuildsModel(project: project, focus: focus, store: store))
    }

    init(model: BuildsModel) {
        _model = State(initialValue: model)
    }

    /// The builds a tab keeps.
    public init(state: BuildsTabState) {
        self.init(model: state.model)
    }

    public var body: some View {
        Group {
            switch layout {
            case .mac: macBody
            case .pad: padBody
            case .phone: phoneBody
            }
        }
        // A route to an item of this window, once it is open, selects it: again, if the user has
        // picked another since.
        .onFocusRequest { focus in
            model.select(focus: focus)
        }
        // The chat panel beside the window asks about the selected run, or release in Releases.
        .onChange(of: model.chatSubject, initial: true) { _, subject in
            reportChatSubject(subject)
        }
        .onChange(of: layout, initial: true) { _, layout in
            model.selectsNewest = layout != .phone
        }
        // The shown mode's list is read when it shows, then every 30 s while it does.
        .task(id: model.mode) {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .task(id: model.selectedRunID) {
            await model.loadSelectedRun()
        }
        .task(id: model.selectedStep) {
            await model.loadLog()
        }
        .alert(model.failure?.title ?? "", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button(String(localized: "OK", bundle: #bundle)) { model.failure = nil }
        } message: {
            Text(verbatim: model.failure?.message ?? "")
        }
        .toolbar {
            if layout == .phone {
                // An iPhone's toolbar has room for a menu, not for both segments.
                ToolbarItem(placement: .primaryAction) {
                    modePicker
                        .pickerStyle(.menu)
                }
            } else {
                ToolbarItem(placement: .principal) {
                    modePicker
                        .pickerStyle(.segmented)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("builds.refresh")
                } else {
                    Button(String(localized: "Refresh", bundle: #bundle), systemImage: "arrow.clockwise") {
                        Task { await model.refresh() }
                    }
                    .help(String(localized: "Refresh", bundle: #bundle))
                    .accessibilityIdentifier("builds.refresh")
                }
            }
            ChatPanelToolbarItem()
        }
    }

    private var modePicker: some View {
        Picker(String(localized: "Show", bundle: #bundle), selection: $model.mode) {
            Text("Runs", bundle: #bundle).tag(BuildsModel.Mode.runs)
            Text("Releases", bundle: #bundle).tag(BuildsModel.Mode.releases)
        }
        .accessibilityIdentifier("builds.mode")
    }

    // MARK: Layouts

    /// The Mac's: the table over the log or the notes, the details always open at the right.
    private var macBody: some View {
        Group {
            switch model.mode {
            case .runs:
                if model.runs.isEmpty {
                    noRuns
                } else {
                    VSplitView {
                        runsTable
                            .frame(minHeight: 150, idealHeight: 320, maxHeight: .infinity)
                        log(of: model.currentRun)
                            .frame(minHeight: 140, idealHeight: 300, maxHeight: .infinity)
                    }
                }
            case .releases:
                if model.releases.isEmpty {
                    noReleases
                } else {
                    VSplitView {
                        releasesTable
                            .frame(minHeight: 120, idealHeight: 220, maxHeight: .infinity)
                        notes(of: model.currentRelease)
                            .frame(minHeight: 140, idealHeight: 360, maxHeight: .infinity)
                    }
                }
            }
        }
        // The details are always open: the user wants them in view with every run.
        .inspector(isPresented: .constant(true)) {
            details
                .inspectorColumnWidth(min: 280, ideal: 330, max: 440)
        }
    }

    /// An iPad's: the table across the window, and under it the log or the notes with the details
    /// beside them, always open (the user's choice). The table keeps the whole width its columns need.
    @ViewBuilder private var padBody: some View {
        switch model.mode {
        case .runs:
            if model.runs.isEmpty {
                noRuns
            } else {
                VSplitView {
                    runsTable
                        .frame(minHeight: 150, idealHeight: 280, maxHeight: .infinity)
                    HSplitView {
                        log(of: model.currentRun)
                            .frame(minWidth: 300, maxWidth: .infinity)
                        details
                            .frame(minWidth: 280, idealWidth: 330, maxWidth: 440, maxHeight: .infinity)
                            .background(.canvas)
                    }
                    .frame(minHeight: 200, idealHeight: 340, maxHeight: .infinity)
                }
            }
        case .releases:
            if model.releases.isEmpty {
                noReleases
            } else {
                VSplitView {
                    releasesTable
                        .frame(minHeight: 120, idealHeight: 220, maxHeight: .infinity)
                    HSplitView {
                        notes(of: model.currentRelease)
                            .frame(minWidth: 300, maxWidth: .infinity)
                        details
                            .frame(minWidth: 280, idealWidth: 330, maxWidth: 440, maxHeight: .infinity)
                            .background(.canvas)
                    }
                    .frame(minHeight: 200, idealHeight: 360, maxHeight: .infinity)
                }
            }
        }
    }

    /// An iPhone's: the runs or releases as a list, then one as a page: its details over its log or
    /// notes, with Back. A window a route opened on an item starts on its page.
    @ViewBuilder private var phoneBody: some View {
        switch model.mode {
        case .runs:
            if model.runs.isEmpty {
                noRuns
            } else {
                PhoneStack(selection: $model.selectedRunID, opensSelection: model.pageOnOpen == .runs) {
                    List(model.runs, selection: $model.selectedRunID) { run in
                        CompactRunRow(run: run)
                            .tag(run.id)
                    }
                    .accessibilityIdentifier("builds.runs.compact")
                } page: { id in
                    // The selected run with its jobs once read, as the Mac and iPad layouts show it; the list's
                    // run has none.
                    if let run = (model.currentRun?.id == id ? model.currentRun : nil) ?? model.runs.first(where: { $0.id == id }) {
                        VSplitView {
                            RunInspector(run: run, selectedStep: $model.selectedStep, model: model)
                                .id(run.id)
                                .frame(minHeight: 180, idealHeight: 300, maxHeight: .infinity)
                            log(of: run)
                                .frame(minHeight: 140, idealHeight: 300, maxHeight: .infinity)
                        }
                    }
                }
            }
        case .releases:
            if model.releases.isEmpty {
                noReleases
            } else {
                PhoneStack(selection: $model.selectedReleaseID, opensSelection: model.pageOnOpen == .releases) {
                    List(model.releases, selection: $model.selectedReleaseID) { release in
                        CompactReleaseRow(release: release)
                            .tag(release.id)
                    }
                    .accessibilityIdentifier("builds.releases.compact")
                } page: { id in
                    if let release = model.releases.first(where: { $0.id == id }) {
                        VSplitView {
                            ReleaseInspector(release: release, model: model)
                                .frame(minHeight: 180, idealHeight: 280, maxHeight: .infinity)
                            ReleaseNotes(release: release)
                                .frame(minHeight: 140, idealHeight: 300, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
    }

    // MARK: Panes

    private var runsTable: some View {
        RunsTable(runs: model.runs, selection: $model.selectedRunID)
    }

    private var releasesTable: some View {
        ReleasesTable(releases: model.releases, selection: $model.selectedReleaseID)
    }

    /// The selected run's or release's details: the Mac's inspector, an iPad's pane beside the log.
    @ViewBuilder private var details: some View {
        switch model.mode {
        case .runs:
            if let run = model.currentRun {
                RunInspector(run: run, selectedStep: $model.selectedStep, model: model)
                    .id(run.id)
            } else {
                ContentUnavailableView(String(localized: "No Run Selected", bundle: #bundle), systemImage: ToolKind.builds.symbol)
                    .accessibilityIdentifier("builds.inspector.noRun")
            }
        case .releases:
            if let release = model.currentRelease {
                ReleaseInspector(release: release, model: model)
            } else {
                ContentUnavailableView(String(localized: "No Release Selected", bundle: #bundle), systemImage: "tag")
                    .accessibilityIdentifier("builds.inspector.noRelease")
            }
        }
    }

    /// The log of the step picked in the run's details.
    @ViewBuilder private func log(of run: WorkflowRun?) -> some View {
        if let run, let selectedStep = model.selectedStep, let found = run.step(selectedStep) {
            LogPane(run: run, job: found.job, step: found.step, lines: model.stepLog)
        } else {
            ContentUnavailableView(
                String(localized: "No Step Selected", bundle: #bundle), systemImage: "text.alignleft",
                description: Text("Pick a step in the run's details to read its log.", bundle: #bundle)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.canvas)
            .accessibilityIdentifier("builds.log.noStep")
        }
    }

    /// The notes of the release picked in the table.
    @ViewBuilder private func notes(of release: Release?) -> some View {
        if let release {
            ReleaseNotes(release: release)
        } else {
            ContentUnavailableView(String(localized: "No Release Selected", bundle: #bundle), systemImage: "tag")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.canvas)
                .accessibilityIdentifier("builds.releaseNotes.noRelease")
        }
    }

    /// No runs to show: on their way, can't be read, or none.
    @ViewBuilder private var noRuns: some View {
        switch model.runsLoad {
        case .loading:
            loading(String(localized: "Reading the runs…", bundle: #bundle))
        case .failed(let message):
            unavailable(String(localized: "Can't Show the Runs", bundle: #bundle), message)
        case .loaded:
            empty(
                String(localized: "No Runs", bundle: #bundle),
                description: String(localized: "This project's repository has no workflow runs yet.", bundle: #bundle)
            )
            .accessibilityIdentifier("builds.noRuns")
        }
    }

    @ViewBuilder private var noReleases: some View {
        switch model.releasesLoad {
        case .loading:
            loading(String(localized: "Reading the releases…", bundle: #bundle))
        case .failed(let message):
            unavailable(String(localized: "Can't Show the Releases", bundle: #bundle), message)
        case .loaded:
            empty(
                String(localized: "No Releases", bundle: #bundle),
                description: String(localized: "This project's repository has no releases yet.", bundle: #bundle)
            )
            .accessibilityIdentifier("builds.noReleases")
        }
    }

    private func loading(_ text: String) -> some View {
        ProgressView(text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.canvas)
            .accessibilityIdentifier("builds.loading")
    }

    /// gh can't read the list: why, and Try Again.
    private func unavailable(_ title: String, _ message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(verbatim: message)
        } actions: {
            Button(String(localized: "Try Again", bundle: #bundle)) {
                Task { await model.refresh() }
            }
            .accessibilityIdentifier("builds.tryAgain")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.canvas)
        .accessibilityIdentifier("builds.unavailable")
    }

    private func empty(_ title: String, description: String) -> some View {
        ContentUnavailableView(title, systemImage: ToolKind.builds.symbol, description: Text(verbatim: description))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.canvas)
    }
}

/// A run in an iPhone's list: its status, title, number, workflow and branch, and when it started.
private struct CompactRunRow: View {
    let run: WorkflowRun

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: run.status.symbol)
                .foregroundStyle(run.status.color)
                .accessibilityLabel(run.status.title)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: run.title)
                    .foregroundStyle(.textPrimary)
                    .lineLimit(2)
                Text("#\(String(run.displayNumber)) · \(run.workflow) · \(run.branch)", bundle: #bundle, comment: "A run's number, workflow and branch: #1288 · CI · fix/payments-backoff")
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(run.startedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("builds.run.\(run.id)")
    }
}

/// A release in an iPhone's list: its tag, title and date.
private struct CompactReleaseRow: View {
    let release: Release

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: release.tag)
                    .monospaced()
                    .foregroundStyle(.textPrimary)
                if release.isLatest {
                    Text("Latest", bundle: #bundle, comment: "A release that is the latest")
                        .font(.caption)
                        .foregroundStyle(.success)
                } else if release.isPrerelease {
                    Text("Pre-release", bundle: #bundle, comment: "A release that is a pre-release")
                        .font(.caption)
                        .foregroundStyle(.warning)
                }
            }
            Text(verbatim: release.title)
                .foregroundStyle(.textSecondary)
                .lineLimit(1)
            Text(release.publishedAt, format: .dateTime.day().month(.abbreviated).year())
                .font(.caption)
                .foregroundStyle(.textSecondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("builds.release.\(release.id)")
    }
}

/// The runs, newest first.
private struct RunsTable: View {
    let runs: [WorkflowRun]
    @Binding var selection: WorkflowRun.ID?

    var body: some View {
        Table(runs, selection: $selection) {
            TableColumn(String(localized: "Status", bundle: #bundle)) { run in
                Image(systemName: run.status.symbol)
                    .foreground(run.status.color, onSelection: .primary)
                    .accessibilityLabel(run.status.title)
            }
            .width(48)
            TableColumn(String(localized: "Run", bundle: #bundle, comment: "The column of a run's commit message and number")) { run in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: run.title)
                        .lineLimit(1)
                    Text("#\(String(run.displayNumber)) · \(run.commit)", bundle: #bundle, comment: "A run's number and commit: #641 · 8e7ccf3")
                        .font(.caption.monospaced())
                        .foreground(.textSecondary, onSelection: .secondary)
                }
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("builds.run.\(run.id)")
            }
            .width(min: 220, ideal: 340)
            TableColumn(String(localized: "Workflow", bundle: #bundle)) { run in
                Text(verbatim: run.workflow)
            }
            .width(min: 70, ideal: 90)
            TableColumn(String(localized: "Branch", bundle: #bundle)) { run in
                Text(verbatim: run.branch)
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 100, ideal: 150)
            TableColumn(String(localized: "Duration", bundle: #bundle)) { run in
                if run.status == .running {
                    Text(verbatim: run.status.title)
                        .foreground(.info, onSelection: .primary)
                } else {
                    elapsedText(run.duration)
                }
            }
            .width(80)
            TableColumn(String(localized: "Started", bundle: #bundle)) { run in
                Text(run.startedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                    .monospacedDigit()
            }
            .width(min: 100, ideal: 120)
        }
        .accessibilityIdentifier("builds.runs")
    }
}

/// The releases, newest first.
private struct ReleasesTable: View {
    let releases: [Release]
    @Binding var selection: Release.ID?

    var body: some View {
        Table(releases, selection: $selection) {
            TableColumn(String(localized: "Tag", bundle: #bundle)) { release in
                HStack(spacing: 6) {
                    Text(verbatim: release.tag)
                        .monospaced()
                    if release.isLatest {
                        Label(String(localized: "Latest", bundle: #bundle, comment: "A release that is the latest"), systemImage: "star.fill")
                            .labelStyle(.badge(.success))
                    } else if release.isPrerelease {
                        Label(String(localized: "Pre-release", bundle: #bundle, comment: "A release that is a pre-release"), systemImage: "flask")
                            .labelStyle(.badge(.warning))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("builds.release.\(release.id)")
            }
            .width(min: 160, ideal: 220)
            TableColumn(String(localized: "Title", bundle: #bundle)) { release in
                Text(verbatim: release.title)
            }
            TableColumn(String(localized: "Published", bundle: #bundle)) { release in
                Text(release.publishedAt, format: .dateTime.day().month(.abbreviated).year())
            }
            .width(110)
            TableColumn(String(localized: "Assets", bundle: #bundle, comment: "The column of a release's number of files")) { release in
                Text(release.assets.count, format: .number)
                    .monospacedDigit()
            }
            .width(60)
        }
        .accessibilityIdentifier("builds.releases")
    }
}

/// A run: its state, where it ran, and its jobs with their steps.
private struct RunInspector: View {
    let run: WorkflowRun
    @Binding var selectedStep: StepReference?
    let model: BuildsModel

    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(run.status.title, systemImage: run.status.symbol)
                        .labelStyle(.badge(run.status.color))
                    Text(verbatim: run.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("#\(String(run.displayNumber)) · \(run.workflow) · \(run.branch) · \(run.commit)", bundle: #bundle, comment: "Where a run ran: its number, workflow, branch and commit")
                        .font(.caption.monospaced())
                        .foregroundStyle(.textSecondary)
                        .textSelection(.enabled)
                }

                HStack {
                    if run.status == .running || run.status == .queued {
                        Button(String(localized: "Cancel Run", bundle: #bundle), systemImage: "xmark.circle") {
                            Task { await model.cancel() }
                        }
                        .disabled(model.isActing)
                        .accessibilityIdentifier("builds.inspector.cancel")
                    } else if run.jobs.contains(where: { $0.status == .failure }) {
                        // A run with failed jobs runs those again, or every job from the menu.
                        Menu {
                            Button(String(localized: "Re-run Failed Jobs", bundle: #bundle)) { Task { await model.rerun(failedOnly: true) } }
                            Button(String(localized: "Re-run All Jobs", bundle: #bundle)) { Task { await model.rerun(failedOnly: false) } }
                        } label: {
                            Label(String(localized: "Re-run", bundle: #bundle), systemImage: "arrow.clockwise")
                        } primaryAction: {
                            Task { await model.rerun(failedOnly: true) }
                        }
                        .fixedSize()
                        .disabled(model.isActing)
                        .help(String(localized: "Re-run Failed Jobs", bundle: #bundle))
                        .accessibilityIdentifier("builds.inspector.rerun")
                    } else {
                        Button(String(localized: "Re-run", bundle: #bundle), systemImage: "arrow.clockwise") {
                            Task { await model.rerun(failedOnly: false) }
                        }
                        .disabled(model.isActing)
                        .help(String(localized: "Re-run All Jobs", bundle: #bundle))
                        .accessibilityIdentifier("builds.inspector.rerun")
                    }
                    if let url = model.webURL {
                        Button(String(localized: "Open on GitHub", bundle: #bundle), systemImage: "arrow.up.forward.square") {
                            openURL(url)
                        }
                        .accessibilityIdentifier("builds.inspector.openOnGitHub")
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Jobs", bundle: #bundle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.textSecondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(run.jobs) { job in
                        JobRow(job: job, selectedStep: $selectedStep)
                    }
                }
            }
            .padding(16)
        }
        .accessibilityIdentifier("builds.inspector.run")
    }
}

/// A job, opened on its steps when it failed, still runs or holds the step whose log is shown.
/// Clicking a step shows its log under the table.
private struct JobRow: View {
    let job: Job
    @Binding var selectedStep: StepReference?

    @State private var isExpanded: Bool

    init(job: Job, selectedStep: Binding<StepReference?>) {
        self.job = job
        _selectedStep = selectedStep
        _isExpanded = State(initialValue: job.opensInitially(showing: selectedStep.wrappedValue))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(job.steps) { step in
                    let reference = StepReference(job: job.name, step: step.name, occurrence: step.occurrence)
                    let isSelected = selectedStep == reference
                    Button {
                        selectedStep = reference
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: step.status.symbol)
                                .foregroundStyle(step.status.color)
                                .accessibilityLabel(step.status.title)
                            Text(verbatim: step.name)
                                .foregroundStyle(.textPrimary)
                            Spacer()
                            elapsedText(step.duration)
                                .foregroundStyle(.textSecondary)
                        }
                        .font(.callout)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isSelected ? AnyShapeStyle(Color.accent.opacity(0.16)) : AnyShapeStyle(.clear), in: .capsule)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("builds.inspector.step.\(job.name).\(step.name)")
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: job.status.symbol)
                    .foregroundStyle(job.status.color)
                    .accessibilityLabel(job.status.title)
                Text(verbatim: job.name)
                    .foregroundStyle(.textPrimary)
                Spacer()
                elapsedText(job.duration)
                    .foregroundStyle(.textSecondary)
            }
        }
        .accessibilityIdentifier("builds.inspector.job.\(job.name)")
    }
}

/// The log of one step, as wide and as tall as the space under the table. A code view: its lines
/// are in Fira Code.
private struct LogPane: View {
    let run: WorkflowRun
    let job: Job
    let step: Step
    let lines: BuildLoad<[String]>

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: step.status.symbol)
                    .foregroundStyle(step.status.color)
                    .accessibilityLabel(step.status.title)
                Text(verbatim: job.name)
                    .foregroundStyle(.textSecondary)
                Image(systemName: "chevron.forward")
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
                    .accessibilityHidden(true)
                Text(verbatim: step.name)
                    .fontWeight(.semibold)
                    .foregroundStyle(.textPrimary)
                Text("#\(String(run.displayNumber))", bundle: #bundle, comment: "A run's number: #641")
                    .monospacedDigit()
                    .foregroundStyle(.textSecondary)
                Spacer()
                elapsedText(step.duration)
                    .foregroundStyle(.textSecondary)
                Button(String(localized: "Copy Log", bundle: #bundle), systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString((lines.value ?? []).joined(separator: "\n"), forType: .string)
                }
                    .disabled(lines.value?.isEmpty ?? true)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(String(localized: "Copy Log", bundle: #bundle))
                    .accessibilityIdentifier("builds.log.copy")
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            switch lines {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.surfaceSunken)
                    .accessibilityIdentifier("builds.log.loading")
            case .failed(let message):
                ContentUnavailableView(String(localized: "No Log", bundle: #bundle, comment: "A step's log can't be shown"), systemImage: "text.alignleft",
                                       description: Text(verbatim: message))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.surfaceSunken)
                    .accessibilityIdentifier("builds.log.failure")
            case .loaded(let lines) where lines.isEmpty:
                ContentUnavailableView(String(localized: "No Log", bundle: #bundle, comment: "A step's log can't be shown"), systemImage: "text.alignleft",
                                       description: Text("This step wrote nothing.", bundle: #bundle))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.surfaceSunken)
                    .accessibilityIdentifier("builds.log.empty")
            case .loaded(let lines):
                lineGrid(lines)
            }
        }
        .accessibilityIdentifier("builds.log")
    }

    /// The lines, made as they scroll into view: a CI log of tens of thousands of lines shows at once. The
    /// widest number sizes the numbers' column, and the longest line, hidden behind the rows, the scroll width.
    private func lineGrid(_ lines: [String]) -> some View {
            let longest = lines.indices.max { lines[$0].utf8.count < lines[$1].utf8.count }.map { lines[$0] } ?? ""
            return ScrollView([.vertical, .horizontal]) {
                ZStack(alignment: .topLeading) {
                    logRow(number: lines.count, line: longest, numbers: lines.count)
                        .hidden()
                        .accessibilityHidden(true)
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(lines.indices, id: \.self) { index in
                            logRow(number: index + 1, line: lines[index], numbers: lines.count)
                        }
                    }
                }
                .codeFont(.callout)
                .textSelection(.enabled)
                .padding(14)
            }
            .defaultScrollAnchor(.topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.surfaceSunken)
            .accessibilityIdentifier("builds.log.lines")
    }

    /// A log line after its number, right-aligned in a column as wide as the largest number (the code font's
    /// digits are monospaced).
    private func logRow(number: Int, line: String, numbers: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(numbers, format: .number)
                .hidden()
                .overlay(alignment: .trailing) {
                    Text(number, format: .number)
                        .foregroundStyle(.textSecondary)
                }
            Text(verbatim: line)
                .foregroundStyle(color(of: LogLineKind(line)))
                .fixedSize()
        }
    }

    private func color(of kind: LogLineKind) -> Color {
        switch kind {
        case .error: .danger
        case .detail: .warning
        case .quiet: .textSecondary
        case .plain: .textPrimary
        }
    }
}

/// A release's notes, under the releases table.
private struct ReleaseNotes: View {
    let release: Release

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: release.tag)
                        .font(.title3.monospaced().weight(.semibold))
                        .foregroundStyle(.textPrimary)
                    Text(verbatim: release.title)
                        .font(.title3)
                        .foregroundStyle(.textPrimary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Group {
                    if release.notes.isEmpty {
                        Text("No notes.", bundle: #bundle, comment: "A release without notes")
                            .foregroundStyle(.textSecondary)
                    } else {
                        Text(verbatim: release.notes)
                            .foregroundStyle(.textPrimary)
                    }
                }
                .lineSpacing(3)
                .textSelection(.enabled)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.canvas)
        .accessibilityIdentifier("builds.releaseNotes")
    }
}

/// A release: its tag, title, date and assets.
private struct ReleaseInspector: View {
    let release: Release
    let model: BuildsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: release.tag)
                        .font(.title3.monospaced().weight(.semibold))
                        .foregroundStyle(.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: release.title)
                        .foregroundStyle(.textPrimary)
                    Text(release.publishedAt, format: .dateTime.day().month().year().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Assets", bundle: #bundle, comment: "The heading of a release's files")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.textSecondary)
                        .accessibilityAddTraits(.isHeader)
                    if release.assets.isEmpty {
                        Text("No assets.", bundle: #bundle, comment: "A release without files")
                            .font(.callout)
                            .foregroundStyle(.textSecondary)
                    }
                    ForEach(release.assets, id: \.self) { asset in
                        HStack {
                            Label {
                                Text(verbatim: asset)
                                    .monospaced()
                            } icon: {
                                Image(systemName: "doc.zipper")
                                    .accessibilityHidden(true)
                            }
                            .font(.callout)
                            .foregroundStyle(.textPrimary)
                            Spacer()
                            switch model.download(of: asset, in: release) {
                            case .running?:
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityIdentifier("builds.inspector.download.\(asset)")
                            case .saved(let file)?:
                                Button(String(localized: "Show in Finder", bundle: #bundle), systemImage: "magnifyingglass") {
                                    NSWorkspace.shared.activateFileViewerSelecting([file])
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help(String(localized: "Show in Finder", bundle: #bundle))
                                .accessibilityIdentifier("builds.inspector.showInFinder.\(asset)")
                            case nil:
                                Button(String(localized: "Download", bundle: #bundle), systemImage: "arrow.down.circle") {
                                    Task { await model.download(asset, of: release) }
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help(String(localized: "Download", bundle: #bundle))
                                .accessibilityLabel(String(localized: "Download \(asset)", bundle: #bundle, comment: "The button that downloads a release's file, named"))
                                .accessibilityIdentifier("builds.inspector.download.\(asset)")
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .accessibilityIdentifier("builds.inspector.release")
    }
}

// MARK: Previews

/// A project whose repository has no runs and no releases, for the previews.
let previewProjectWithoutRuns = Project(
    id: "NEW", name: "New Project", kind: .app, tint: .accent, symbol: "sparkles",
    path: "~/Developer/New", repository: "new",
    activity: ProjectActivity(openTickets: 0, ticketsInReview: 0, draftTickets: 0, lastBuild: .passed, lastBuildAt: SampleClock.date())
)

/// The window of a sample project, on `focus`, in `mode` when given.
@MainActor private func previewModel(_ projectID: Project.ID, focus: String? = nil, mode: BuildsModel.Mode? = nil) -> BuildsModel {
    let model = BuildsModel(project: Project.sample(projectID) ?? previewProjectWithoutRuns, focus: focus, store: SampleBuildStore())
    if let mode {
        model.mode = mode
    }
    return model
}

#Preview("Runs", traits: .appChrome, .fixedLayout(width: 1180, height: 720)) {
    BuildsRootView(model: previewModel("ORD"))
}

#Preview("Runs, Dark", traits: .appChrome, .fixedLayout(width: 1180, height: 720)) {
    BuildsRootView(model: previewModel("PAY", focus: "641"))
        .preferredColorScheme(.dark)
}

#Preview("Releases", traits: .appChrome, .fixedLayout(width: 1180, height: 720)) {
    BuildsRootView(model: previewModel("ORD", focus: "release:v1.4.0"))
}

#Preview("Releases, Dark", traits: .appChrome, .fixedLayout(width: 1180, height: 720)) {
    BuildsRootView(model: previewModel("ORD", focus: "release:v1.5.0-rc.1"))
        .preferredColorScheme(.dark)
}

#Preview("No Runs", traits: .appChrome, .fixedLayout(width: 900, height: 600)) {
    BuildsRootView(model: BuildsModel(project: previewProjectWithoutRuns, focus: nil, store: SampleBuildStore()))
}

#Preview("No Releases", traits: .appChrome, .fixedLayout(width: 1180, height: 720)) {
    BuildsRootView(model: previewModel("SHOP", mode: .releases))
}

#Preview("Largest Text", traits: .largestText, .fixedLayout(width: 1180, height: 720)) {
    BuildsRootView(model: previewModel("PAY", focus: "641"))
}

#Preview("iPad", traits: .padLayout, .fixedLayout(width: 760, height: 720)) {
    BuildsRootView(model: previewModel("PAY", focus: "641"))
}

#Preview("iPad, Dark", traits: .padLayout, .fixedLayout(width: 760, height: 720)) {
    BuildsRootView(model: previewModel("ORD", focus: "1288"))
        .preferredColorScheme(.dark)
}

#Preview("iPad, Releases", traits: .padLayout, .fixedLayout(width: 760, height: 720)) {
    BuildsRootView(model: previewModel("ORD", focus: "release:v1.4.0"))
}

#Preview("iPad, Largest Text", traits: .padLayout, .largestText, .fixedLayout(width: 760, height: 720)) {
    BuildsRootView(model: previewModel("PAY", focus: "641"))
}

#Preview("iPhone", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    BuildsRootView(model: previewModel("ORD"))
}

#Preview("iPhone, Run", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    BuildsRootView(model: previewModel("ORD", focus: "1288"))
}

#Preview("iPhone, Run, Dark", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    BuildsRootView(model: previewModel("PAY", focus: "641"))
        .preferredColorScheme(.dark)
}

#Preview("iPhone, Release", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    BuildsRootView(model: previewModel("ORD", focus: "release:v1.4.0"))
}

#Preview("iPhone, Largest Text", traits: .phoneLayout, .largestText, .fixedLayout(width: 420, height: 800)) {
    BuildsRootView(model: previewModel("ORD", focus: "1288"))
}
