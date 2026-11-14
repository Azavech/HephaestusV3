import AZDesign
import SwiftUI
import ToolsFoundation

/// The Projects window, the project selector: pick a project, see where it stands, open its tools.
///
/// It replaces V2's breadcrumb and Dashboard. It is a picker, not a hub: tools never live in it.
public struct ProjectsRootView: View {
    @Binding var selection: Project.ID?
    var onNewProject: () -> Void
    /// New Sub Project…, with the parent it is for: the selected project.
    var onNewSubProject: (Project.ID) -> Void
    var onAddFolder: () -> Void

    @State private var model: ProjectsModel

    /// The overview never gets narrower than an iPhone, nor lower than a tool window can be.
    private static let minimumOverviewSize = CGSize(width: 390, height: 420)
    /// The width the projects and the overview need side by side; narrower, an iPad's layout.
    static let macWidth: CGFloat = 900

    /// The window's size, size classes and whether it narrowed from a regular width (AZDesign), which
    /// pick the Mac's, an iPad's or an iPhone's layout.
    @State private var adaptiveWindow = AdaptiveWindowState()
    /// The projects column: shown on a Mac, folded behind the sidebar button on an iPad.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    public init(
        projects: [Project],
        selection: Binding<Project.ID?>,
        onNewProject: @escaping () -> Void = {},
        onNewSubProject: @escaping (Project.ID) -> Void = { _ in },
        onAddFolder: @escaping () -> Void = {}
    ) {
        self.init(
            model: ProjectsModel(store: SampleProjectStore(projects: projects), selection: selection.wrappedValue),
            selection: selection, onNewProject: onNewProject, onNewSubProject: onNewSubProject, onAddFolder: onAddFolder
        )
    }

    init(
        model: ProjectsModel,
        selection: Binding<Project.ID?>,
        onNewProject: @escaping () -> Void = {},
        onNewSubProject: @escaping (Project.ID) -> Void = { _ in },
        onAddFolder: @escaping () -> Void = {}
    ) {
        _model = State(initialValue: model)
        _selection = selection
        self.onNewProject = onNewProject
        self.onNewSubProject = onNewSubProject
        self.onAddFolder = onAddFolder
    }

    public var body: some View {
        Group {
            if layout == .phone {
                phoneBody
            } else {
                splitBody
            }
        }
        // Measures the window and gives its views their layout, size classes and whether it narrowed
        // from a regular width (AZDesign's adaptive window).
        .adaptiveWindow($adaptiveWindow, layout: layout)
        .frame(minWidth: Self.minimumOverviewSize.width, minHeight: Self.minimumOverviewSize.height)
        .navigationTitle(Text("Projects", bundle: #bundle))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                addMenu
            }
        }
        // The window's selection and the model's follow each other: a route selects through the
        // binding, the sidebar and the overview through the model.
        .onAppear {
            model.select(selection)
        }
        .onChange(of: selection) { _, id in
            model.select(id)
        }
        .onChange(of: model.selection) { _, id in
            selection = id
        }
        .onFocusRequest { focus in
            model.select(focus: focus)
        }
        // File ▸ New Project… (⇧⌘N), as the toolbar's menu offers it.
        .newItemCommand(String(localized: "New Project…", bundle: #bundle, comment: "File menu item, ⇧⌘N")) {
            onNewProject()
        }
    }

    /// The Mac's: the projects beside the overview. An iPad's folds the projects behind the sidebar
    /// button, as an iPad's split view does when it lacks the room, so the overview keeps it.
    private var splitBody: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ProjectSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detail
        }
        .searchable(text: $model.query, placement: .sidebar, prompt: Text("Filter Projects", bundle: #bundle))
        .onChange(of: layout, initial: true) {
            columnVisibility = layout == .mac ? .all : .detailOnly
        }
    }

    /// An iPhone's: the projects, then the picked one's overview as a page with Back.
    private var phoneBody: some View {
        PhoneStack(selection: Binding { model.selection } set: { model.select($0) }) {
            ProjectSidebar(model: model)
                .searchable(text: $model.query, prompt: Text("Filter Projects", bundle: #bundle))
        } page: { _ in
            detail
        }
    }

    /// The selected project's overview, or what to do without one.
    private var detail: some View {
        Group {
            if let project = model.selectedProject {
                ProjectOverview(project: project, model: model)
            } else {
                ContentUnavailableView(
                    String(localized: "No Project Selected", bundle: #bundle),
                    systemImage: "folder",
                    description: Text("Pick a project to see where it stands and open its tools.", bundle: #bundle)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.canvas)
                .accessibilityIdentifier("projects.noSelection")
            }
        }
        .frame(minWidth: Self.minimumOverviewSize.width, minHeight: Self.minimumOverviewSize.height)
    }

    /// The Mac's layout while the projects and the overview fit side by side, an iPad's below that,
    /// an iPhone's at compact width.
    private var layout: WindowLayout {
        adaptiveWindow.layout(macWidth: Self.macWidth)
    }

    private var addMenu: some View {
        Menu {
            Button(String(localized: "New Project…", bundle: #bundle), action: onNewProject)
                .accessibilityIdentifier("projects.add.newProject")
            Button(String(localized: "New Sub Project…", bundle: #bundle)) {
                if let parent = model.selection {
                    onNewSubProject(parent)
                }
            }
            .disabled(model.selectedProject == nil)
            .accessibilityIdentifier("projects.add.newSubProject")
            Button(String(localized: "Add Existing Folder…", bundle: #bundle), action: onAddFolder)
                .accessibilityIdentifier("projects.add.existingFolder")
        } label: {
            Label(String(localized: "Add Project", bundle: #bundle), systemImage: "plus")
                .toolbarLabelPadding()
        }
        .help(String(localized: "Add Project", bundle: #bundle))
        .accessibilityIdentifier("projects.add")
    }
}

/// The projects: the top-level ones grouped by kind, each with its sub projects under it, which a
/// disclosure triangle folds. While filtering, the matches alone, without the tree.
private struct ProjectSidebar: View {
    let model: ProjectsModel

    var body: some View {
        List(selection: Binding { model.selection } set: { model.select($0) }) {
            ForEach(model.sidebarSections) { section in
                Section(section.kind.pluralTitle) {
                    ForEach(section.entries, id: \.project.id) { entry in
                        if model.isFiltering {
                            SidebarProjectRow(project: entry.project, openTickets: model.ticketTotals(of: entry.project.id).open)
                        } else {
                            ProjectTreeRow(project: entry.project, model: model)
                        }
                    }
                }
            }
        }
        .overlay {
            if model.hasNoMatches {
                NoMatchingProjects(query: model.query)
                    .accessibilityIdentifier("projects.noMatches")
            }
        }
    }
}

/// A project of the sidebar, with its sub projects under it.
private struct ProjectTreeRow: View {
    let project: Project
    let model: ProjectsModel

    var body: some View {
        let children = model.children(of: project.id)
        let row = SidebarProjectRow(project: project, openTickets: model.ticketTotals(of: project.id).open)
        if children.isEmpty {
            row
        } else {
            DisclosureGroup(isExpanded: Binding { model.isExpanded(project.id) } set: { model.setExpanded($0, project.id) }) {
                ForEach(children) { child in
                    ProjectTreeRow(project: child, model: model)
                }
            } label: {
                row
            }
        }
    }
}

/// A row of the sidebar. Its count is the open tickets of the project and its sub projects, as its
/// Tickets window lists them.
private struct SidebarProjectRow: View {
    let project: Project
    let openTickets: Int

    var body: some View {
        ProjectRow(project: project)
            .badge(openTickets)
            .tag(project.id)
            .accessibilityIdentifier("projects.row.\(project.id)")
    }
}

/// A project's icon, name and identifier.
struct ProjectRow: View {
    let project: Project

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: project.name)
                Text(verbatim: project.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            ProjectIcon(project)
        }
    }
}

/// What a list says when its filter matches no project.
struct NoMatchingProjects: View {
    let query: String

    var body: some View {
        ContentUnavailableView(
            String(localized: "No Matching Projects", bundle: #bundle),
            systemImage: "magnifyingglass",
            description: Text("No project’s name or identifier contains “\(ProjectTree.normalized(query))”.", bundle: #bundle)
        )
    }
}

// MARK: - Previews

private func previewModel(_ selection: Project.ID?, query: String = "") -> ProjectsModel {
    ProjectsModel(store: SampleProjectStore(), selection: selection, query: query)
}

#Preview("Loaded", traits: .appChrome, .fixedLayout(width: 1000, height: 660)) {
    ProjectsRootView(model: previewModel("ORD"), selection: .constant("ORD"))
}

#Preview("Loaded, Dark", traits: .appChrome, .fixedLayout(width: 1000, height: 660)) {
    ProjectsRootView(model: previewModel("ORD"), selection: .constant("ORD"))
        .preferredColorScheme(.dark)
}

#Preview("Parent Project", traits: .appChrome, .fixedLayout(width: 1000, height: 660)) {
    ProjectsRootView(model: previewModel("SHOP"), selection: .constant("SHOP"))
}

#Preview("App Project", traits: .appChrome, .fixedLayout(width: 1000, height: 660)) {
    ProjectsRootView(model: previewModel("TLS"), selection: .constant("TLS"))
}

#Preview("Filtered", traits: .appChrome, .fixedLayout(width: 1000, height: 660)) {
    ProjectsRootView(model: previewModel("ORD", query: "kit"), selection: .constant("ORD"))
}

#Preview("No Matches", traits: .appChrome, .fixedLayout(width: 1000, height: 660)) {
    ProjectsRootView(model: previewModel("ORD", query: "xyz"), selection: .constant("ORD"))
}

#Preview("No Selection", traits: .appChrome, .fixedLayout(width: 1000, height: 660)) {
    ProjectsRootView(model: previewModel(nil), selection: .constant(nil))
}

#Preview("Narrow", traits: .appChrome, .fixedLayout(width: 640, height: 660)) {
    ProjectsRootView(model: previewModel("SHOP"), selection: .constant("SHOP"))
}

#Preview("Largest Text", traits: .largestText, .fixedLayout(width: 1000, height: 660)) {
    ProjectsRootView(model: previewModel("SHOP"), selection: .constant("SHOP"))
}
