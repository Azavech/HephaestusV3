import Foundation
import ToolsFoundation

// `TicketStatus` is in ToolsFoundation: the Dashboard's Tickets widget counts by status too.

/// How urgent a ticket is.
enum TicketPriority: String, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high
    case urgent

    var id: Self { self }
}

/// Something in another tool that a ticket points to. Opening it opens that tool's window.
struct TicketLink: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case service
        case request
        case contract
        case build
    }

    let id: String
    let kind: Kind
    let title: String
    /// What the other tool selects when it opens: a service, a request, an operation, a run.
    let target: String

    /// The window this link opens, for the ticket's project.
    func route(in projectID: Project.ID) -> Route {
        switch kind {
        case .service: .tool(.serviceMap, project: projectID, focus: "service:\(target)")
        case .request: .tool(.serviceMap, project: projectID, focus: "request:\(target)")
        case .contract: .tool(.contracts, project: projectID, focus: target)
        case .build: .tool(.builds, project: projectID, focus: target)
        }
    }
}

/// One entry in a ticket's history.
struct TicketEvent: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case drafted
        case statusChanged
        case commented
    }

    let id: Int
    let kind: Kind
    let text: String
    let date: Date
    /// What a comment says, under the line that announces it.
    var comment: String? = nil
}

/// A ticket as the views show it: plain values, from a `TicketStore`.
struct Ticket: Identifiable, Hashable, Sendable {
    let id: String
    let projectID: Project.ID
    let title: String
    let details: String
    let status: TicketStatus
    let priority: TicketPriority
    let labels: [String]
    let reporter: String
    let createdAt: Date
    let updatedAt: Date
    let links: [TicketLink]
    let events: [TicketEvent]
}

/// Tickets shipped together, such as the work for one release.
struct TicketBundle: Identifiable, Hashable, Sendable {
    let id: String
    let projectID: Project.ID
    let title: String
    let ticketIDs: [Ticket.ID]
}
