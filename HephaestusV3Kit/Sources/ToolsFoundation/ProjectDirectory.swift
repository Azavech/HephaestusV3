import Observation
import SwiftUI

/// The projects every window reads: the app's own, loaded from their folders, or the samples of the
/// previews. ToolsScenes keeps the app's directory in step with the project data; a window reads it from
/// the environment (`\.projectDirectory`) and follows its changes.
@Observable
public final class ProjectDirectory {
    /// Where the projects are.
    public enum State: Equatable, Sendable {
        /// The app is loading its data.
        case loading
        /// The projects are loaded.
        case ready
        /// The app's data can't be used; the message says why, in the user's words.
        case failed(String)
    }

    /// An entry of the project list that didn't load: its folder, and why, in the user's words.
    public struct Unavailable: Identifiable, Hashable, Sendable {
        public let path: String
        public let reason: String
        /// The project whose sub projects list it; nil for a top-level entry.
        public let parentID: Project.ID?

        public init(path: String, reason: String, parentID: Project.ID?) {
            self.path = path
            self.reason = reason
            self.parentID = parentID
        }

        public var id: String { path }
    }

    public private(set) var state: State
    public private(set) var tree: ProjectTree
    public private(set) var unavailable: [Unavailable]

    public init(projects: [Project], state: State = .ready, unavailable: [Unavailable] = []) {
        self.state = state
        tree = ProjectTree(projects)
        self.unavailable = unavailable
    }

    /// Every project, top-level and sub projects, in their order.
    public var projects: [Project] { tree.projects }

    public func project(_ id: Project.ID?) -> Project? {
        tree.project(id)
    }

    /// Replaces what the directory holds; a value equal to the current one changes nothing.
    public func update(projects: [Project], state: State, unavailable: [Unavailable]) {
        if tree.projects != projects { tree = ProjectTree(projects) }
        if self.state != state { self.state = state }
        if self.unavailable != unavailable { self.unavailable = unavailable }
    }

    /// The ticket counts of each project on its own, once the tickets are loaded; nil in the samples, whose
    /// figures come with each project's `activity`.
    public private(set) var ticketCounts: [Project.ID: TicketCounts]?

    public func update(ticketCounts: [Project.ID: TicketCounts]) {
        if self.ticketCounts != ticketCounts { self.ticketCounts = ticketCounts }
    }

    /// The ticket figures of a project with all its sub projects, as its Tickets window lists them.
    public func ticketTotals(of id: Project.ID) -> (open: Int, inReview: Int, drafts: Int) {
        guard let ticketCounts else { return tree.ticketTotals(of: id) }
        return tree.family(of: id).reduce((0, 0, 0)) { total, project in
            let counts = ticketCounts[project.id] ?? TicketCounts()
            return (total.0 + counts.open, total.1 + counts.inReview, total.2 + counts.drafts)
        }
    }

    /// The sample projects, for previews and tests.
    public static func samples() -> ProjectDirectory {
        ProjectDirectory(projects: Project.samples)
    }
}

/// How many tickets of one project are open (neither done nor drafts), in review, and drafts.
nonisolated public struct TicketCounts: Hashable, Sendable {
    public var open: Int
    public var inReview: Int
    public var drafts: Int

    public init(open: Int = 0, inReview: Int = 0, drafts: Int = 0) {
        self.open = open
        self.inReview = inReview
        self.drafts = drafts
    }
}

extension ProjectDirectory {
    /// The directory of the previews, made once.
    @MainActor public static let previewSamples = ProjectDirectory.samples()
}

extension EnvironmentValues {
    /// The projects of the app; the samples by default, in previews.
    @Entry public var projectDirectory = ProjectDirectory.previewSamples

    /// The tools the running app offers. The others
    /// are hidden from menus, tiles and lists. Every tool by default, in previews.
    @Entry public var availableTools: Set<ToolKind> = Set(ToolKind.allCases)
}
