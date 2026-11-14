import Foundation
import Observation
import ToolsFoundation

/// The Projects window: its selection, the sidebar's filter and folding, and what a project's overview
/// lists.
@Observable
final class ProjectsModel {
    /// The projects as a tree, from the store: the app's follow its data as it changes.
    var tree: ProjectTree { ProjectTree(store.projects) }
    /// Whether the projects are loaded, or why they can't be.
    var state: ProjectDirectory.State { store.state }
    /// The entries of the list that didn't load.
    var unavailable: [ProjectDirectory.Unavailable] { store.unavailable }
    /// The project whose overview shows.
    private(set) var selection: Project.ID?
    /// The sidebar's filter: a project's name or identifier.
    var query: String
    /// The parents whose sub projects the sidebar hides. Every parent starts unfolded.
    private(set) var folded: Set<Project.ID> = []

    @ObservationIgnored private let store: any ProjectStore

    /// The most events the overview lists.
    static let activityLimit = 40

    init(store: any ProjectStore, selection: Project.ID? = nil, query: String = "") {
        self.store = store
        self.selection = selection
        self.query = query
        reveal(selection)
    }

    // MARK: Sidebar

    var selectedProject: Project? {
        tree.project(selection)
    }

    /// Whether the filter holds text: the sidebar then lists the matches alone, flat.
    var isFiltering: Bool {
        !ProjectTree.normalized(query).isEmpty
    }

    /// The sidebar's sections: the top-level projects by kind, whose rows hold their sub projects; while
    /// filtering, the matches alone, each in its own kind's section.
    var sidebarSections: [ProjectListSection] {
        let sections = tree.sections(matching: query)
        guard !isFiltering else { return sections }
        return sections.map { ProjectListSection(kind: $0.kind, entries: $0.entries.filter { $0.depth == 0 }) }
    }

    /// Whether the filter matches no project.
    var hasNoMatches: Bool {
        isFiltering && tree.matching(query).isEmpty
    }

    /// The direct sub projects of `id`, in their order.
    func children(of id: Project.ID) -> [Project] {
        tree.children(of: id)
    }

    func isExpanded(_ id: Project.ID) -> Bool {
        !folded.contains(id)
    }

    /// Folds or unfolds a parent in the sidebar. Folding lasts while the window is open.
    func setExpanded(_ expanded: Bool, _ id: Project.ID) {
        if expanded {
            folded.remove(id)
        } else {
            folded.insert(id)
        }
    }

    // MARK: Selection

    /// Selects a project and unfolds its ancestors, so that its row shows in the sidebar, even when it
    /// was selected already.
    func select(_ id: Project.ID?) {
        if id != selection {
            selection = id
        }
        selectionAncestors = id.map { tree.ancestors(of: $0).map(\.id) } ?? []
        reveal(id)
    }

    /// The ancestors of the selection when it was made, outermost first, for `keepSelection()`.
    private var selectionAncestors: [Project.ID] = []

    /// After the projects changed: a selection that left the list moves to its nearest ancestor still
    /// listed, else to the first project; without a selection, the first project is selected.
    func keepSelection() {
        if let selection, tree.project(selection) != nil { return }
        let ancestor = selectionAncestors.last { tree.project($0) != nil }
        select(ancestor ?? tree.children(of: nil).first?.id)
    }

    /// Whether the app has nothing to list: no project, and no entry that didn't load.
    var isEmpty: Bool {
        state == .ready && tree.projects.isEmpty && unavailable.isEmpty
    }

    /// A route's focus: a project's identifier. An identifier that names no project changes nothing.
    func select(focus: String) {
        guard tree.project(focus) != nil else { return }
        select(focus)
    }

    private func reveal(_ id: Project.ID?) {
        guard let id else { return }
        let hidden = folded.intersection(tree.ancestors(of: id).map(\.id))
        if !hidden.isEmpty {
            folded.subtract(hidden)
        }
    }

    // MARK: Overview

    /// The ancestors of `id`, its top-level project first: the overview's path.
    func ancestors(of id: Project.ID) -> [Project] {
        tree.ancestors(of: id)
    }

    /// The number of sub projects of `id`, at every depth.
    func descendantCount(of id: Project.ID) -> Int {
        tree.descendants(of: id).count
    }

    /// The ticket figures of a project with all its sub projects, as its Tickets window lists them.
    func ticketTotals(of id: Project.ID) -> (open: Int, inReview: Int, drafts: Int) {
        store.ticketTotals(of: id)
    }

    /// The environments the overview lists: those of the project whose settings apply. A sub project
    /// that uses its parent's settings lists its parent's, up the tree, and says where they come from.
    func environments(of id: Project.ID) -> ProjectEnvironments {
        guard let project = tree.project(id) else { return ProjectEnvironments(environments: [], inheritedFrom: nil) }
        if project.environmentsAreResolved {
            let parent = project.environments.compactMap(\.inheritedFrom).first.flatMap(tree.project)
            return ProjectEnvironments(environments: project.environments, inheritedFrom: parent)
        }
        let source = tree.settingsSource(of: id) ?? project
        return ProjectEnvironments(environments: source.environments, inheritedFrom: source.id == project.id ? nil : source)
    }

    /// What happened in the project and its sub projects, newest first, at most `activityLimit` events.
    func activity(of id: Project.ID) -> [ActivityEntry] {
        tree.family(of: id)
            .flatMap { member in store.activity(of: member.id).map { ActivityEntry(project: member, item: $0) } }
            .sorted { $0.item.date > $1.item.date }
            .prefix(Self.activityLimit)
            .map(\.self)
    }
}

/// The environments a project's overview lists, and the project they come from when it inherits them.
nonisolated struct ProjectEnvironments: Hashable, Sendable {
    let environments: [DeploymentEnvironment]
    /// The project whose settings the project uses, when it isn't the project itself.
    let inheritedFrom: Project?
}

/// An event and the project it happened in.
struct ActivityEntry: Identifiable, Hashable {
    let project: Project
    let item: ActivityItem

    /// Stable across launches: the project's identifier and the event's.
    var id: String { "\(project.id).\(item.id)" }
}

/// How the overview's grids pick their columns.
nonisolated enum OverviewGrid {
    /// As many equal columns as fit in `width`, choosing a count that divides `count`, so no row is left
    /// half empty. A count with no divisor that fits, such as a service's five tools, would fall into a
    /// single column: from four items it takes the count that leaves the fewest empty places instead.
    static func columnCount(for count: Int, minimum: CGFloat, spacing: CGFloat, width: CGFloat) -> Int {
        let fits = { (columns: Int) in CGFloat(columns) * minimum + CGFloat(columns - 1) * spacing <= width }
        let most = (1...max(count, 1)).reversed().first(where: fits) ?? 1
        var chosen = (1...most).reversed().first { count % $0 == 0 } ?? 1
        if chosen == 1, count > 3, most > 1 {
            chosen = (2...most).reversed().min { (($0 - count % $0) % $0) < (($1 - count % $1) % $1) } ?? 1
        }
        return chosen
    }
}
