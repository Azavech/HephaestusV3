import Foundation
@testable import ProjectsKit
import ToolsFoundation

/// A small tree of projects for the tests:
///
/// - Alpha (`A`, service, with a contract and two environments)
///   - Alpha One (`A1`, service, uses its parent's settings, one environment of its own)
///     - Alpha One Lib (`A1L`, library, uses its parent's settings)
///   - Alpha Two (`A2`, service without a contract, its own settings and environment)
/// - Béta (`B`, app)
///   - Béta Kit (`BK`, library)
/// - Core (`C`, library)
struct MockProjectStore: ProjectStore {
    let projects: [Project]
    var events: [Project.ID: [ActivityItem]] = [:]
    var state: ProjectDirectory.State = .ready
    var unavailable: [ProjectDirectory.Unavailable] = []

    init(events: [Project.ID: [ActivityItem]] = [:]) {
        projects = [
            Self.project("A", "Alpha", .service, contract: "1.0.0", environments: ["Staging", "Production"]),
            Self.project("A1", "Alpha One", .service, contract: "2.0.0", environments: ["Own"], parent: "A"),
            Self.project("A1L", "Alpha One Lib", .library, parent: "A1"),
            Self.project("A2", "Alpha Two", .service, environments: ["Separate", "Staging"], parent: "A"),
            Self.project("B", "Béta", .app),
            Self.project("BK", "Béta Kit", .library, parent: "B"),
            Self.project("C", "Core", .library),
        ]
        self.events = events
    }

    func activity(of projectID: Project.ID) -> [ActivityItem] {
        events[projectID] ?? []
    }

    static func project(
        _ id: String, _ name: String, _ kind: Project.Kind, contract: String? = nil, environments: [String] = [],
        parent: Project.ID? = nil
    ) -> Project {
        Project(
            id: id, name: name, kind: kind, tint: .accent, symbol: "folder", path: "~/\(id)", repository: id.lowercased(),
            environments: environments.map {
                DeploymentEnvironment(name: $0, cluster: "cluster", namespace: id.lowercased(), url: "https://\($0).example.com", health: .healthy)
            },
            activity: ProjectActivity(
                openTickets: 1, ticketsInReview: 1, draftTickets: 1, lastBuild: .passed, lastBuildAt: SampleClock.date(),
                contractVersion: contract
            ),
            parentID: parent
        )
    }

    /// An event of `tool` about `subject`, `minutesAgo` minutes before the sample clock's now.
    static func event(_ tool: ToolKind, _ subject: String, minutesAgo: Int) -> ActivityItem {
        ActivityItem(
            tool: tool, text: "Something about \(subject)", subject: subject,
            date: SampleClock.date(minutes: -minutesAgo), tone: .neutral, focus: subject
        )
    }
}
