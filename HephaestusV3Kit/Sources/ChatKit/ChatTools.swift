import ChatData
import FileStorage
import Foundation
import MCPKit
import ProjectData
import ToolsFoundation

/// What a chat's Claude may do without asking, as the user set it (docs/mcp.md › Permissions). The MCP server
/// asks before each call of a chat's Claude; the external token's calls run as before.
public enum ChatGate {
    /// Nil lets the call run; an error refuses it. A change set to Ask First waits for the user's answer to a
    /// card in the chat.
    @MainActor
    public static func check(_ caller: MCPCaller, _ operation: ToolOperation, _ arguments: JSONValue, chats: ChatSession,
                             defaults: UserDefaults = .standard) async -> ToolError? {
        guard case .chat(let chatID) = caller else { return nil }
        func rule(_ key: String) -> ChangePermission {
            defaults.string(forKey: key).flatMap(ChangePermission.init(rawValue:)) ?? .askFirst
        }
        let permission: ChangePermission
        let refusal: String
        switch operation.permission {
        case .read, .renameChats:
            return nil
        case .changeTickets:
            permission = rule(ChatPreferences.ticketChangesKey)
            refusal = "The user doesn't let Claude change tickets from chats (Settings ▸ Chat)."
        case .deleteTickets:
            permission = rule(ChatPreferences.ticketChangesKey) == .never ? .never : .askFirst
            refusal = "The user doesn't let Claude change tickets from chats (Settings ▸ Chat)."
        case .changeProjects:
            permission = rule(ChatPreferences.projectChangesKey)
            refusal = "The user doesn't let Claude change projects from chats (Settings ▸ Chat)."
        case .removeProjects:
            permission = rule(ChatPreferences.projectChangesKey) == .never ? .never : .askFirst
            refusal = "The user doesn't let Claude change projects from chats (Settings ▸ Chat)."
        }
        switch permission {
        case .always:
            return nil
        case .never:
            return ToolError(.forbidden, refusal)
        case .askFirst:
            let allowed = await chats.requestApproval(chatID, tool: operation.name, input: arguments)
            return allowed ? nil : ToolError(.forbidden, "The user didn't allow this call.")
        }
    }
}

/// The chat operations the MCP server offers Claude (docs/mcp.md › Chat tools).
public enum ChatTools {
    @MainActor
    public static func operations(chats: ChatSession, projects: ProjectSession) -> [ToolOperation] {
        [listChats(chats, projects), getChat(chats), renameChat(chats)]
    }

    static let chatID = ToolSchema.string("Chat id, an uppercase UUID.")

    @MainActor
    static func listChats(_ chats: ChatSession, _ projects: ProjectSession) -> ToolOperation {
        ToolOperation(
            name: "list_chats",
            description: "Returns a project's chats, its sub projects' included, the latest first: id, project, title, kind, created, updated, origin, model, effort and state.",
            inputSchema: .object(properties: [("projectID", .string("Project identifier, 2 to 8 letters, such as ORD."))], required: ["projectID"]),
            permission: .read,
            describe: { arguments in
                let id = arguments["projectID"]?.stringValue?.uppercased() ?? ""
                return ToolCallText(action: String(localized: "Listed the chats of \(id)", bundle: #bundle),
                                    item: ToolItem(tool: ToolKind.chat.rawValue, projectID: id, focus: "", title: id))
            }
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("projectID").uppercased()
            guard projects.snapshot.project(id) != nil else { throw ToolError(.notFound, "Project \(id) not found.") }
            let family = Set(projects.snapshot.family(of: id).map(\.id))
            return .array(chats.chats(of: family).map { json($0, chats) })
        }
    }

    @MainActor
    static func getChat(_ chats: ChatSession) -> ToolOperation {
        ToolOperation(
            name: "get_chat",
            description: "Returns a chat with its messages: the user's messages, Claude's replies, the tool calls and their results, the permission requests and their answers, in order.",
            inputSchema: .object(properties: [("chatID", chatID)], required: ["chatID"]),
            permission: .read,
            describe: { arguments in
                _ = arguments
                return ToolCallText(action: String(localized: "Read a chat", bundle: #bundle, comment: "Claude read another chat's messages"))
            }
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("chatID").uppercased()
            guard let chat = chats.chats[id] else { throw ToolError(.notFound, "Chat \(id) not found.") }
            await chats.open(id)
            var value = json(chat, chats)
            if case .object(var object) = value {
                object["items"] = .array((chats.transcripts[id] ?? []).map(\.json))
                value = .object(object)
            }
            return value
        }
    }

    @MainActor
    static func renameChat(_ chats: ChatSession) -> ToolOperation {
        ToolOperation(
            name: "rename_chat",
            description: "Renames a chat. The title is 1 to 100 characters on one line. Returns the chat.",
            inputSchema: .object(properties: [("chatID", chatID), ("title", .string("The new title."))], required: ["chatID", "title"]),
            permission: .renameChats,
            describe: { arguments in
                ToolCallText(action: String(localized: "Renamed a chat “\(arguments["title"]?.stringValue ?? "")”", bundle: #bundle,
                                            comment: "Claude renamed a chat; the value is the new title"))
            }
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("chatID").uppercased()
            let title = try arguments.string("title")
            do throws(ChatError) {
                try chats.rename(id, to: title)
            } catch {
                switch error {
                case .notFound(let message): throw ToolError(.notFound, message)
                case .invalid(let message): throw ToolError(.invalid, message)
                default: throw ToolError(.internal, error.description)
                }
            }
            guard let chat = chats.chats[id] else { throw ToolError(.notFound, "Chat \(id) not found.") }
            return json(chat, chats)
        }
    }

    /// A chat's JSON: its metadata and state.
    @MainActor
    static func json(_ chat: LoadedChat, _ chats: ChatSession) -> JSONValue {
        let state: String = switch chats.state(of: chat.id) {
        case .idle: "idle"
        case .starting: "starting"
        case .running: "running"
        case .waitingPermission: "waitingPermission"
        case .error: "error"
        }
        var object: [String: JSONValue] = [
            "id": .string(chat.id), "project": .string(chat.projectID), "title": .string(chat.file.title),
            "kind": .string(chat.file.kind.rawValue), "created": .string(ISODate.string(from: chat.file.created)),
            "updated": .string(ISODate.string(from: chat.file.updated)), "model": .string(chat.file.settings.model),
            "effort": .string(chat.file.settings.effort.rawValue), "state": .string(state),
        ]
        if let origin = chat.file.origin { object["origin"] = .string(origin) }
        if let ticket = chat.file.ticketID { object["ticket"] = .string(ticket) }
        if let bundle = chat.file.bundleID { object["bundle"] = .string(bundle) }
        return .object(object)
    }
}
