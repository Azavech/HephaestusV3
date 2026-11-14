import Foundation

extension Project {
    /// The projects every window of the example shows.
    public static let samples: [Project] = [
        Project(
            id: "ORD",
            name: "Orders",
            kind: .service,
            tint: .accent,
            symbol: "cart",
            path: "~/Developer/Services/shop/orders",
            repository: "services/orders",
            environments: [
                DeploymentEnvironment(name: "Local", cluster: "docker-desktop", namespace: "shop", url: "http://localhost:8080", health: .healthy),
                DeploymentEnvironment(name: "Staging", cluster: "staging-eu", namespace: "shop", url: "https://orders.staging.example.com", health: .degraded),
                DeploymentEnvironment(name: "Production", cluster: "prod-eu", namespace: "shop", url: "https://orders.example.com", health: .healthy),
            ],
            activity: ProjectActivity(
                openTickets: 5, ticketsInReview: 1, draftTickets: 2,
                lastBuild: .passed, lastBuildAt: SampleClock.date(hours: -2),
                contractVersion: "1.4.0", operationCount: 6, serviceCount: 8
            ),
            parentID: "SHOP"
        ),
        Project(
            id: "PAY",
            name: "Payments",
            kind: .service,
            tint: .success,
            symbol: "creditcard",
            path: "~/Developer/Services/shop/payments",
            repository: "services/payments",
            environments: [
                DeploymentEnvironment(name: "Local", cluster: "docker-desktop", namespace: "shop", url: "http://localhost:8081", health: .healthy),
                DeploymentEnvironment(name: "Staging", cluster: "staging-eu", namespace: "shop", url: "https://payments.staging.example.com", health: .degraded),
                DeploymentEnvironment(name: "Production", cluster: "prod-eu", namespace: "shop", url: "https://payments.example.com", health: .healthy),
            ],
            activity: ProjectActivity(
                openTickets: 3, ticketsInReview: 0, draftTickets: 1,
                lastBuild: .failed, lastBuildAt: SampleClock.date(hours: -5),
                contractVersion: "2.1.0", operationCount: 4, serviceCount: 8
            ),
            parentID: "SHOP"
        ),
        Project(
            id: "GW",
            name: "Edge Gateway",
            kind: .service,
            tint: .info,
            symbol: "network",
            path: "~/Developer/Services/shop/gateway",
            repository: "services/gateway",
            environments: [
                DeploymentEnvironment(name: "Local", cluster: "docker-desktop", namespace: "shop", url: "http://localhost:8000", health: .healthy),
                DeploymentEnvironment(name: "Staging", cluster: "staging-eu", namespace: "shop", url: "https://staging.example.com", health: .healthy),
                DeploymentEnvironment(name: "Production", cluster: "prod-eu", namespace: "shop", url: "https://example.com", health: .healthy),
            ],
            activity: ProjectActivity(
                openTickets: 1, ticketsInReview: 1, draftTickets: 0,
                lastBuild: .running, lastBuildAt: SampleClock.date(minutes: -4),
                contractVersion: "1.0.2", operationCount: 3, serviceCount: 8
            ),
            parentID: "SHOP"
        ),
        Project(
            id: "TLS",
            name: "Tools",
            kind: .app,
            tint: .accentSecondary,
            symbol: "wrench.and.screwdriver",
            path: "~/Developer/Apple/Apps/Tools",
            repository: "apple/tools",
            activity: ProjectActivity(
                openTickets: 4, ticketsInReview: 0, draftTickets: 1,
                lastBuild: .passed, lastBuildAt: SampleClock.date(days: -1, hours: 3)
            )
        ),
        Project(
            id: "AZD",
            name: "AZDesign",
            kind: .library,
            tint: .warning,
            symbol: "paintpalette",
            path: "~/Developer/Apple/Libraries/AZDesign",
            repository: "apple/azdesign",
            activity: ProjectActivity(
                openTickets: 2, ticketsInReview: 0, draftTickets: 0,
                lastBuild: .passed, lastBuildAt: SampleClock.date(hours: -7)
            )
        ),
        // The parent of the shop's services: the namespace they share, its Helm charts and its tickets.
        Project(
            id: "SHOP",
            name: "Shop",
            kind: .service,
            tint: .accentSecondary,
            symbol: "storefront",
            path: "~/Developer/Services/shop",
            repository: "services/shop",
            environments: [
                DeploymentEnvironment(name: "Local", cluster: "docker-desktop", namespace: "shop", url: "http://localhost", health: .healthy),
                DeploymentEnvironment(name: "Staging", cluster: "staging-eu", namespace: "shop", url: "https://staging.example.com", health: .degraded),
                DeploymentEnvironment(name: "Production", cluster: "prod-eu", namespace: "shop", url: "https://example.com", health: .healthy),
            ],
            activity: ProjectActivity(
                openTickets: 2, ticketsInReview: 0, draftTickets: 1,
                lastBuild: .passed, lastBuildAt: SampleClock.date(hours: -9),
                serviceCount: 9
            )
        ),
        // A package inside the Tools app's folder, in the same repository.
        Project(
            id: "TKIT",
            name: "ToolsKit",
            kind: .library,
            tint: .info,
            symbol: "shippingbox",
            path: "~/Developer/Apple/Apps/Tools/ToolsKit",
            repository: "apple/tools",
            activity: ProjectActivity(
                openTickets: 2, ticketsInReview: 1, draftTickets: 0,
                lastBuild: .passed, lastBuildAt: SampleClock.date(days: -1, hours: 3)
            ),
            parentID: "TLS"
        ),
    ]

    /// The sample projects as a tree.
    public static let tree = ProjectTree(samples)

    /// The environments the project's tools read: its own, or those of the project it takes its settings
    /// from. See `ProjectTree.environments(of:)`.
    public var deploymentEnvironments: [DeploymentEnvironment] {
        let inherited = Project.tree.environments(of: id)
        return Project.tree.project(id) == nil ? environments : inherited
    }

    /// The sample project with this identifier.
    public static func sample(_ id: Project.ID) -> Project? {
        samples.first { $0.id == id }
    }
}
