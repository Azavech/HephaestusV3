import ChatData
import ChatKit
import FileStorage
import Foundation
import MCPKit
import SwiftUI
import TicketData
import ToolsFoundation

/// Implement and Implement All, and the tools `implement_ticket` and `implement_bundle` (docs/data.md › Implement
/// chats): the checks on the ticket or the bundle, then the chat, linked to it. Only ToolsScenes knows both the
/// tickets and the chats.
@MainActor
struct Implementer {
    let tickets: TicketSession
    let chats: ChatSession

    /// Starts a ticket's chat and returns its id. `settings` are the sheet's, nil for a new chat's; `caller` is the
    /// chat whose Claude calls `implement_ticket`: a bundle chat of the ticket's bundle orchestrates the new chat.
    func implementTicket(_ value: String, settings: ChatSettings?, caller: String? = nil) async throws(ChatError) -> String {
        let id = value.uppercased()
        guard TicketIDs.parseTicket(id) != nil else { throw .invalid("\"\(value)\" is not a valid ticket id.") }
        let snapshot = tickets.snapshot
        guard let ticket = snapshot.ticket(id) else { throw .notFound("Ticket \(id) not found.") }
        if let refusal = ImplementRules.refusal(of: ticket.file) { throw .conflict(refusal) }
        let orchestrator = chats.orchestrator(for: id, caller: caller) { snapshot.bundle($0)?.ticketIDs }
        // A chat a bundle's chat starts takes that chat's settings as they are now.
        let chosen = orchestrator.flatMap { chats.chats[$0.chatID]?.file.settings } ?? settings ?? chats.defaults
        let request = ImplementChat(.ticket(id, orchestrator: orchestrator), projectID: ticket.projectID, itemTitle: ticket.file.title,
                                    settings: chosen)
        let tickets = tickets
        return try await chats.startImplementChat(request) { chatID throws(ChatError) in
            do throws(TicketError) {
                try await tickets.linkChat(chatID, toTicket: id)
            } catch {
                throw Self.chatError(error)
            }
        }
    }

    /// Starts a bundle's chat and returns its id: the bundle lists it and is In Progress.
    func implementBundle(_ value: String, settings: ChatSettings?) async throws(ChatError) -> String {
        let id = value.uppercased()
        guard let projectID = TicketIDs.parseBundle(id)?.project else { throw .invalid("\"\(value)\" is not a valid bundle id.") }
        let snapshot = tickets.snapshot
        guard let bundle = snapshot.bundle(id) else { throw .notFound("Bundle \(id) not found.") }
        if let refusal = ImplementRules.refusal(of: bundle, ticket: { snapshot.ticket($0)?.file }) { throw .conflict(refusal) }
        let request = ImplementChat(.bundle(id), projectID: projectID, itemTitle: bundle.title, settings: settings ?? chats.defaults)
        let tickets = tickets
        return try await chats.startImplementChat(request) { chatID throws(ChatError) in
            do throws(TicketError) {
                try await tickets.startImplementation(of: id, chat: chatID)
            } catch {
                throw Self.chatError(error)
            }
        }
    }

    /// The sheet's Start.
    func start(_ target: ImplementTarget, settings: ChatSettings) async throws(ChatError) -> String {
        switch target.kind {
        case .ticket: try await implementTicket(target.id, settings: settings)
        case .bundle: try await implementBundle(target.id, settings: settings)
        }
    }

    /// A bundle's tickets, for the chats' own items.
    func bundleTickets(_ bundleID: String) -> [String]? {
        tickets.snapshot.bundle(bundleID)?.ticketIDs
    }

    static func chatError(_ error: TicketError) -> ChatError {
        switch error {
        case .notFound(let message): .notFound(message)
        case .conflict(let message): .conflict(message)
        case .invalid(let message), .forbidden(let message): .invalid(message)
        case .storage(let error): .storage(error)
        case .project: .invalid(error.description)
        }
    }

    // MARK: MCP tools (docs/mcp.md › implement_ticket, implement_bundle)

    /// `implement_ticket` and `implement_bundle`, after the chat tools.
    func operations() -> [ToolOperation] {
        [implementTicketTool(), implementBundleTool()]
    }

    private func implementTicketTool() -> ToolOperation {
        let implementer = self
        return ToolOperation(
            name: "implement_ticket",
            description: "Starts a chat in which Claude implements a ticket: the chat's first message calls the internal skill implement-ticket with the ticket's id, and the chat is added to the ticket's chats. Called from a chat that implements a bundle, for a ticket of that bundle, the new chat also gets the bundle's id, takes the calling chat's settings, and works on its own branch <bundle id>/<ticket id> in a git worktree the app creates from the project's current commit, replacing the ticket's earlier branch and worktree; the app then sends the calling chat a message each time the new chat ends a turn. Refused for a ticket that is done or a draft. Returns the new chat's id.",
            inputSchema: .object(properties: [("ticketID", .string("Ticket id, such as ORD-12."))], required: ["ticketID"]),
            permission: .changeTickets,
            describe: { arguments in Self.describe(arguments["ticketID"]?.stringValue) }
        ) { @MainActor arguments throws(ToolError) in
            let value = try arguments.string("ticketID")
            do throws(ChatError) {
                let chatID = try await implementer.implementTicket(value, settings: nil, caller: MCPCaller.current.chatID)
                return ["chatID": .string(chatID)]
            } catch {
                throw Self.toolError(error)
            }
        }
    }

    private func implementBundleTool() -> ToolOperation {
        let implementer = self
        return ToolOperation(
            name: "implement_bundle",
            description: "Starts a chat in which Claude implements a bundle: the chat's first message calls the internal skill implement-bundle with the bundle's id, the chat is added to the bundle's chats, and the bundle is set to in_progress. Refused unless the bundle is todo and lists a ticket that isn't done. Returns the new chat's id.",
            inputSchema: .object(properties: [("bundleID", .string("Bundle id, such as ORD-B2."))], required: ["bundleID"]),
            permission: .changeTickets,
            describe: { arguments in Self.describe(arguments["bundleID"]?.stringValue) }
        ) { @MainActor arguments throws(ToolError) in
            let value = try arguments.string("bundleID")
            do throws(ChatError) {
                let chatID = try await implementer.implementBundle(value, settings: nil)
                return ["chatID": .string(chatID)]
            } catch {
                throw Self.toolError(error)
            }
        }
    }

    /// The call's row, and its card: the item opens in its Tickets window.
    nonisolated static func describe(_ value: String?) -> ToolCallText {
        let id = value?.uppercased() ?? ""
        let project = TicketIDs.parseTicket(id)?.project ?? TicketIDs.parseBundle(id)?.project
        return ToolCallText(action: String(localized: "Started the chat that implements \(id)", bundle: #bundle,
                                           comment: "Claude started a chat; the value is a ticket or bundle id"),
                            request: String(localized: "Claude wants to start a chat that implements \(id)", bundle: #bundle,
                                            comment: "An approval card; the value is a ticket or bundle id"),
                            item: project.map { ToolItem(tool: ToolKind.tickets.rawValue, projectID: $0, focus: id, title: id) })
    }

    static func toolError(_ error: ChatError) -> ToolError {
        switch error {
        case .unavailable(let message): ToolError(.unavailable, message)
        case .notFound(let message): ToolError(.notFound, message)
        case .invalid(let message): ToolError(.invalid, message)
        case .conflict(let message): ToolError(.conflict, message)
        case .storage: ToolError(.internal, error.description)
        }
    }
}

nonisolated extension EnvironmentValues {
    /// What starts the implement chats, from `RouteHost`; nil where there is none.
    @Entry var implementer: Implementer? = nil
}

extension View {
    /// Gives the window's tool the Implement action and shows the Implement sheet on the window (docs/ui/tickets.md ›
    /// Implement sheet); the new chat opens in its project's Chat tab.
    func implementSheet() -> some View {
        modifier(ImplementSheetModifier())
    }
}

private struct ImplementSheetModifier: ViewModifier {
    @Environment(\.implementer) private var implementer
    @Environment(\.chatStore) private var chatStore
    @Environment(\.openRoute) private var openRoute
    @State private var target: ImplementTarget?

    func body(content: Content) -> some View {
        content
            .environment(\.implement, implementer == nil || chatStore == nil ? nil : ImplementAction { [$target] in $target.wrappedValue = $0 })
            .sheet(item: $target) { target in
                if let implementer, let chatStore {
                    ImplementView(target: target, chats: chatStore, start: { settings throws(ChatError) in
                        try await implementer.start(target, settings: settings)
                    }) { id in
                        self.target = nil
                        if let id {
                            openRoute(.tool(.chat, project: target.projectID, focus: id))
                        }
                    }
                }
            }
    }
}
