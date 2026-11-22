import BuildsKit
import ChatData
import ContractsKit
import ServiceMapKit
import ChatKit
import Foundation
import MCPKit
import MachineData
import MachinesKit
import ProjectData
import TicketData
import TicketsKit
import ProjectsKit
import ToolsFoundation

/// Every tool operation the MCP server offers, in the order of `tools/list` (docs/mcp.md › Tools): each
/// available feature's operations, then `open_in_app`; then the debug tools, when the app was launched with
/// `HEPHAESTUS_DEBUG_TOOLS=1` (docs/mcp.md › Debug tools).
@MainActor
enum AppTools {
    /// `open` shows a route in a window, and says whether a window could.
    static func registry(session: ProjectSession, tickets: TicketSession, chats: ChatSession, contracts: LiveContractStore,
                         maps: LiveServiceMapStore, machines: MachineHost, implementer: Implementer, debugTools: Bool = false,
                         open: @escaping @MainActor (Route) -> Bool) -> ToolRegistry {
        let feedback = FeedbackLink(isUnlinked: { chats.isUnlinkedFeedback($0) }, link: { chats.linkFeedback($0, toTicket: $1) })
        let ticketCounts: @MainActor (String) -> [String: Int] = { id in
            (tickets.snapshot.tickets[id] ?? []).reduce(into: [:]) { counts, ticket in counts[ticket.file.status.rawValue, default: 0] += 1 }
        }
        return ToolRegistry(ProjectTools.operations(session: session, ticketCounts: ticketCounts) + TicketTools.operations(tickets: tickets, projects: session, feedback: feedback,
                                                                                                                   replyModel: { chats.replyModel(of: $0) })
            + ChatTools.operations(chats: chats, projects: session) + implementer.operations() + BuildTools.operations(projects: session)
            + ContractTools.operations(contracts: contracts, projects: session) + ClusterTools.operations(maps: maps, projects: session)
            + MachineTools.operations(host: machines) + [openInApp(session: session, tickets: tickets, open: open)]
            + (debugTools ? DebugTools.operations(session: session, tickets: tickets, open: open) : []))
    }

    /// What `open_in_app` and `debug_navigate` take: the item to show.
    static let targetSchema: ToolSchema = .object(
        "The item to open. project and projectSettings take projectID, ticket takes ticketID, bundle takes bundleID, skill takes name.",
        properties: [
            ("kind", .string("The item's kind.", oneOf: ["project", "projectSettings", "ticket", "bundle", "skill"])),
            ("projectID", .string("Project identifier, 2 to 8 letters, such as ORD.")),
            ("ticketID", .string("Ticket id, such as ORD-12.")),
            ("bundleID", .string("Bundle id, such as ORD-B2.")),
            ("name", .string("An internal skill's name, such as set-ticket-title.")),
        ],
        required: ["kind"]
    )

    /// The route that shows a target; `notFound` for an item that doesn't exist.
    static func route(of target: JSONValue, session: ProjectSession, tickets: TicketSession) throws(ToolError) -> Route {
        switch try target.string("kind") {
        case "ticket", "bundle":
            let isTicket = try target.string("kind") == "ticket"
            let id = try target.string(isTicket ? "ticketID" : "bundleID").uppercased()
            let found = isTicket ? tickets.snapshot.ticket(id) != nil : tickets.snapshot.bundle(id) != nil
            guard found, let project = (isTicket ? TicketIDs.parseTicket(id)?.project : TicketIDs.parseBundle(id)?.project) else {
                throw ToolError(.notFound, isTicket ? "Ticket \(id) not found." : "Bundle \(id) not found.")
            }
            return .tool(.tickets, project: project, focus: id)
        case "skill":
            let name = try target.string("name")
            guard InternalSkill.all.contains(where: { $0.name == name }) else { throw ToolError(.notFound, "No internal skill \(name).") }
            return .systemPrompts(skill: name)
        default:
            let id = try target.string("projectID")
            guard session.snapshot.project(id) != nil else { throw ToolError(.notFound, "No project \(id).") }
            return try target.string("kind") == "projectSettings" ? .projectSettings(id) : .project(id)
        }
    }

    static func openInApp(session: ProjectSession, tickets: TicketSession, open: @escaping @MainActor (Route) -> Bool) -> ToolOperation {
        ToolOperation(
            name: "open_in_app",
            description: "Opens an item in Hephaestus V3 for the user: a project in the Projects window, a project's settings window, a ticket or bundle in its project's Tickets window, or an internal skill in System Prompts.",
            inputSchema: .object(properties: [("target", targetSchema)], required: ["target"]),
            permission: .read,
            describe: { _ in ToolCallText(action: String(localized: "Opened a window of Hephaestus", bundle: #bundle)) }
        ) { @MainActor arguments throws(ToolError) in
            guard let target = arguments["target"] else { throw ToolError(.invalid, "target: required.") }
            let route = try route(of: target, session: session, tickets: tickets)
            guard open(route) else { throw ToolError(.unavailable, "The app has no window to show it in.") }
            return [:]
        }
    }
}
