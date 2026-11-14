import AppKit
import AZDesign
import ProjectData
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
    @Environment(\.openRoute) private var openRoute
    /// The app's project data; nil in previews, whose actions only call the closures.
    private let session: ProjectSession?
    @State private var newProject: NewProjectModel?
    @State private var addingFolder = false
    @State private var removal: Project?
    @State private var failure: Failure?

    /// An alert after a failed change.
    private struct Failure: Identifiable {
        let title: String
        let message: String
        /// For a folder without a project: offer to create one there.
        var folderWithoutProject: URL?
        var id: String { title + message }
    }

    /// The overview never gets narrower than an iPhone, nor lower than a tool window can be.
    private static let minimumOverviewSize = CGSize(width: 390, height: 420)
    /// The width the projects and the overview need side by side; narrower, an iPad's layout.
    static let macWidth: CGFloat = 900

    /// The window's size, size classes and whether it narrowed from a regular width (AZDesign), which
    /// pick the Mac's, an iPad's or an iPhone's layout.
    @State private var adaptiveWindow = AdaptiveWindowState()
    /// The projects column: shown on a Mac, folded behind the sidebar button on an iPad.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// The app's Projects window, on the app's projects: New Project, Add Existing Folder and Remove Project
    /// change them through the session.
    public init(directory: ProjectDirectory, session: ProjectSession, selection: Binding<Project.ID?>) {
        self.init(
            model: ProjectsModel(store: DirectoryProjectStore(directory: directory), selection: selection.wrappedValue),
            selection: selection, session: session
        )
    }

    /// A Projects window on given projects, such as the samples.
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
        session: ProjectSession? = nil,
        onNewProject: @escaping () -> Void = {},
        onNewSubProject: @escaping (Project.ID) -> Void = { _ in },
        onAddFolder: @escaping () -> Void = {}
    ) {
        _model = State(initialValue: model)
        self.session = session
        _selection = selection
        self.onNewProject = onNewProject
        self.onNewSubProject = onNewSubProject
        self.onAddFolder = onAddFolder
    }

    public var body: some View {
        presentations(window)
    }

    private var window: some View {
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
            ToolbarItem(placement: .primaryAction) {
                projectMenu
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
        // A project removed, here or outside the app, leaves the selection.
        .onChange(of: model.tree.projects.map(\.id)) {
            model.keepSelection()
        }
        // File ▸ New Project… (⇧⌘N), as the toolbar's menu offers it.
        .newItemCommand(String(localized: "New Project…", bundle: #bundle, comment: "File menu item, ⇧⌘N")) {
            newProjectAction()
        }
    }

    /// The sheets and alerts of New Project, Add Existing Folder and Remove Project.
    private func presentations(_ content: some View) -> some View {
        content
            .sheet(item: $newProject) { newModel in
                if let session {
                    NewProjectSheet(model: newModel) { request throws(ProjectError) in
                        try await session.create(request)
                    } addInstead: { folder throws(ProjectError) in
                        try await session.open(folder: folder)
                    } done: { id in
                        model.select(id)
                    }
                }
            }
            .fileImporter(isPresented: $addingFolder, allowedContentTypes: [.folder]) { result in
                guard case .success(let folder) = result else { return }
                addFolder(folder)
            }
            .alert(
                Text("Remove “\(removal?.name ?? "")” from Hephaestus V3?", bundle: #bundle),
                isPresented: Binding { removal != nil } set: { if !$0 { removal = nil } }, presenting: removal
            ) { project in
                Button(String(localized: "Remove", bundle: #bundle), role: .destructive) {
                    remove(project)
                }
                Button(String(localized: "Cancel", bundle: #bundle), role: .cancel) {}
            } message: { project in
                Text(verbatim: removalMessage(project))
            }
            .alert(
                Text(verbatim: failure?.title ?? ""),
                isPresented: Binding { failure != nil } set: { if !$0 { failure = nil } }, presenting: failure
            ) { failure in
                if let folder = failure.folderWithoutProject {
                    Button(String(localized: "Create Project Here…", bundle: #bundle)) {
                        startNewProject(existingFolder: folder)
                    }
                }
                Button(String(localized: "OK", bundle: #bundle), role: .cancel) {}
            } message: { failure in
                Text(verbatim: failure.message)
            }
            // File ▸ Add Existing Folder… (⌘O).
            .focusedSceneValue(\.addFolder, AddFolderCommand { addExistingFolder() })
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
            switch model.state {
            case .loading:
                ProgressView {
                    Text("Loading Projects…", bundle: #bundle)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.canvas)
                .accessibilityIdentifier("projects.loading")
            case .failed(let message):
                ContentUnavailableView {
                    Label(String(localized: "Can’t Open the Projects", bundle: #bundle), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: message)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.canvas)
                .accessibilityIdentifier("projects.failed")
            case .ready where model.isEmpty:
                ContentUnavailableView {
                    Label(String(localized: "No Projects", bundle: #bundle), systemImage: "folder.badge.plus")
                } description: {
                    Text("Create a project, or add a folder that holds one, such as a project of HephaestusV2.", bundle: #bundle)
                } actions: {
                    Button(String(localized: "New Project…", bundle: #bundle), action: newProjectAction)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("projects.empty.newProject")
                    Button(String(localized: "Add Existing Folder…", bundle: #bundle), action: addExistingFolder)
                        .accessibilityIdentifier("projects.empty.addFolder")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.canvas)
                .accessibilityIdentifier("projects.empty")
            case .ready:
                selectionDetail
            }
        }
        .frame(minWidth: Self.minimumOverviewSize.width, minHeight: Self.minimumOverviewSize.height)
    }

    /// The selected project's overview, or what to do without one.
    private var selectionDetail: some View {
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
            Button(String(localized: "New Project…", bundle: #bundle), action: newProjectAction)
                .accessibilityIdentifier("projects.add.newProject")
            Button(String(localized: "New Sub Project…", bundle: #bundle)) {
                if let parent = model.selection {
                    if session != nil { startNewProject(parent: parent) } else { onNewSubProject(parent) }
                }
            }
            .disabled(model.selectedProject == nil)
            .accessibilityIdentifier("projects.add.newSubProject")
            Button(String(localized: "Add Existing Folder…", bundle: #bundle), action: addExistingFolder)
                .accessibilityIdentifier("projects.add.existingFolder")
        } label: {
            Label(String(localized: "Add Project", bundle: #bundle), systemImage: "plus")
                .toolbarLabelPadding()
        }
        .help(String(localized: "Add Project", bundle: #bundle))
        .accessibilityIdentifier("projects.add")
    }
}

extension ProjectsRootView {
    /// The selected project's actions: Show in Finder, Remove Project….
    var projectMenu: some View {
        Menu {
            Button(String(localized: "Show in Finder", bundle: #bundle)) {
                if let project = model.selectedProject {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
                }
            }
            .accessibilityIdentifier("projects.more.showInFinder")
            Button(String(localized: "Project Settings…", bundle: #bundle)) {
                if let project = model.selectedProject {
                    openRoute(.projectSettings(project.id))
                }
            }
            .accessibilityIdentifier("projects.more.settings")
            Divider()
            Button(String(localized: "Remove Project…", bundle: #bundle), role: .destructive) {
                removal = model.selectedProject
            }
            .disabled(session == nil)
            .accessibilityIdentifier("projects.more.remove")
        } label: {
            Label(String(localized: "More", bundle: #bundle, comment: "The selected project's actions"), systemImage: "ellipsis.circle")
                .toolbarLabelPadding()
        }
        .disabled(model.selectedProject == nil)
        .help(String(localized: "Project Actions", bundle: #bundle))
        .accessibilityIdentifier("projects.more")
    }

    func newProjectAction() {
        if session != nil { startNewProject() } else { onNewProject() }
    }

    func addExistingFolder() {
        if session != nil { addingFolder = true } else { onAddFolder() }
    }

    func startNewProject(parent: Project.ID? = nil, existingFolder: URL? = nil) {
        let location = NewProjectModel.defaultLocation(selected: model.selectedProject, in: model.tree)
        newProject = NewProjectModel(projects: model.tree.projects, location: location, parentID: parent, existingFolder: existingFolder)
    }

    /// Adds the folder's project and selects it. A folder without a project offers to create one there.
    func addFolder(_ folder: URL) {
        guard let session else { return }
        Task {
            do throws(ProjectError) {
                model.select(try await session.open(folder: folder.path))
            } catch .noProject {
                failure = Failure(title: String(localized: "No Project in “\(folder.lastPathComponent)”", bundle: #bundle),
                                  message: String(localized: "The folder has no .hephaestus/project.yml.", bundle: #bundle),
                                  folderWithoutProject: folder)
            } catch {
                failure = Failure(title: String(localized: "Can’t Add the Folder", bundle: #bundle), message: ProjectMessages.message(error))
            }
        }
    }

    func remove(_ project: Project) {
        guard let session else { return }
        Task {
            do throws(ProjectError) {
                try await session.remove(project.id)
            } catch {
                failure = Failure(title: String(localized: "Can’t Remove “\(project.name)”", bundle: #bundle), message: ProjectMessages.message(error))
            }
        }
    }

    /// The folder stays; its sub projects go with it.
    func removalMessage(_ project: Project) -> String {
        let folder = String(localized: "The folder and its files stay on disk: \(project.path).", bundle: #bundle)
        let count = model.descendantCount(of: project.id)
        guard count > 0 else { return folder }
        let subprojects = count == 1
            ? String(localized: "Its sub project is removed with it.", bundle: #bundle)
            : String(localized: "Its \(count) sub projects are removed with it.", bundle: #bundle)
        return folder + " " + subprojects
    }
}

/// File ▸ Add Existing Folder… (⌘O), while the Projects window is the key window.
public struct AddFolderCommand {
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @MainActor
    public func callAsFunction() {
        action()
    }
}

extension FocusedValues {
    @Entry public var addFolder: AddFolderCommand?
}

extension NewProjectModel: Identifiable {}

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
            // The entries of the list that didn't load, with why; they load once their folder is fine.
            if !model.unavailable.isEmpty && !model.isFiltering {
                Section(String(localized: "Unavailable", bundle: #bundle, comment: "A sidebar section of projects that didn't load")) {
                    ForEach(model.unavailable) { entry in
                        UnavailableRow(entry: entry)
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

/// An entry of the list that didn't load: its folder's name, and why.
private struct UnavailableRow: View {
    let entry: ProjectDirectory.Unavailable

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: (entry.path as NSString).lastPathComponent)
                    .foregroundStyle(.textSecondary)
                Text(verbatim: entry.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } icon: {
            Image(systemName: "questionmark.folder")
                .foregroundStyle(.textSecondary)
        }
        .help(Text(verbatim: entry.path))
        .selectionDisabled()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("projects.unavailable.\((entry.path as NSString).lastPathComponent)")
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

private func previewModel(_ store: SampleProjectStore, _ selection: Project.ID? = nil) -> ProjectsModel {
    ProjectsModel(store: store, selection: selection)
}

#Preview("Loading", traits: .appChrome, .fixedLayout(width: 1000, height: 660)) {
    ProjectsRootView(model: previewModel(SampleProjectStore(projects: [], state: .loading)), selection: .constant(nil))
}

#Preview("Can't Open", traits: .appChrome, .fixedLayout(width: 1000, height: 660)) {
    let message = "Another copy of Hephaestus V3 is using its data. Quit it, then open this one again."
    ProjectsRootView(model: previewModel(SampleProjectStore(projects: [], state: .failed(message))), selection: .constant(nil))
}

#Preview("No Projects", traits: .appChrome, .fixedLayout(width: 1000, height: 660)) {
    ProjectsRootView(model: previewModel(SampleProjectStore(projects: [])), selection: .constant(nil))
}

#Preview("Unavailable", traits: .appChrome, .fixedLayout(width: 1000, height: 660)) {
    let unavailable = [
        ProjectDirectory.Unavailable(path: "/Users/example/Developer/archive", reason: "The folder is missing.", parentID: nil),
        ProjectDirectory.Unavailable(path: "/Users/example/Developer/shop/legacy", reason: "The folder has no .hephaestus/project.yml.",
                                     parentID: "SHOP"),
    ]
    ProjectsRootView(model: previewModel(SampleProjectStore(unavailable: unavailable), "ORD"), selection: .constant("ORD"))
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
