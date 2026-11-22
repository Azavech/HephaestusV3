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
            + MachineTools.operations(host: machines) + [openInApp(session: session, tickets: tickets, chats: chats, machines: machines, open: open)]
            + (debugTools ? DebugTools.operations(session: session, tickets: tickets, chats: chats, machines: machines, open: open) : []))
    }

    /// What `open_in_app` and `debug_navigate` take: the item to show.
    static let targetSchema: ToolSchema = .object(
        "The item to open. project and projectSettings take projectID, ticket takes ticketID, bundle takes bundleID, skill takes name, chat takes chatID, tool takes projectID, tool and optionally focus, virtualMachine takes vmID, memories takes projectID or none for the global memories.",
        properties: [
            ("kind", .string("The item's kind.", oneOf: ["project", "projectSettings", "ticket", "bundle", "skill", "chat", "tool", "virtualMachine", "memories"])),
            ("projectID", .string("Project identifier, 2 to 8 letters, such as ORD.")),
            ("ticketID", .string("Ticket id, such as ORD-12.")),
            ("bundleID", .string("Bundle id, such as ORD-B2.")),
            ("name", .string("An internal skill's name, such as set-ticket-title.")),
            ("chatID", .string("Chat id, as list_chats gives it.")),
            ("tool", .string("The tool to open for the project.", oneOf: ToolKind.allCases.map(\.rawValue))),
            ("focus", .string("The item the tool selects, as a route's focus, such as ORD-12 in tickets.")),
            ("vmID", .string("Virtual machine id, as vm_list gives it.")),
        ],
        required: ["kind"]
    )

    /// The route that shows a target; `notFound` for an item that doesn't exist.
    static func route(of target: JSONValue, session: ProjectSession, tickets: TicketSession, chats: ChatSession? = nil,
                      machines: MachineHost? = nil) throws(ToolError) -> Route {
        switch try target.string("kind") {
        case "chat":
            let id = try target.string("chatID")
            guard chats?.chats[id] != nil else { throw ToolError(.notFound, "Chat \(id) not found.") }
            return .chatWindow(chat: id)
        case "tool":
            let id = try target.string("projectID")
            guard session.snapshot.project(id) != nil else { throw ToolError(.notFound, "No project \(id).") }
            guard let tool = ToolKind(rawValue: try target.string("tool")) else { throw ToolError(.invalid, "target.tool: unknown tool.") }
            return .tool(tool, project: id, focus: target["focus"]?.stringValue)
        case "virtualMachine":
            let id = try target.string("vmID")
            guard machines?.machines.contains(where: { $0.id == id }) == true else { throw ToolError(.notFound, "No virtual machine \(id).") }
            return .machine(id)
        case "memories":
            guard let id = target["projectID"]?.stringValue else { return .memories(scope: nil) }
            guard session.snapshot.project(id) != nil else { throw ToolError(.notFound, "No project \(id).") }
            return .memories(scope: id)
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

    static func openInApp(session: ProjectSession, tickets: TicketSession, chats: ChatSession? = nil, machines: MachineHost? = nil,
                          open: @escaping @MainActor (Route) -> Bool) -> ToolOperation {
        ToolOperation(
            name: "open_in_app",
            description: "Opens an item in Hephaestus V3 for the user: a project in the Projects window, a project's settings window, a ticket or bundle in its project's Tickets window, an internal skill in System Prompts, a chat in its own window, a project's tool on an item, a virtual machine, or the memories of a project or the global ones.",
            inputSchema: .object(properties: [("target", targetSchema)], required: ["target"]),
            permission: .read,
            describe: { _ in ToolCallText(action: String(localized: "Opened a window of Hephaestus", bundle: #bundle)) }
        ) { @MainActor arguments throws(ToolError) in
            guard let target = arguments["target"] else { throw ToolError(.invalid, "target: required.") }
            let route = try route(of: target, session: session, tickets: tickets, chats: chats, machines: machines)
            guard open(route) else { throw ToolError(.unavailable, "The app has no window to show it in.") }
            return [:]
        }
    }
}
