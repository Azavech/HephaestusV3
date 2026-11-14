import Foundation
import ToolsFoundation

/// Where the projects come from: the app's data (`DirectoryProjectStore`), or the samples of the previews
/// (`SampleProjectStore`).
protocol ProjectStore {
    /// Every project, top-level and sub projects, in their order.
    var projects: [Project] { get }
    /// Whether the projects are loaded, or why they can't be.
    var state: ProjectDirectory.State { get }
    /// The entries of the list that didn't load.
    var unavailable: [ProjectDirectory.Unavailable] { get }
    /// What happened lately in one project's own tools, newest first.
    func activity(of projectID: Project.ID) -> [ActivityItem]
    /// The ticket figures of a project with all its sub projects, as its Tickets window lists them.
    func ticketTotals(of projectID: Project.ID) -> (open: Int, inReview: Int, drafts: Int)
}

extension ProjectStore {
    func ticketTotals(of projectID: Project.ID) -> (open: Int, inReview: Int, drafts: Int) {
        ProjectTree(projects).ticketTotals(of: projectID)
    }
}

/// The app's projects, as the directory holds them. Their tools report no events yet.
struct DirectoryProjectStore: ProjectStore {
    let directory: ProjectDirectory

    var projects: [Project] { directory.projects }
    var state: ProjectDirectory.State { directory.state }
    var unavailable: [ProjectDirectory.Unavailable] { directory.unavailable }

    func activity(of projectID: Project.ID) -> [ActivityItem] {
        []
    }

    func ticketTotals(of projectID: Project.ID) -> (open: Int, inReview: Int, drafts: Int) {
        directory.ticketTotals(of: projectID)
    }
}

/// The sample projects (`Project.samples`) and their sample events.
struct SampleProjectStore: ProjectStore {
    let projects: [Project]
    let state: ProjectDirectory.State
    let unavailable: [ProjectDirectory.Unavailable]

    init(projects: [Project] = Project.samples, state: ProjectDirectory.State = .ready,
         unavailable: [ProjectDirectory.Unavailable] = []) {
        self.projects = projects
        self.state = state
        self.unavailable = unavailable
    }

    func activity(of projectID: Project.ID) -> [ActivityItem] {
        ActivityItem.samples(for: projectID)
    }
}

/// A project as a list shows it, with its depth in the tree: 0 for a top-level project, and for every
/// match while filtering.
nonisolated struct ProjectListEntry: Hashable, Sendable {
    let project: Project
    let depth: Int
}

/// The projects of one kind, as the lists group them.
nonisolated struct ProjectListSection: Hashable, Sendable, Identifiable {
    let kind: Project.Kind
    let entries: [ProjectListEntry]

    var id: Project.Kind { kind }
}

nonisolated extension ProjectTree {
    /// The filter's text, without the spaces around it; empty when the filter shows the whole tree.
    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The projects whose name or identifier contains `query`, ignoring case and diacritics, in their
    /// order. Every project for an empty query.
    func matching(_ query: String) -> [Project] {
        let query = Self.normalized(query)
        guard !query.isEmpty else { return projects }
        return projects.filter { $0.name.localizedStandardContains(query) || $0.id.localizedStandardContains(query) }
    }

    /// Every project in sections by kind (Services, Apps, Libraries), as the lists show them. A section
    /// shows only when it has a project.
    ///
    /// - Without a query: the tree, each top-level project followed by its sub projects, in the section
    ///   of its top-level project's kind, whatever their own.
    /// - With one: the matches alone, flat, each in the section of its own kind.
    func sections(matching query: String) -> [ProjectListSection] {
        let filtering = !Self.normalized(query).isEmpty
        let entries = filtering
            ? matching(query).map { ProjectListEntry(project: $0, depth: 0) }
            : ordered().map { ProjectListEntry(project: $0.project, depth: $0.depth) }
        return Project.Kind.allCases.compactMap { kind in
            let group = entries.filter { entry in
                (filtering ? entry.project : ancestors(of: entry.project.id).first ?? entry.project).kind == kind
            }
            return group.isEmpty ? nil : ProjectListSection(kind: kind, entries: group)
        }
    }
}
