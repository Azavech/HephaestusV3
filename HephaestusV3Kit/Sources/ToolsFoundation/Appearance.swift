import AZDesign
import SwiftUI

// Names, symbols and colors of the shared types. Colors are AZDesign's semantic colors only.

extension ToolKind {
    public var title: String {
        switch self {
        case .dashboard: String(localized: "Dashboard", bundle: #bundle)
        case .tickets: String(localized: "Tickets", bundle: #bundle)
        case .serviceMap: String(localized: "Service Map", bundle: #bundle)
        case .contracts: String(localized: "Contracts", bundle: #bundle)
        case .builds: String(localized: "Builds", bundle: #bundle)
        case .chat: String(localized: "Chat", bundle: #bundle)
        }
    }

    public var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .tickets: "checklist"
        case .serviceMap: "point.3.connected.trianglepath.dotted"
        case .contracts: "curlybraces.square"
        case .builds: "hammer"
        case .chat: "bubble.left.and.text.bubble.right"
        }
    }

    /// The ⌘-key that opens the tool for the key window's project. The Dashboard is ⌘1, as in V2.
    public var shortcut: KeyEquivalent {
        switch self {
        case .dashboard: "1"
        case .tickets: "2"
        case .serviceMap: "3"
        case .contracts: "4"
        case .builds: "5"
        case .chat: "6"
        }
    }
}

extension TicketStatus {
    public var title: String {
        switch self {
        case .draft: String(localized: "Draft", bundle: #bundle)
        case .created: String(localized: "Created", bundle: #bundle)
        case .inProgress: String(localized: "In Progress", bundle: #bundle)
        case .inReview: String(localized: "In Review", bundle: #bundle)
        case .done: String(localized: "Done", bundle: #bundle)
        }
    }
}

extension TimeWindow {
    public var title: String {
        switch self {
        case .fiveMinutes: String(localized: "5 min", bundle: #bundle)
        case .hour: String(localized: "1 hour", bundle: #bundle)
        case .day: String(localized: "24 hours", bundle: #bundle)
        }
    }
}

extension Project.Kind {
    public var title: String {
        switch self {
        case .service: String(localized: "Service", bundle: #bundle)
        case .app: String(localized: "App", bundle: #bundle)
        case .library: String(localized: "Library", bundle: #bundle)
        case .other: String(localized: "Other", bundle: #bundle, comment: "A project that is neither a service, an app nor a library")
        }
    }

    public var pluralTitle: String {
        switch self {
        case .service: String(localized: "Services", bundle: #bundle)
        case .app: String(localized: "Apps", bundle: #bundle)
        case .library: String(localized: "Libraries", bundle: #bundle)
        case .other: String(localized: "Other Projects", bundle: #bundle, comment: "A section of projects that are neither services, apps nor libraries")
        }
    }

    public var symbol: String {
        switch self {
        case .service: "server.rack"
        case .app: "macwindow"
        case .library: "books.vertical"
        case .other: "folder"
        }
    }
}

extension ProjectTint {
    public var color: Color {
        switch self {
        case .accent: .accent
        case .accentSecondary: .accentSecondary
        case .info: .info
        case .success: .success
        case .warning: .warning
        }
    }

    /// The tint's name in Project Settings: the color AZDesign draws.
    public var title: String {
        switch self {
        case .accent: String(localized: "Purple", bundle: #bundle, comment: "A project's tint")
        case .accentSecondary: String(localized: "Pink", bundle: #bundle, comment: "A project's tint")
        case .info: String(localized: "Cyan", bundle: #bundle, comment: "A project's tint")
        case .success: String(localized: "Green", bundle: #bundle, comment: "A project's tint")
        case .warning: String(localized: "Orange", bundle: #bundle, comment: "A project's tint")
        }
    }
}

extension DeploymentEnvironment.Health {
    public var title: String {
        switch self {
        case .healthy: String(localized: "Healthy", bundle: #bundle)
        case .degraded: String(localized: "Degraded", bundle: #bundle)
        case .down: String(localized: "Down", bundle: #bundle)
        }
    }

    public var symbol: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .down: "xmark.octagon.fill"
        }
    }

    public var color: Color {
        switch self {
        case .healthy: .success
        case .degraded: .warning
        case .down: .danger
        }
    }
}

extension DeploymentEnvironment {
    /// The health's name, or Unknown until the Service Map reads it.
    public var healthTitle: String {
        health?.title ?? String(localized: "Unknown", bundle: #bundle, comment: "An environment's health before anything reads it")
    }

    public var healthSymbol: String { health?.symbol ?? "questionmark.circle" }

    public var healthColor: Color { health?.color ?? .textSecondary }

    /// `<cluster> / <namespace>`, or the one that is known; empty when neither is.
    public var place: String {
        [cluster, namespace].compactMap { $0 }.joined(separator: " / ")
    }
}

extension ProjectActivity.BuildOutcome {
    public var title: String {
        switch self {
        case .passed: String(localized: "Passed", bundle: #bundle)
        case .failed: String(localized: "Failed", bundle: #bundle)
        case .running: String(localized: "Running", bundle: #bundle)
        }
    }

    public var symbol: String {
        switch self {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .running: "arrow.triangle.2.circlepath"
        }
    }

    public var color: Color {
        switch self {
        case .passed: .success
        case .failed: .danger
        case .running: .info
        }
    }
}

extension DashboardWidgetKind {
    /// The title of a widget whose `Title` setting is empty, and its item in the Add Widget menu.
    public var title: String {
        switch self {
        case .project: String(localized: "Project", bundle: #bundle)
        case .tickets: String(localized: "Tickets", bundle: #bundle)
        case .recentBuilds: String(localized: "Recent Builds", bundle: #bundle)
        case .instances: String(localized: "Instances", bundle: #bundle)
        case .serviceGraph: String(localized: "Service Graph", bundle: #bundle)
        case .busiestCalls: String(localized: "Busiest Calls", bundle: #bundle)
        case .failedRequests: String(localized: "Failed Requests", bundle: #bundle)
        case .requestsPerMinute: String(localized: "Requests per Minute", bundle: #bundle)
        }
    }

    public var symbol: String {
        switch self {
        case .project: "folder"
        case .tickets: ToolKind.tickets.symbol
        case .recentBuilds: ToolKind.builds.symbol
        case .instances: "shippingbox"
        case .serviceGraph: ToolKind.serviceMap.symbol
        case .busiestCalls: "arrow.right.arrow.left"
        case .failedRequests: "exclamationmark.triangle"
        case .requestsPerMinute: "chart.xyaxis.line"
        }
    }
}

extension DashboardProjectField {
    /// The label of its checkbox in the settings popover.
    public var title: String {
        switch self {
        case .name: String(localized: "Name", bundle: #bundle)
        case .identifier: String(localized: "Identifier", bundle: #bundle)
        case .type: String(localized: "Type", bundle: #bundle)
        case .folder: String(localized: "Folder", bundle: #bundle)
        }
    }
}
