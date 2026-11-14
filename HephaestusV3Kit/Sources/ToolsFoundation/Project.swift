import Foundation

/// A project the tools work on: a repository, and for a service, the places where it runs.
///
/// A sub project is a project whose folder lies inside its parent's folder, as in V2. It has its own
/// identifier and tickets; sub projects may nest. See `ProjectTree` for walking them.
///
/// Plain values: this example has no store behind it. The data types of ToolsFoundation are
/// `nonisolated` so that windows can carry them (`WindowGroup` values, focused values).
nonisolated public struct Project: Identifiable, Hashable, Sendable {
    /// What a project is decides which tools apply to it.
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case service
        case app
        case library

        public var id: Self { self }
    }

    /// The identifier, also the prefix of its tickets, e.g. `ORD`.
    public let id: String
    public let name: String
    public let kind: Kind
    public let tint: ProjectTint
    /// An SF Symbol name.
    public let symbol: String
    public let path: String
    public let repository: String
    /// Where a service runs. Empty for apps and libraries.
    public let environments: [DeploymentEnvironment]
    public let activity: ProjectActivity
    /// The project whose folder holds this one's; nil for a top-level project.
    public let parentID: Project.ID?
    /// For a sub project: whether it takes its parent's settings, its environments among them (V2's
    /// `Use parent settings`, on by default).
    public let usesParentSettings: Bool

    public init(
        id: String,
        name: String,
        kind: Kind,
        tint: ProjectTint,
        symbol: String,
        path: String,
        repository: String,
        environments: [DeploymentEnvironment] = [],
        activity: ProjectActivity,
        parentID: Project.ID? = nil,
        usesParentSettings: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.tint = tint
        self.symbol = symbol
        self.path = path
        self.repository = repository
        self.environments = environments
        self.activity = activity
        self.parentID = parentID
        self.usesParentSettings = usesParentSettings
    }

    /// The tools that apply to this project, in menu order: the Dashboard first, as in V2, and Chat
    /// last. Contracts only for a service with one.
    public var tools: [ToolKind] {
        switch kind {
        case .service:
            activity.contractVersion == nil
                ? [.dashboard, .tickets, .serviceMap, .builds, .chat]
                : [.dashboard, .tickets, .serviceMap, .contracts, .builds, .chat]
        case .app, .library: [.dashboard, .tickets, .builds, .chat]
        }
    }
}

/// The color of a project. Each case is one of AZDesign's semantic colors.
nonisolated public enum ProjectTint: String, CaseIterable, Sendable {
    case accent
    case accentSecondary
    case info
    case success
    case warning
}

/// A place where a service runs: a cluster context and a namespace.
nonisolated public struct DeploymentEnvironment: Identifiable, Hashable, Sendable {
    public enum Health: Sendable {
        case healthy
        case degraded
        case down
    }

    public var id: String { name }
    public let name: String
    public let cluster: String
    public let namespace: String
    public let url: String
    public let health: Health

    public init(name: String, cluster: String, namespace: String, url: String, health: Health) {
        self.name = name
        self.cluster = cluster
        self.namespace = namespace
        self.url = url
        self.health = health
    }
}

/// What the Projects window says about a project.
///
/// In the real suite each tool's service would answer these figures; here they are sample values.
nonisolated public struct ProjectActivity: Hashable, Sendable {
    public enum BuildOutcome: Sendable {
        case passed
        case failed
        case running
    }

    public let openTickets: Int
    public let ticketsInReview: Int
    public let draftTickets: Int
    public let lastBuild: BuildOutcome
    public let lastBuildAt: Date
    public let contractVersion: String?
    public let operationCount: Int
    public let serviceCount: Int

    public init(
        openTickets: Int,
        ticketsInReview: Int,
        draftTickets: Int,
        lastBuild: BuildOutcome,
        lastBuildAt: Date,
        contractVersion: String? = nil,
        operationCount: Int = 0,
        serviceCount: Int = 0
    ) {
        self.openTickets = openTickets
        self.ticketsInReview = ticketsInReview
        self.draftTickets = draftTickets
        self.lastBuild = lastBuild
        self.lastBuildAt = lastBuildAt
        self.contractVersion = contractVersion
        self.operationCount = operationCount
        self.serviceCount = serviceCount
    }
}

/// "Now" for every sample value, so that previews show the same thing every time.
nonisolated public enum SampleClock {
    /// 11 November 2026 at 14:00 in the Mac's own calendar, moved by the given amounts.
    public static func date(days: Int = 0, hours: Int = 0, minutes: Int = 0) -> Date {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 14))
        return (now ?? .distantPast).addingTimeInterval(TimeInterval(days * 86_400 + hours * 3_600 + minutes * 60))
    }
}

/// The projects as a tree: each top-level project followed by its sub projects, at any depth.
nonisolated public struct ProjectTree: Sendable {
    public let projects: [Project]

    public init(_ projects: [Project]) {
        self.projects = projects
    }

    public func project(_ id: Project.ID?) -> Project? {
        projects.first { $0.id == id }
    }

    /// The direct sub projects of `id`, or the top-level projects for nil, in their order.
    public func children(of id: Project.ID?) -> [Project] {
        projects.filter { $0.parentID == id }
    }

    /// Every sub project of `id` at any depth, depth first: each followed by its own.
    public func descendants(of id: Project.ID) -> [Project] {
        children(of: id).flatMap { [$0] + descendants(of: $0.id) }
    }

    /// The project and its descendants, in tree order.
    public func family(of id: Project.ID) -> [Project] {
        (project(id).map { [$0] } ?? []) + descendants(of: id)
    }

    /// The ancestors of `id`, its top-level project first.
    public func ancestors(of id: Project.ID) -> [Project] {
        guard let parent = project(project(id)?.parentID) else { return [] }
        return ancestors(of: parent.id) + [parent]
    }

    /// 0 for a top-level project, 1 for its sub projects, and so on.
    public func depth(of id: Project.ID) -> Int {
        ancestors(of: id).count
    }

    /// Every project with its depth: each top-level project of `topLevel` followed by its descendants.
    public func ordered(topLevel: [Project]? = nil) -> [(project: Project, depth: Int)] {
        (topLevel ?? children(of: nil)).flatMap { top in
            [(top, 0)] + descendants(of: top.id).map { ($0, depth(of: $0.id)) }
        }
    }

    /// The project whose settings apply to `id`: itself, or for a sub project using its parent's
    /// settings, its parent's source, up the tree.
    public func settingsSource(of id: Project.ID) -> Project? {
        guard let project = project(id) else { return nil }
        if project.parentID != nil, project.usesParentSettings, let parent = self.project(project.parentID) {
            return settingsSource(of: parent.id)
        }
        return project
    }

    /// The environments a project's tools read: those of the project it takes its settings from, its
    /// own when it has its own settings (the user's choice: the overview and every tool agree).
    public func environments(of id: Project.ID) -> [DeploymentEnvironment] {
        settingsSource(of: id)?.environments ?? project(id)?.environments ?? []
    }

    /// The ticket figures of a project with all its descendants.
    public func ticketTotals(of id: Project.ID) -> (open: Int, inReview: Int, drafts: Int) {
        family(of: id).reduce((0, 0, 0)) { total, project in
            (total.0 + project.activity.openTickets, total.1 + project.activity.ticketsInReview, total.2 + project.activity.draftTickets)
        }
    }

    /// `Shop › Orders`: the names of the ancestors and the project.
    public func path(of id: Project.ID) -> String {
        (ancestors(of: id) + (project(id).map { [$0] } ?? [])).map(\.name).joined(separator: " › ")
    }
}
