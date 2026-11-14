import AZDesign
import SwiftUI
import ToolsFoundation

/// Where a project stands: its figures, a tile per tool, its environments and what happened lately.
///
/// Nothing here has a fixed width. The tool and environment grids take as many columns as fit (all
/// of them in one row, or an even split), the figures wrap when their row doesn't fit, and the activity
/// list fills the height a tall window has.
struct ProjectOverview: View {
    let project: Project
    let model: ProjectsModel

    @State private var width: CGFloat = 0

    @Environment(\.openRoute) private var openRoute
    @Environment(\.availableTools) private var availableTools

    private let spacing: CGFloat = 14

    var body: some View {
        let subprojects = model.children(of: project.id)
        let environments = model.environments(of: project.id)
        let tools = project.tools.filter(availableTools.contains)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 28) {
                        header
                        Spacer(minLength: 28)
                        if let activity = project.activity {
                            figures(activity, hasSubprojects: !subprojects.isEmpty)
                        }
                    }
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        if let activity = project.activity {
                            figures(activity, hasSubprojects: !subprojects.isEmpty)
                        }
                    }
                }
                if let fileIssue = project.fileIssue {
                    FileIssueBanner(reason: fileIssue)
                }
                // The tools whose feature has come over from V2; the others are hidden.
                if !tools.isEmpty {
                    section(String(localized: "Tools", bundle: #bundle), id: "tools") {
                    LazyVGrid(columns: columns(for: tools.count, minimum: 220), spacing: spacing) {
                        ForEach(tools) { tool in
                            ToolTile(
                                tool: tool, project: project, ticketTotals: model.ticketTotals(of: project.id),
                                environmentCount: environments.environments.count
                            ) {
                                openRoute(.tool(tool, project: project.id))
                            }
                        }
                    }
                    }
                }
                if !subprojects.isEmpty {
                    section(String(localized: "Sub Projects", bundle: #bundle), id: "subProjects") {
                        LazyVGrid(columns: columns(for: subprojects.count, minimum: 240), spacing: spacing) {
                            ForEach(subprojects) { subproject in
                                SubprojectCard(
                                    project: subproject, subprojectCount: model.descendantCount(of: subproject.id),
                                    openTickets: model.ticketTotals(of: subproject.id).open
                                ) {
                                    select(subproject.id)
                                }
                            }
                        }
                    }
                }
                // A sub project that uses its parent's settings lists its parent's environments.
                if !environments.environments.isEmpty {
                    section(
                        String(localized: "Environments", bundle: #bundle), id: "environments",
                        note: environments.inheritedFrom.map {
                            Text("Inherited from \($0.name)", bundle: #bundle, comment: "The project whose environments a sub project uses")
                        }
                    ) {
                        LazyVGrid(columns: columns(for: environments.environments.count, minimum: 300), spacing: spacing) {
                            ForEach(environments.environments) { environment in
                                EnvironmentCard(environment: environment)
                            }
                        }
                    }
                }
                section(
                    String(localized: "Activity", bundle: #bundle), id: "activity",
                    note: subprojects.isEmpty ? nil : Text("Sub projects included", bundle: #bundle)
                ) {
                    ActivityList(entries: model.activity(of: project.id), showsProjects: !subprojects.isEmpty) { entry in
                        openRoute(entry.item.route(in: entry.project.id))
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width - 56 } action: { width = $0 }
        }
        .background(.canvas)
        .navigationSubtitle(Text(verbatim: project.name))
    }

    /// Selects an ancestor or a sub project; the sidebar unfolds the parents of its row.
    private func select(_ id: Project.ID) {
        model.select(id)
    }

    private func columns(for count: Int, minimum: CGFloat) -> [GridItem] {
        let count = OverviewGrid.columnCount(for: count, minimum: minimum, spacing: spacing, width: width)
        return Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: count)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ProjectIcon(project)
                .font(.largeTitle)
                .frame(minWidth: 44)
            VStack(alignment: .leading, spacing: 4) {
                let ancestors = model.ancestors(of: project.id)
                if !ancestors.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(ancestors) { ancestor in
                            Button {
                                select(ancestor.id)
                            } label: {
                                Label {
                                    Text(verbatim: ancestor.name)
                                } icon: {
                                    ProjectIcon(ancestor)
                                }
                            }
                            .buttonStyle(.link)
                            .accessibilityIdentifier("projects.path.\(ancestor.id)")
                            Image(systemName: "chevron.forward")
                                .font(.caption)
                                .foregroundStyle(.textSecondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .font(.callout)
                }
                Text(verbatim: project.name)
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 10) {
                    Label(project.kind.title, systemImage: project.kind.symbol)
                    Text(verbatim: project.id)
                        .monospaced()
                    Text(verbatim: project.path)
                        .monospaced()
                        .truncationMode(.middle)
                }
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(.textSecondary)
            }
        }
        .accessibilityIdentifier("projects.header")
    }

    /// The ticket figures count the sub projects' tickets too, as the project's Tickets window lists
    /// them. They sit in one row when it fits, then two by two, then one under the other.
    private func figures(_ activity: ProjectActivity, hasSubprojects: Bool) -> some View {
        let totals = model.ticketTotals(of: project.id)
        let open = Figure(
            Text(totals.open, format: .number),
            caption: hasSubprojects ? Text("Open tickets, sub projects included", bundle: #bundle) : Text("Open tickets", bundle: #bundle)
        )
        .accessibilityIdentifier("projects.figure.open")
        let inReview = Figure(Text(totals.inReview, format: .number), caption: Text("In review", bundle: #bundle))
            .accessibilityIdentifier("projects.figure.inReview")
        let drafts = Figure(Text(totals.drafts, format: .number), caption: Text("Drafts", bundle: #bundle))
            .accessibilityIdentifier("projects.figure.drafts")
        let lastBuild = LastBuildFigure(outcome: activity.lastBuild)
            .accessibilityIdentifier("projects.figure.lastBuild")
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 36) {
                open
                inReview
                drafts
                lastBuild
            }
            .fixedSize()
            Grid(alignment: .topLeading, horizontalSpacing: 36, verticalSpacing: 16) {
                GridRow {
                    open
                    inReview
                }
                GridRow {
                    drafts
                    lastBuild
                }
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 16) {
                open
                inReview
                drafts
                lastBuild
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section(_ title: String, id: String, note: Text? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("projects.section.\(id)")
                if let note {
                    note
                        .font(.callout)
                        .foregroundStyle(.textSecondary)
                        .accessibilityIdentifier("projects.section.\(id).note")
                }
            }
            content()
        }
    }
}

/// The project's own last build, as a figure: its outcome with a symbol in its color, and a caption.
private struct LastBuildFigure: View {
    let outcome: ProjectActivity.BuildOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(outcome.title, systemImage: outcome.symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(outcome.color)
            Text("Last build", bundle: #bundle)
                .font(.caption)
                .foregroundStyle(.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One tool of the project: what it would show, and the button that opens its window.
private struct ToolTile: View {
    let tool: ToolKind
    let project: Project
    /// The project's ticket figures, its sub projects included.
    let ticketTotals: (open: Int, inReview: Int, drafts: Int)
    /// The environments the overview lists for the project, inherited ones included.
    let environmentCount: Int
    let open: () -> Void

    /// One height for every tool's symbol, so the titles of a row line up.
    @ScaledMetric(relativeTo: .title2) private var iconHeight = 26.0

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: tool.symbol)
                    .font(.title2)
                    .foregroundStyle(.accent)
                    .frame(height: iconHeight, alignment: .bottomLeading)
                    .accessibilityHidden(true)
                Text(verbatim: tool.title)
                    .font(.headline)
                    .foregroundStyle(.textPrimary)
                status
                    .font(.callout)
                    .foregroundStyle(.textSecondary)
                    .lineLimit(2, reservesSpace: true)
                Button(action: open) {
                    Text("Open", bundle: #bundle, comment: "Opens a tool's window from its tile")
                }
                // Every tile has an Open button: VoiceOver's list of buttons names the tool.
                .accessibilityLabel(Text("Open \(tool.title)", bundle: #bundle, comment: "Opens a tool's window, such as Open Tickets"))
                .accessibilityIdentifier("projects.tool.\(tool.rawValue).open")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: tool.title))
        .accessibilityIdentifier("projects.tool.\(tool.rawValue)")
    }

    @ViewBuilder private var status: some View {
        switch tool {
        case .dashboard:
            if DashboardWidgetKind.hasServiceMap(project) {
                Text("Tickets, builds and services in widgets you arrange", bundle: #bundle)
            } else {
                Text("Tickets and builds in widgets you arrange", bundle: #bundle)
            }
        case .tickets:
            // As the Tickets window lists them: with the sub projects' tickets.
            Text("\(ticketTotals.open) open, \(ticketTotals.inReview) in review, ^[\(ticketTotals.drafts) draft](inflect: true)", bundle: #bundle)
        case .serviceMap:
            Text("^[\(project.activity?.serviceCount ?? 0) service](inflect: true) in ^[\(environmentCount) environment](inflect: true)", bundle: #bundle)
        case .contracts:
            if let activity = project.activity, let version = activity.contractVersion {
                Text("Version \(version), ^[\(activity.operationCount) operation](inflect: true)", bundle: #bundle)
            } else {
                Text("No contract yet", bundle: #bundle)
            }
        case .chat:
            Text("Ask Claude, which reads through these tools", bundle: #bundle)
        case .builds:
            if let activity = project.activity {
                Text("Last run on \(activity.lastBuildAt, format: .dateTime.day().month(.abbreviated).hour().minute())", bundle: #bundle)
            } else {
                Text("Workflow runs and releases on GitHub", bundle: #bundle)
            }
        }
    }
}

/// A place where the service runs, with its health.
private struct EnvironmentCard: View {
    let environment: DeploymentEnvironment

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    // Health shows once the Service Map reads it.
                    if let health = environment.health {
                        StatusDot(health.color)
                    }
                    Text(verbatim: environment.name)
                        .font(.headline)
                        .foregroundStyle(.textPrimary)
                    Spacer(minLength: 12)
                    if let health = environment.health {
                        Label(health.title, systemImage: health.symbol)
                            .labelStyle(.badge(health.color))
                    }
                }
                if !environment.place.isEmpty {
                    Text(verbatim: environment.place)
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.textSecondary)
                }
                if let url = environment.url {
                    Text(verbatim: url)
                        .font(.callout)
                        .monospaced()
                        .foregroundStyle(.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text("No API address", bundle: #bundle, comment: "An environment without a URL")
                        .font(.callout)
                        .foregroundStyle(.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("projects.environment.\(environment.id)")
    }
}

/// What happened lately in the project's tools, newest first. Clicking an event opens its tool on it.
private struct ActivityList: View {
    let entries: [ActivityEntry]
    /// For a project with sub projects: each event says which project it is from.
    let showsProjects: Bool
    let open: (ActivityEntry) -> Void

    var body: some View {
        GroupBox {
            if entries.isEmpty {
                Text("Nothing happened in this project yet.", bundle: #bundle)
                    .foregroundStyle(.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .accessibilityIdentifier("projects.activity.empty")
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
                    ForEach(entries) { entry in
                        if entry.id != entries.first?.id {
                            Divider()
                                .gridCellUnsizedAxes(.horizontal)
                        }
                        ActivityRow(entry: entry, showsProject: showsProjects) { open(entry) }
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .accessibilityIdentifier("projects.activity")
    }
}

/// One event: its tool, what happened, what it is about and when. VoiceOver reads it as one button.
private struct ActivityRow: View {
    let entry: ActivityEntry
    /// Whether the row names the project the event is from, when the list mixes sub projects.
    let showsProject: Bool
    let action: () -> Void

    private static let dateFormat = Date.FormatStyle.dateTime.day().month(.abbreviated).hour().minute()

    var body: some View {
        let item = entry.item
        GridRow {
            if showsProject {
                Label {
                    Text(verbatim: entry.project.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.textSecondary)
                } icon: {
                    ProjectIcon(entry.project)
                }
                .lineLimit(1)
                .help(Text(verbatim: entry.project.name))
                .accessibilityHidden(true)
            }
            Image(systemName: item.tool.symbol)
                .foregroundStyle(item.tone.color)
                .frame(minWidth: 20)
                .help(Text(verbatim: item.tool.title))
                .accessibilityHidden(true)
            Button(action: action) {
                Text(verbatim: item.text)
                    .foregroundStyle(.textPrimary)
                    .lineLimit(1)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // The row's other cells are hidden from VoiceOver: the button says all of it.
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("projects.activity.\(entry.id)")
            Text(verbatim: item.subject)
                .font(.caption.monospaced())
                .foregroundStyle(.textSecondary)
                .lineLimit(1)
                .accessibilityHidden(true)
            Text(item.date, format: Self.dateFormat)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.textSecondary)
                .gridColumnAlignment(.trailing)
                .accessibilityHidden(true)
        }
    }

    /// The tool, what happened, its subject and its date; first the project, when the row shows it.
    private var accessibilityLabel: Text {
        let item = entry.item
        if showsProject {
            return Text(
                "\(entry.project.name), \(item.tool.title): \(item.text), \(item.subject), \(item.date, format: Self.dateFormat)", bundle: #bundle,
                comment: "An activity event, for VoiceOver: project, tool: what happened, its subject, its date"
            )
        }
        return Text(
            "\(item.tool.title): \(item.text), \(item.subject), \(item.date, format: Self.dateFormat)", bundle: #bundle,
            comment: "An activity event, for VoiceOver: tool: what happened, its subject, its date"
        )
    }
}

/// A sub project in its parent's overview: what it is and where it stands. Clicking it selects it.
private struct SubprojectCard: View {
    let project: Project
    /// Its sub projects, at every depth.
    let subprojectCount: Int
    /// Its open tickets, its sub projects included.
    let openTickets: Int
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            GroupBox {
                HStack(alignment: .top, spacing: 12) {
                    ProjectIcon(project)
                        .font(.title2)
                        .frame(minWidth: 28)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: project.name)
                                .font(.headline)
                                .foregroundStyle(.textPrimary)
                            Text(verbatim: project.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.textSecondary)
                        }
                        HStack(spacing: 8) {
                            Label(project.kind.title, systemImage: project.kind.symbol)
                            if subprojectCount > 0 {
                                Text("^[\(subprojectCount) sub project](inflect: true)", bundle: #bundle)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                        if let activity = project.activity {
                            HStack(spacing: 8) {
                                Text("^[\(openTickets) open ticket](inflect: true)", bundle: #bundle)
                                    .font(.callout)
                                    .foregroundStyle(.textSecondary)
                                Label(activity.lastBuild.title, systemImage: activity.lastBuild.symbol)
                                    .labelStyle(.badge(activity.lastBuild.color))
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward")
                        .foregroundStyle(.textSecondary)
                        .accessibilityHidden(true)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("projects.subproject.\(project.id)")
    }
}

/// The project's file on disk is invalid now: the version loaded before shows, until the file is fixed or
/// the next change writes it again.
private struct FileIssueBanner: View {
    let reason: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("project.yml can't be read", bundle: #bundle, comment: "A banner over a project whose file became invalid")
                    .font(.headline)
                    .foregroundStyle(.textPrimary)
                Text("The project shows as it was before the file changed. Fix the file, or change a setting to write it again.", bundle: #bundle)
                    .foregroundStyle(.textSecondary)
                Text(verbatim: reason)
                    .font(.callout)
                    .monospaced()
                    .foregroundStyle(.textSecondary)
                    .textSelection(.enabled)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.warning)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.surface, in: .card)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("projects.fileIssue")
    }
}
