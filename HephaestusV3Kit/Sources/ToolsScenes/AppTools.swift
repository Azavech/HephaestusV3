import Foundation
import MCPKit
import ProjectData
import TicketData
import TicketsKit
import ProjectsKit
import ToolsFoundation

/// Every tool operation the MCP server offers, in the order of `tools/list` (docs/mcp.md › Tools): each
/// available feature's operations, then `open_in_app`.
@MainActor
enum AppTools {
    /// `open` shows a route in a window, and says whether a window could.
    static func registry(session: ProjectSession, tickets: TicketSession, open: @escaping @MainActor (Route) -> Bool) -> ToolRegistry {
        ToolRegistry(ProjectTools.operations(session: session) + TicketTools.operations(tickets: tickets, projects: session)
            + [openInApp(session: session, tickets: tickets, open: open)])
    }

    static func openInApp(session: ProjectSession, tickets: TicketSession, open: @escaping @MainActor (Route) -> Bool) -> ToolOperation {
        ToolOperation(
            name: "open_in_app",
            description: "Show something to the user in Hephaestus V3: a project in the Projects window, a project's settings, or a ticket or a bundle in its Tickets window.",
            inputSchema: .object(properties: [
                ("target", .object(
                    "What to show. kind decides the other properties: project: projectID; projectSettings: projectID; ticket: ticketID; bundle: bundleID.",
                    properties: [
                        ("kind", .string("Kind of item to show.", oneOf: ["project", "projectSettings", "ticket", "bundle"])),
                        ("projectID", .string("Project identifier: 2 to 8 letters, for example ORD.")),
                        ("ticketID", .string("Ticket id, for example ORD-12.")),
                        ("bundleID", .string("Bundle id, for example ORD-B2.")),
                    ],
                    required: ["kind"]
                )),
            ], required: ["target"]),
            permission: .read
        ) { @MainActor arguments throws(ToolError) in
            guard let target = arguments["target"] else { throw ToolError(.invalid, "target: required.") }
            let route: Route
            switch try target.string("kind") {
            case "ticket", "bundle":
                let isTicket = try target.string("kind") == "ticket"
                let id = try target.string(isTicket ? "ticketID" : "bundleID").uppercased()
                let found = isTicket ? tickets.snapshot.ticket(id) != nil : tickets.snapshot.bundle(id) != nil
                guard found, let project = (isTicket ? TicketIDs.parseTicket(id)?.project : TicketIDs.parseBundle(id)?.project) else {
                    throw ToolError(.notFound, isTicket ? "Ticket \(id) not found." : "Bundle \(id) not found.")
                }
                route = .tool(.tickets, project: project, focus: id)
            default:
                let id = try target.string("projectID")
                guard session.snapshot.project(id) != nil else { throw ToolError(.notFound, "No project \(id).") }
                route = try target.string("kind") == "projectSettings" ? .projectSettings(id) : .project(id)
            }
            guard open(route) else { throw ToolError(.unavailable, "The app has no window to show it in.") }
            return [:]
        }
    }
}
